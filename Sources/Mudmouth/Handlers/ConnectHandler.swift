//
//  ConnectHandler.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import OSLog
import SwiftyLogger

/// Where CONNECT upstream sockets go. `address` overrides ONLY the socket destination; TLS always
/// authenticates the CONNECT host.
struct HTTPProxyUpstream: Sendable {
    init(
        address: (@Sendable (String, Int) throws -> SocketAddress)? = nil,
        tlsConfiguration: TLSConfiguration = .makeClientConfiguration(),
    ) {
        self.address = address
        self.tlsConfiguration = tlsConfiguration
    }

    let address: (@Sendable (String, Int) throws -> SocketAddress)?
    let tlsConfiguration: TLSConfiguration
}

final class ConnectHandler: ChannelInboundHandler {
    // MARK: Internal

    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    init(
        allowedHosts: Set<String>,
        authority: HTTPHookAuthority = HTTPHookAuthority(),
        isConsentGranted: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted },
        upstream: HTTPProxyUpstream = HTTPProxyUpstream(),
    ) {
        self.allowedHosts = allowedHosts
        self.authority = authority
        self.isConsentGranted = isConsentGranted
        upstreamConfiguration = upstream
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard isConsentGranted() else {
            abort(context: context)
            return
        }
        switch state {
            case .idle:
                idle(context: context, data: data)
            case .awaitingEnd:
                awaitingEnd(context: context, data: data)
            case .connecting:
                // Pipelined HTTP or raw bytes after decoder removal: never unwrap or forward.
                abort(context: context)
            case .established:
                // Forward data to the next channel.
                context.fireChannelRead(data)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        upstream = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        abort(context: context)
    }

    // MARK: Private

    private enum State {
        case idle
        case awaitingEnd
        case connecting
        case established
    }

    private let allowedHosts: Set<String>
    private let authority: HTTPHookAuthority
    private let isConsentGranted: @Sendable () -> Bool
    private let upstreamConfiguration: HTTPProxyUpstream
    private var upstream: Channel?
    private var state: State = .idle
    private var host: String?
    private var port: Int?

    private func abort(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        upstream = nil
        context.close(promise: nil)
    }

    private func respondAndClose(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let head = HTTPResponseHead(
            version: .http1_1, status: status,
            headers: HTTPHeaders([("Content-Length", "0"), ("Connection", "close")]),
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }

    private func awaitingEnd(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        guard let host, let port else {
            abort(context: context)
            return
        }
        // Must precede decoder removal: bytes released by the removal are raw, not HTTP parts.
        state = .connecting
        context.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).whenComplete { result in
            guard case let .success(decoder) = result, context.channel.isActive, self.isConsentGranted() else {
                self.abort(context: context)
                return
            }
            context.pipeline.removeHandler(context: decoder, promise: nil)
            self.connectUpstream(context: context, host: host, port: port)
        }
    }

    private func connectUpstream(context: ChannelHandlerContext, host: String, port: Int) {
        let configuration = upstreamConfiguration
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                self.upstream = channel
                guard context.channel.isActive, self.isConsentGranted() else { return channel.close() }
                do {
                    let sslContext = try NIOSSLContext(configuration: configuration.tlsConfiguration)
                    let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    return channel.pipeline.addHandler(tls)
                        .flatMap { channel.pipeline.addHandler(HTTPRequestEncoder()) }
                        .flatMap {
                            channel.pipeline.addHandler(
                                ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward)),
                            )
                        }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let connected: EventLoopFuture<Channel>
        do {
            if let address = configuration.address {
                connected = try bootstrap.connect(to: address(host, port))
            } else {
                connected = bootstrap.connect(host: host, port: port)
            }
        } catch {
            connectFailed(context: context, host: host, port: port, error: error)
            return
        }
        connected.whenComplete { result in
            switch result {
                case let .success(client):
                    self.upstreamConnected(context: context, client: client)
                case let .failure(failure):
                    self.connectFailed(context: context, host: host, port: port, error: failure)
            }
        }
    }

    private func connectFailed(context: ChannelHandlerContext, host: String, port: Int, error: Error) {
        NSLog("Interceptor: Failed to connect to \(host):\(port): \(error)")
        upstream?.close(promise: nil)
        upstream = nil
        guard context.channel.isActive, isConsentGranted() else {
            abort(context: context)
            return
        }
        // The response encoder is still installed; close once the 404 is flushed.
        respondAndClose(context: context, status: .notFound)
    }

    private func upstreamConnected(context: ChannelHandlerContext, client: Channel) {
        guard context.channel.isActive, isConsentGranted() else {
            client.close(promise: nil)
            abort(context: context)
            return
        }
        // Send 200 to downstream.
        let head = HTTPResponseHead(
            version: .init(major: 1, minor: 1), status: .ok, headers: HTTPHeaders([("Content-Length", "0")]),
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenFailure { _ in
            client.close(promise: nil)
            self.abort(context: context)
        }
        context.pipeline.context(handlerType: HTTPResponseEncoder.self).whenComplete { lookup in
            guard case let .success(encoder) = lookup, context.channel.isActive, self.isConsentGranted() else {
                client.close(promise: nil)
                self.abort(context: context)
                return
            }
            context.pipeline.removeHandler(context: encoder, promise: nil)
            let (localGlue, remoteGlue) = GlueHandler.matchedPair()
            context.pipeline.addHandler(localGlue)
                .and(client.pipeline.addHandler(remoteGlue))
                .whenComplete { result in
                    switch result {
                        case .success:
                            guard context.channel.isActive, self.isConsentGranted() else {
                                client.close(promise: nil)
                                self.abort(context: context)
                                return
                            }
                            self.state = .established
                        case let .failure(failure):
                            SwiftyLogger.error(failure)
                            client.close(promise: nil)
                            self.abort(context: context)
                    }
                }
        }
    }

    private func idle(context: ChannelHandlerContext, data: NIOAny) {
        guard case let .head(head) = unwrapInboundIn(data) else { return }
        guard head.method == .CONNECT else {
            respondAndClose(context: context, status: .methodNotAllowed)
            return
        }
        let components = head.uri.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let requestedPort = Int(components[1]), requestedPort == 443,
              allowedHosts.contains(String(components[0]).lowercased())
        else {
            respondAndClose(context: context, status: .forbidden)
            return
        }
        host = String(components[0]).lowercased()
        port = requestedPort
        // The validated CONNECT authority is the only host hooks may match on; the decrypted Host header is untrusted.
        authority.establish(host: String(components[0]))
        state = .awaitingEnd
    }
}

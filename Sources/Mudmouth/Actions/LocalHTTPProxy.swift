//
//  LocalHTTPProxy.swift
//  Mudmouth
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// Tracks listener and accepted channels under one lock so stop also cancels an in-flight bind.
final class LocalProxyChannels: @unchecked Sendable {
    // MARK: Lifecycle

    init(isConsentGranted: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted }) {
        self.isConsentGranted = isConsentGranted
    }

    // MARK: Internal

    enum Failure: Error { case invalidOptions, alreadyRunning }

    func begin() -> Int? {
        lock.withLock {
            guard !running else { return nil }
            running = true
            generation += 1
            return generation
        }
    }

    func register(_ channel: Channel, generation expected: Int) -> Bool {
        let accepted = lock.withLock {
            guard running, generation == expected, isConsentGranted() else { return false }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
        if accepted {
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.remove(channel)
            }
        }
        return accepted
    }

    func stop(generation expected: Int? = nil) -> [Channel] {
        lock.withLock {
            if let expected, expected != generation {
                return []
            }
            running = false
            generation += 1
            let closing = Array(channels.values)
            channels.removeAll()
            return closing
        }
    }

    // MARK: Private

    private let lock = NSLock()
    private let isConsentGranted: @Sendable () -> Bool
    private var generation = 0
    private var running = false
    private var channels: [ObjectIdentifier: Channel] = [:]

    private func remove(_ channel: Channel) {
        lock.withLock { _ = channels.removeValue(forKey: ObjectIdentifier(channel)) }
    }
}

/// Reject further inbound bytes as soon as the consent is withdrawn.
final class CaptureConsentHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    init(isConsentGranted: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted }) {
        self.isConsentGranted = isConsentGranted
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard isConsentGranted() else {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    private let isConsentGranted: @Sendable () -> Bool
}

/// Loopback CONNECT/TLS proxy. Registry and listener are per instance; the caller owns the event loop group.
final class LocalHTTPProxy: @unchecked Sendable {
    // MARK: Lifecycle

    init(
        group: EventLoopGroup,
        isConsentGranted: @escaping @Sendable () -> Bool = { CaptureAuthorization.isGranted },
    ) {
        self.group = group
        self.isConsentGranted = isConsentGranted
        channels = LocalProxyChannels(isConsentGranted: isConsentGranted)
    }

    // MARK: Internal

    /// Binds `127.0.0.1:port`; pass `0` to let the system pick and read it from the returned channel.
    func start(
        port: Int = 6836,
        allowedHosts: Set<String>,
        serverContext: NIOSSLContext,
        processor: (any HTTPPluginProcessing)? = nil,
        observerFactory: @escaping () -> (any HTTPExchangeObserving)? = { nil },
        upstream: HTTPProxyUpstream = .init(),
    ) async throws -> Channel {
        guard isConsentGranted() else { throw CaptureAuthorization.Failure.consentRequired }
        guard let generation = channels.begin() else { throw LocalProxyChannels.Failure.alreadyRunning }
        let channels = channels
        let isConsentGranted = isConsentGranted
        // Only ever invoked on the child's event loop, one call per accepted connection.
        nonisolated(unsafe) let observerFactory = observerFactory
        do {
            let listener = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    guard channels.register(channel, generation: generation) else { return channel.close() }
                    let authority = HTTPHookAuthority()
                    return channel.pipeline.addHandlers(
                        [
                            CaptureConsentHandler(isConsentGranted: isConsentGranted),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            HTTPResponseEncoder(),
                            ConnectHandler(
                                allowedHosts: allowedHosts, authority: authority,
                                isConsentGranted: isConsentGranted, upstream: upstream,
                            ),
                            NIOSSLServerHandler(context: serverContext),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            HTTPResponseEncoder(),
                            HTTPHookHandler(
                                authority: authority,
                                processor: processor,
                                observer: observerFactory(),
                                isConsentGranted: isConsentGranted,
                            ),
                        ], position: .last,
                    )
                }
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .childChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
                .bind(host: "127.0.0.1", port: port).get()
            guard channels.register(listener, generation: generation) else {
                try? await listener.close().get()
                if !isConsentGranted() {
                    throw CaptureAuthorization.Failure.consentRequired
                }
                throw CancellationError()
            }
            return listener
        } catch {
            await abort(channels.stop(generation: generation))
            throw error
        }
    }

    /// Closes the listener and every accepted connection (which also closes paired upstreams).
    func stop() async {
        await abort(channels.stop())
    }

    // MARK: Private

    private func abort(_ channels: [Channel]) async {
        // Administrative shutdown must not wait for graceful response draining.
        // Queue every abort before awaiting any one channel, including listeners
        // and children whose HTTP pipeline has not finished initialization yet.
        let closing = channels.map { channel in
            channel.eventLoop.submit {
                channel.pipeline.fireUserInboundEventTriggered(HTTPHookAbort())
                channel.close(promise: nil)
            }.flatMap { channel.closeFuture }
        }
        for result in closing {
            try? await result.get()
        }
    }

    private let group: EventLoopGroup
    private let isConsentGranted: @Sendable () -> Bool
    private let channels: LocalProxyChannels
}

//
//  MITM.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import NetworkExtension
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import SwiftyLogger

/// Tracks listener and accepted channels under one lock so stop also cancels an in-flight bind.
final class LocalProxyChannels: @unchecked Sendable {
    enum Failure: Error { case invalidOptions }
    private let lock = NSLock()
    private var generation = 0
    private var running = false
    private var channels: [ObjectIdentifier: Channel] = [:]

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
            guard running, generation == expected, CaptureAuthorization.isGranted else { return false }
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

    private func remove(_ channel: Channel) {
        lock.withLock { _ = channels.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    func stop(generation expected: Int? = nil) -> [Channel] {
        lock.withLock {
            if let expected, expected != generation { return [] }
            running = false
            generation += 1
            let closing = Array(channels.values)
            channels.removeAll()
            return closing
        }
    }
}

/// Reject further inbound bytes as soon as the shared consent is withdrawn.
final class CaptureConsentHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard CaptureAuthorization.isGranted else {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }
}

public enum MITM {
    private static let port = 6_836
    private static let group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private static let channels = LocalProxyChannels()

    public static func startTunnel(options: [String: NSObject]? = nil) async throws {
        try CaptureAuthorization.requireConsent()
        let decoder = JSONDecoder()
        guard let options,
              let keyData = options[NEVPNConnectionStartOptionPassword] as? Data,
              let keyPair = try? decoder.decode(KeyPair.self, from: keyData),
              let targetData = options[NEVPNConnectionProxyTargets] as? Data,
              let targets = try? decoder.decode([ProxyOption].self, from: targetData)
        else { throw LocalProxyChannels.Failure.invalidOptions }
        guard let generation = channels.begin() else { return }
        do {
            let listener = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    guard channels.register(channel, generation: generation) else { return channel.close() }
                    return channel.pipeline.addHandlers(
                        [
                            CaptureConsentHandler(),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            HTTPResponseEncoder(),
                            ConnectHandler(allowedHosts: Set(targets.filter(\.capture).map { $0.host.lowercased() })),
                            NIOSSLServerHandler(context: keyPair.context),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            HTTPResponseEncoder(),
                            ProxyHandler(options: targets),
                        ], position: .last
                    )
                }
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .childChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
                .bind(host: "127.0.0.1", port: port).get()
            guard channels.register(listener, generation: generation) else {
                try? await listener.close().get()
                throw CaptureAuthorization.Failure.consentRequired
            }
        } catch {
            for channel in channels.stop(generation: generation) { try? await channel.close().get() }
            throw error
        }
    }

    public static func stopTunnel() async {
        // Schedule every close before awaiting any one channel; closing a downstream
        // channel also closes its paired upstream connection through GlueHandler.
        let closing = channels.stop().map { $0.close() }
        for result in closing { try? await result.get() }
    }
}

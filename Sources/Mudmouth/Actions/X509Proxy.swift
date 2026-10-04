//
//  X509Proxy.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import KeychainAccess
import NIOCore
import NIOHTTP1
import NIOPosix
import SwiftUI
import SwiftyLogger
import X509

@Observable
public class X509Proxy: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private let keychain: Keychain = .init(service: Bundle.main.bundleIdentifier!)
    private let port: Int = 8_888
    public var url: URL {
        .init(string: "http://127.0.0.1:\(port)")!
    }

    private let channels = LocalProxyChannels()
    private let group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lifecycleLock = NSLock()
    private let monitorLock = NSLock()
    private var consentMonitor: DispatchSourceTimer?

    /// Starts a loopback-only certificate server after explicit consent.
    func start() throws {
        try lifecycleLock.withLock { try startServer() }
    }

    private func startServer() throws {
        try CaptureAuthorization.requireConsent()
        guard let generation = channels.begin() else { return }
        do {
            let certificate = try keychain.getCertificate()
            let listener = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
                .childChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
                .childChannelInitializer { [channels] channel in
                    guard channels.register(channel, generation: generation) else { return channel.close() }
                    return channel.pipeline.configureHTTPServerPipeline()
                        .flatMap {
                            channel.pipeline.addHandler(CertificateHandler(certificate: certificate))
                        }
                }
                .bind(host: "127.0.0.1", port: port).wait()
            guard channels.register(listener, generation: generation) else {
                try? listener.close().wait()
                throw CaptureAuthorization.Failure.consentRequired
            }
            monitorLock.withLock {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now(), repeating: .milliseconds(250))
                timer.setEventHandler { [weak self] in
                    guard !CaptureAuthorization.isGranted else { return }
                    try? self?.stop()
                }
                consentMonitor?.cancel()
                consentMonitor = timer
                timer.resume()
            }
        } catch {
            for channel in channels.stop(generation: generation) {
                try? channel.close().wait()
            }
            throw error
        }
    }

    /// Closes the listener and all accepted connections; a later start can rebind.
    func stop() throws {
        lifecycleLock.withLock { stopServer() }
    }

    private func stopServer() {
        monitorLock.withLock {
            consentMonitor?.cancel()
            consentMonitor = nil
        }
        let closing = channels.stop().map { $0.close() }
        for result in closing {
            try? result.wait()
        }
    }

    init() {}
}

public extension X509Proxy {
    static let `default`: X509Proxy = .init()
}

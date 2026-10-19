//
//  MITM.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import MudmouthHTTPHooks
import NetworkExtension
import NIOCore
import NIOPosix
import NIOSSL
import X509

public enum MITM {
    public static func startTunnel(
        options: [String: NSObject]? = nil,
        pluginProcessor: (any HTTPPluginProcessing)? = nil,
    ) async throws {
        try CaptureAuthorization.requireConsent()
        let decoder = JSONDecoder()
        guard let options,
              let keyData = options[NEVPNConnectionStartOptionPassword] as? Data,
              let keyPair = try? decoder.decode(KeyPair.self, from: keyData),
              let targetData = options[NEVPNConnectionProxyTargets] as? Data,
              let targets = try? decoder.decode([ProxyOption].self, from: targetData)
        else { throw LocalProxyChannels.Failure.invalidOptions }
        let serverContext = try NIOSSLContext(configuration: TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(NIOSSLCertificate(bytes: keyPair.certificate.derBytes, format: .der))],
            privateKey: .privateKey(NIOSSLPrivateKey(bytes: keyPair.privateKey.derBytes, format: .der)),
        ))
        _ = try await proxy.start(
            allowedHosts: Set(targets.filter(\.capture).map { $0.host.lowercased() }),
            serverContext: serverContext,
            processor: pluginProcessor,
            observerFactory: { ProxyRecorder(options: targets) },
        )
    }

    public static func stopTunnel() async {
        await proxy.stop()
    }

    private static let group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private static let proxy = LocalHTTPProxy(group: group)
}

//
//  Mudmouth.swift
//  Interceptor
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Crypto
import Foundation
import KeychainAccess
@preconcurrency import NetworkExtension
import NIO
import NIOHTTP1
import NIOSSL
import OSLog
import SwiftASN1
import SwiftUI
import SwiftyLogger
import UniformTypeIdentifiers
import X509

@MainActor
@Observable
public final class Mudmouth {
    private var manager: NETunnelProviderManager? {
        willSet {
            SwiftyLogger.debug("Interceptor: VPN Manager updated \(newValue)")
            // 現在の値ではなく、新しくセットする値がnilかどうかでチェックする
            isVPNInstalled = newValue != nil
        }
    }

    private(set) var privateKey: Certificate.PrivateKey! {
        willSet {
            SwiftyLogger.warning("Private key updated, regenerating certificate")
            try? keychain.setPrivateKey(newValue)
        }
    }

    private(set) var certificate: Certificate! {
        willSet {
            SwiftyLogger.warning("Certificate updated, saving to keychain")
            try? keychain.setCertificate(newValue)
        }
    }

    public static let `default`: Mudmouth = .init()
    // 新規データはこの端末のみのKeychainに保存する
    // NOTE: ライブラリを利用するアプリのバンドルIDで初期化
    private let keychain: Keychain = .init(service: Bundle.main.bundleIdentifier!).synchronizable(false).accessibility(.afterFirstUnlockThisDeviceOnly)
    private let port: Int = 16_836
    private let bundleIdentifier: String = "\(Bundle.main.bundleIdentifier!).packet-tunnel"
    private let generator: UINotificationFeedbackGenerator = .init()
    private let notificationCenter: UNUserNotificationCenter = .current()
    private var timer: Timer?
    private var status: NEVPNStatus = .invalid

    private var options: [ProxyOption] = [
        .init(host: "api.accounts.nintendo.com", paths: []),
        .init(host: "api-lp1.znc.srv.nintendo.net", paths: []),
        .init(host: "api.lp1.usagi.srv.nintendo.net", paths: []),
        .init(host: "api.lp1.av5ja.srv.nintendo.net", paths: [
            .init(path: "/api/bullet_tokens"),
        ]),
        .init(host: "api.lp1.87abc152.srv.nintendo.net", paths: []),
        .init(host: "accounts.nintendo.com", paths: []),
        .init(host: "app.splatoon2.nintendo.net", paths: [
            .init(path: "/"),
        ]),
        .init(host: "app.smashbros.nintendo.net", paths: []),
        .init(host: "web.sd.lp1.acbaa.srv.nintendo.net", paths: []),
    ]

    /// Nintendo Switch Appがインストールされているかどうか
    /// NOTE: 一度アプリがバックグラウンドになるので、フォアグラウンドになったときにチェックすれば良い
    private(set) var isAPPInstalled: Bool = false {
        willSet {
            SwiftyLogger.debug("Interceptor: isAPPInstalled changed from \(isAPPInstalled) to \(newValue)")
        }
    }

    /// VPNがインストールされているかどうか
    /// NOTE: アプリがフォアグラウンドになったときか、VPNをインストール直後にチェックすれば良い
    private(set) var isVPNInstalled: Bool = false {
        willSet {
            SwiftyLogger.debug("Interceptor: isVPNInstalled changed from \(isVPNInstalled) to \(newValue)")
        }
    }

    /// VPNに接続されているかどうか
    /// NOTE: VPNの状態が変更されたときにチェックすれば良い
    public private(set) var isConnected: Bool = false {
        willSet {
            SwiftyLogger.debug("Interceptor: isConnected changed from \(isConnected) to \(newValue)")
        }
    }

    /// 証明書がインストールされているかどうか
    /// NOTE: アプリがフォアグラウンドになったときにチェックすれば良い
    private(set) var isVerified: Bool = false {
        willSet {
            SwiftyLogger.debug("Interceptor: isVerified changed from \(isVerified) to \(newValue)")
        }
    }

    /// 証明書が信頼されているかどうか
    /// NOTE: アプリがフォアグラウンドになったときにチェックすれば良い
    private(set) var isTrusted: Bool = false {
        willSet {
            SwiftyLogger.debug("Interceptor: isTrusted changed from \(isTrusted) to \(newValue)")
        }
    }

    /// 通知設定が許可されているかどうか
    /// NOTE: アプリがフォアグラウンドになったときと、通知許可リクエストの直後にチェックすれば良い
    private(set) var isAuthorized: Bool = false {
        willSet {
            SwiftyLogger.debug("Interceptor: isAuthorized changed from \(isAuthorized) to \(newValue)")
        }
    }

    /// VPN構成のインストールを実行する
    /// NOTE: パスコード等の認証が必要になる
    /// NOTE: isVPNInstalledを更新する
    /// NOTE: マネージャがそもそもなければどうなるんだ感はあるが、新しく作られまくる心配がない
    func installVPN() async throws {
        try CaptureAuthorization.requireConsent()
        // 既に作成されていたら何もしない
        if manager != nil {
            return
        }
        let manager: NETunnelProviderManager = .init()
        manager.localizedDescription = "Interceptor"
        let configuration: NETunnelProviderProtocol = .init()
        configuration.providerBundleIdentifier = bundleIdentifier
        configuration.serverAddress = "Interceptor"
        manager.protocolConfiguration = configuration
        SwiftyLogger.debug(configuration)
        try await manager.saveToPreferences()
        self.manager = manager
    }

    /// ユーザーに通知の許可をリクエストする
    /// 拒否されている場合には設定を開く
    public func requestAuthorization(options: [UNNotificationPresentationOptions] = []) async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized {
            return
        }
        if settings.authorizationStatus == .notDetermined {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            return
        }
        await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }

    /// デフォルト設定でVPNトンネルを開始する
    func startVPNTunnel() async throws {
        try await startVPNTunnel(options: options)
    }

    /// VPNトンネルを開始する
    public func startVPNTunnel(options: [ProxyOption]) async throws {
        try CaptureAuthorization.requireConsent()
        SwiftyLogger.debug("Interceptor: Starting VPN Tunnel")
        // 一応マネージャーがあるかをチェックする
        guard let manager = try await NETunnelProviderManager.loadAllFromPreferences().first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.bundleIdentifier })
        else {
            throw NSError(domain: "Mudmouth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set up the Interceptor VPN before starting capture."])
        }
        // キャプチャするドメインを指定して鍵を生成する
        let keyPair: KeyPair = generateSiteKeyPair(hosts: options.targets(keyPath: \.capture))
        // VPN設定を有効化する
        manager.isEnabled = true
        // 何をしているのかはよくわからない
        try await manager.saveToPreferences()
        SwiftyLogger.debug("Interceptor: VPN Manager configured")

        SwiftyLogger.debug("Interceptor: \(NEVPNConnectionStartOptionPassword)")
        // サイト用の証明書をパスワードに同梱し、アプリに渡す
        // ついでにターゲット情報も渡す
        // ターゲットに合致したときにキャプチャしたパケットを渡す仕組み
        try CaptureAuthorization.requireConsent()
        try manager.connection.startVPNTunnel(options: [
            NEVPNConnectionProxyTargets: options.data as NSObject,
            NEVPNConnectionStartOptionPassword: keyPair.data as NSObject,
        ])
        generator.notificationOccurred(.success)
    }

    /// VPNトンネルを停止する
    /// アプリが復帰したときにVPNを無効化する
    @objc
    public func stopVPNTunnel() {
        SwiftyLogger.debug("Interceptor: Stopping VPN Tunnel")
        // 非同期関数はobjcで定義できないのでTaskでラップする
        Task(priority: .background, operation: {
            if let manager = try await NETunnelProviderManager.loadAllFromPreferences().first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.bundleIdentifier }) {
                manager.connection.stopVPNTunnel()
                generator.notificationOccurred(.success)
            }
        })
    }

    /// 指定されたNintendo Switch Appのコンテンツを開く
    /// NOTE: イカリング3とタヌポータルしか効かない
    /// - Parameter contentId: <#contentId description#>
    public func openURL(_ contentId: ContentId) {
        UIApplication.shared.open(URL(unsafeString: "com.nintendo.znca://znca/game/\(contentId.rawValue)"))
    }

    /// NOTE: アプリ起動時に証明書を発行する
    /// 多分失敗しないのであんまり気にしなくて大丈夫
    /// - Returns: <#description#>
    func generateCAKeyPair() {
        let privateKey: Certificate.PrivateKey = .default
        let certificate: Certificate = try! .init(privateKey)
        self.privateKey = privateKey
        self.certificate = certificate
    }

    /// サイト用の証明書を発行する
    /// NOTE: 現在は指定したサイトにのみ有効な設定
    /// - Parameter url: <#url description#>
    /// - Returns: <#description#>
    private func generateSiteKeyPair(hosts: [String]) -> KeyPair {
        // サイト用の鍵
        let caCertificateKey: Certificate.PrivateKey = .default
        let certificate: Certificate = try! .init(
            publicKey: caCertificateKey.publicKey,
            issuerPrivateKey: privateKey,
            issuer: certificate,
            hosts: hosts,
        )
        return .init(certificate: certificate, privateKey: caCertificateKey)
    }

    public init() {
        #if DEBUG || targetEnvironment(simulator)
        SwiftyLogger.debug("Mudmouth: Initializing in DEBUG mode")
        #else
        SwiftyLogger.debug("Mudmouth: Initializing in RELEASE mode")
        #endif
        let legacy = Keychain(service: Bundle.main.bundleIdentifier!).synchronizable(true)
        for key in ["privateKey", "certificate"] {
            if (try? keychain.getData(key, ignoringAttributeSynchronizable: false)) == nil,
               let data = try? legacy.getData(key, ignoringAttributeSynchronizable: false)
            {
                try? keychain.set(data, key: key)
            }
        }
        privateKey = {
            guard let privateKey = try? keychain.getPrivateKey()
            else {
                SwiftyLogger.warning("No private key found, generating a new one")
                return .default
            }
            return privateKey
        }()
        certificate = {
            guard let certificate = try? keychain.getCertificate()
            else {
                SwiftyLogger.warning("No certificate found, generating a new one")

                return try! .init(privateKey)
            }
            return certificate
        }()
        try? keychain.setPrivateKey(privateKey)
        try? keychain.setCertificate(certificate)
        NotificationCenter.default.addObserver(self, selector: #selector(statusDidChange), name: .NEVPNStatusDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForegroundNotification), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackgroundNotification), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActiveNotification), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// VPN接続が変化するたびに呼ばれる
    @objc
    private func statusDidChange() {
        SwiftyLogger.debug("Interceptor: VPN Status Changed")
        isConnected = getConnected()
    }

    /// アプリがフォアグラウンドになったときに呼ばれる
    /// NOTE: 起動時には呼ばれない
    @objc
    private func willEnterForegroundNotification() {
        SwiftyLogger.debug("Interceptor: WillEnterForegroundNotification")
    }

    /// アプリがバックグラウンドになったときに呼ばれる
    @objc
    private func didEnterBackgroundNotification() {
        SwiftyLogger.debug("Interceptor: DidEnterBackgroundNotification")
    }

    /// 起動時にも呼ばれる
    /// アプリがアクティブになるたびに毎回呼ばれる
    @objc
    private func didBecomeActiveNotification() {
        SwiftyLogger.debug("Interceptor: DidBecomeActiveNotification")
        isAPPInstalled = getAppInstalled()
        isVerified = getVerified()
        isTrusted = getTrusted()
        Task(priority: .background, operation: {
            self.isAuthorized = try await getAuthorized()
            // VPN設定を読み込んでマネージャをロードする
            // NOTE: VPN設定が有効かどうかのチェックはwillSetで実行するのでgetVPNInstalledは不要
            self.manager = try await NETunnelProviderManager.loadAllFromPreferences().first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.bundleIdentifier })
        })
    }
}

extension Mudmouth {
    /// Nintendo Switch Appがインストールされているかどうかをチェックする
    /// NOTE: いきなり呼んでも大丈夫でした
    /// NOTE: URLスキームが動作するかどうかでチェックしています
    /// - Returns: <#description#>
    private func getAppInstalled() -> Bool {
        SwiftyLogger.debug("Checking if Nintendo Switch Online App is installed")
        return UIApplication.shared.canOpenURL(URL(string: "com.nintendo.znca://")!)
    }

    /// 証明書がインストールされているかどうかをチェックする
    /// NOTE: いつ呼んでも大丈夫でした
    /// - Returns: <#description#>
    private func getVerified() -> Bool {
        SwiftyLogger.debug("Checking if certificate is installed")
        let der = certificate.derRepresentation
        let secCertificate = SecCertificateCreateWithData(nil, der as CFData)!
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(secCertificate, policy, &trust)
        guard status == errSecSuccess, let trust else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// 証明書が信頼されているかどうかをチェックする
    /// NOTE: 少し時間を置かないとチェックされない
    /// NOTE: 別のトリガーを用意したほうがいい気もする
    /// NOTE: 発行してすぐの証明書は時間の関係でnotValidBeforeがtrueになってしまうのが原因
    /// NOTE: めんどくさいのでその日の00:00:00をnotValidBeforeに設定しているので、相当タイミングが悪くないと一回も失敗しないはず
    /// - Returns: <#description#>
    private func getTrusted() -> Bool {
        SwiftyLogger.debug("Checking if certificate is trusted")
        let url: URL = .init(string: "http://localhost")!
        guard let certificate = SecCertificateCreateWithData(nil, generateSiteKeyPair(hosts: [url.host!]).certificate.derRepresentation as CFData)
        else {
            SwiftyLogger.error("Failed to create certificate from DER representation")
            return false
        }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, url.host! as NSString)
        let status = SecTrustCreateWithCertificates(certificate, policy, &trust)
        guard status == errSecSuccess, let trust else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// 通知が許可されているかをチェックする
    /// - Returns: <#description#>
    private func getAuthorized() async throws -> Bool {
        SwiftyLogger.debug("Checking if notifications are authorized")
        let settings: UNNotificationSettings = try await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    private func getConnected() -> Bool {
        manager?.connection.status == .connected
    }
}

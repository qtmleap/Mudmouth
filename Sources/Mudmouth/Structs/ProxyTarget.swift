//
//  ProxyTarget.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/13.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation

public struct ProxyTarget: Codable {
    public let host: String
    public let path: String
    public let script: String? = nil

    public init(url: URL) {
        host = url.host!
        path = url.path
    }

    public init(url value: String) {
        let url: URL = .init(unsafeString: value)
        host = url.host!
        path = url.path
    }
}

public struct ProxyOption: Codable, Identifiable, Sendable {
    public var id: String { host }
    /// ホスト
    public var host: String
    /// パス
    public var paths: [ProxyPath]
    /// キャプチャするかどうか
    public var capture: Bool
    /// キャプチャ時に通知するかどうか
    public var notify: Bool
    /// スクリプト
    public var script: String?

    public init(host: String, paths: [ProxyPath], capture: Bool = true, notify: Bool = true, script: String? = nil) {
        self.host = host
        self.paths = paths
        self.capture = capture
        self.notify = notify
        self.script = script
    }

    /// 条件がtrueになるパスを取得する
    /// NOTE: 面白い書き方だなって
    func targets(keyPath: KeyPath<ProxyPath, Bool>) -> [String] {
        paths.filter { $0[keyPath: keyPath] }.map(\.path)
    }
}

public struct ProxyPath: Codable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    /// パスごとの通知設定
    public var notify: Bool
    public var capture: Bool

    public init(path: String, capture: Bool = true, notify: Bool = true) {
        self.path = path
        self.capture = capture
        self.notify = notify
    }
}

/// REF: AppStorageにCodableを保存する時に気を付けたいパフォーマンスの話
/// NOTE: https://zenn.dev/noppe/articles/31a61bd3d17891
/// 比較時にイニシャライザが走らないようにするための処理
extension ProxyOption: Equatable {
    public static func == (lhs: ProxyOption, rhs: ProxyOption) -> Bool {
        lhs.host == rhs.host
    }
}

/// REF: AppStorageにCodableを保存する時に気を付けたいパフォーマンスの話
/// NOTE: https://zenn.dev/noppe/articles/31a61bd3d17891
/// 比較時にイニシャライザが走らないようにするための処理
extension ProxyPath: Equatable {
    public static func == (lhs: ProxyPath, rhs: ProxyPath) -> Bool {
        lhs.path == rhs.path
    }
}

extension [ProxyOption] {
    /// キャプチャする設定のオプションだけをエンコードして渡す
    var data: Data {
        let encoder: JSONEncoder = .init()
        return try! encoder.encode(filter(\.capture))
    }

    /// ホストを取得する
    func targets(keyPath: KeyPath<ProxyOption, Bool>) -> [String] {
        filter { $0[keyPath: keyPath] }.map(\.host)
    }
}

extension [ProxyTarget] {
    var hosts: [String] {
        map(\.host)
    }

    var data: Data {
        let encoder: JSONEncoder = .init()
        return try! encoder.encode(self)
    }
}

//
//  Record.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/16.
//

import Foundation
import NIOCore
import NIOHTTP1
import SwiftData

@Model
public final class RecordGroup: Identifiable {
    @Attribute(.unique)
    public var host: String

    @Relationship(deleteRule: .cascade, inverse: \Record.host)
    public var records: [Record]

    init(host: String, records: [Record]) {
        self.host = host
        self.records = records
    }
}

@Model
public final class Record: Identifiable {
    @Attribute(.unique) public var id: UUID
    public var capturedAt: Date = Date()
    public var method: String
    public var path: String
    public var host: RecordGroup?
    @Relationship(deleteRule: .cascade)
    public var request: HTTP.Request
    @Relationship(deleteRule: .cascade)
    public var response: HTTP.Response

    init(container: HTTP.MessageContainer) {
        id = .init()
        method = container.request.method
        path = container.request.path
        request = container.request
        response = container.response
    }

    init(method: HTTPMethod, path: String, request: HTTP.Request, response: HTTP.Response) {
        id = .init()
        self.method = method.rawValue
        self.path = path
        self.request = request
        self.response = response
    }

    public var queries: HTTP.Parameters {
        guard let url: URL = .init(string: path),
              let components: URLComponents = .init(url: url, resolvingAgainstBaseURL: false),
              let queryItems: [URLQueryItem] = components.queryItems
        else {
            return .init([])
        }
        return .init(queryItems.compactMap { queryItem in
            guard let value: String = queryItem.value else { return nil }
            return HTTP.Parameter(key: queryItem.name, value: value)
        }
        .sorted(by: { $0.key < $1.key }))
    }

    public var code: UInt {
        response.code
    }

    public var phrase: String {
        response.phrase
    }

    public var cookies: HTTP.Parameters {
        request.cookies
    }
}

public enum HTTP {
    public protocol Message {
        var header: Data { get }
        var data: Data? { get set }
        /// デコード済みのボディ
        var body: Data? { get }

        var headers: HTTP.Parameters { get }
    }

    struct MessageContainer: Sendable {
        var request: HTTP.Request
        /// ないってことはないと思う
        var response: HTTP.Response!
    }

    @dynamicMemberLookup
    public struct Parameters: Hashable, Codable {
        public let values: [Parameter]

        subscript(dynamicMember member: String) -> String? {
            values.first(where: { $0.key == member })?.value
        }

        public var isEmpty: Bool {
            values.isEmpty
        }

        init(_ values: [Parameter]) {
            self.values = values
        }
    }

    public struct Parameter: Hashable, Codable {
        public let key: String
        public let value: String
    }

    @Model
    public class Request: HTTP.Message, @unchecked Sendable {
        @Attribute(.unique)
        public var id: UUID
        public var version: String
        public var host: String
        public var path: String
        public var header: Data
        public var method: String
        public var data: Data?

        init(head: HTTPRequestHead) {
            id = .init()
            version = head.version.description
            host = head.host!
            path = head.uri
            method = head.method.rawValue
            header = head.headers.data
            data = nil
        }

        func add(_ buffer: ByteBuffer) {
            if data == nil {
                data = buffer.data
            } else {
                data?.append(contentsOf: buffer.data)
            }
        }

        /// リクエストのCookie
        public var cookies: HTTP.Parameters {
            guard let cookie: String = headers.values.first(where: { $0.key.lowercased() == "cookie" })?.value
            else {
                return .init([])
            }
            return .init(cookie
                .split(separator: ";")
                .compactMap { component in
                    let components: [String] = component.split(separator: "=", maxSplits: 1).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }
                    return components.count == 2 ? .init(key: components[0], value: components[1]) : .init(key: components[0], value: "true")
                }
                .reduce(into: [String: HTTP.Parameter]()) { result, cookie in
                    result[cookie.key] = cookie
                }
                .values
                .sorted(by: { $0.key < $1.key }))
        }
    }

    @Model
    public class Response: HTTP.Message, @unchecked Sendable {
        @Attribute(.unique)
        public var id: UUID
        public var header: Data
        public var data: Data?
        public var code: UInt
        public var phrase: String

        init(head: HTTPResponseHead) {
            id = .init()
            code = head.status.code
            phrase = head.status.reasonPhrase
            header = head.headers.data
            data = nil
        }

        func add(_ buffer: ByteBuffer) {
            if data == nil {
                data = buffer.data
            } else {
                data?.append(contentsOf: buffer.data)
            }
        }

        /// レスポンスのCookie
        public var cookies: HTTP.Parameters {
            guard let cookie: String = headers.values.first(where: { $0.key.lowercased() == "set-cookie" })?.value
            else {
                return .init([])
            }
            return .init(cookie
                .split(separator: ";")
                .compactMap { component in
                    let components: [String] = component.split(separator: "=", maxSplits: 1).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }
                    return components.count == 2 ? .init(key: components[0], value: components[1]) : .init(key: components[0], value: "true")
                }
                .reduce(into: [String: HTTP.Parameter]()) { result, cookie in
                    result[cookie.key] = cookie
                }
                .values
                .sorted(by: { $0.key < $1.key }))
        }
    }
}

public extension HTTP.Message {
    var headers: HTTP.Parameters {
        guard let headers = try? JSONSerialization.jsonObject(with: header) as? [String: String]
        else {
            return .init([])
        }
        return .init(headers.map { .init(key: $0.key, value: $0.value) }.sorted(by: { $0.key < $1.key }))
    }

    var encoding: String? {
        guard let value = headers.values.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        else {
            return nil
        }
        return value.lowercased()
    }

    var body: Data? {
        guard let data: Data = data
        else {
            return nil
        }
        return encoding == "gzip" ? try? data.gunzipped() : data
    }

    var json: String? {
        guard let data: Data = body,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let data: Data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

public struct HTTPHeader: Identifiable, Hashable {
    public var id: String {
        key
    }

    public let key: String
    public let value: String
}

extension HTTPHeaders {
    var dictionary: [String: String] {
        Dictionary(map { ($0.name, $0.value) }, uniquingKeysWith: { "\($0); \($1)" })
    }

    var data: Data {
        try! JSONSerialization.data(withJSONObject: dictionary)
    }
}

public extension RecordGroup {
    convenience init() {
        let headers: HTTPHeaders = .init([
            ("Host", "http://localhost/"),
            ("Content-Type", "application/json"),
        ])
        self.init(host: "localhost", records: [
            .init(method: .GET, path: "/", request: .init(head: .init(version: .http3, method: .GET, uri: "http://localhost/", headers: headers)), response: .init(head: .init(version: .http3, status: .ok))),
            .init(method: .POST, path: "/", request: .init(head: .init(version: .http3, method: .POST, uri: "http://localhost/", headers: headers)), response: .init(head: .init(version: .http3, status: .ok))),
            .init(method: .PATCH, path: "/", request: .init(head: .init(version: .http3, method: .PATCH, uri: "http://localhost/", headers: headers)), response: .init(head: .init(version: .http3, status: .ok))),
            .init(method: .PUT, path: "/", request: .init(head: .init(version: .http3, method: .PUT, uri: "http://localhost/", headers: headers)), response: .init(head: .init(version: .http3, status: .ok))),
        ])
    }
}

import Foundation
@testable import Mudmouth
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

final class CaptureHandlerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CaptureLifecycleEvent] = []
        var events: [CaptureLifecycleEvent] {
            lock.withLock { storage }
        }

        func offer(_ event: CaptureLifecycleEvent) -> Bool {
            lock.withLock { storage.append(event) }; return true
        }
    }

    /// Argument-domain overrides are process-local and never change persisted
    /// app-group consent or another process's running capture session.
    private func withConsent(_ granted: Bool, body: (UserDefaults) throws -> Void) rethrows {
        let store = CaptureAuthorization.defaults
        let previous = store.volatileDomain(forName: UserDefaults.argumentDomain)
        var overridden = previous
        overridden[CaptureAuthorization.key] = granted ? CaptureAuthorization.version : 0
        store.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        defer { store.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        try body(store)
    }

    func testValidatedConnectAuthorityFlowsToActualProxyHandler() throws {
        try withConsent(true) { _ in
            let recorder = Recorder()
            let shared = CaptureConnectionContext()
            let connect = ConnectHandler(allowedHosts: ["example.com"], captureContext: shared)
            let proxy = ProxyHandler(captureContext: shared, eventSink: recorder.offer)
            let connectChannel = EmbeddedChannel(handler: connect)
            let channel = EmbeddedChannel(handler: proxy)
            defer {
                _ = try? connectChannel.finish(acceptAlreadyClosed: true)
                _ = try? channel.finish(acceptAlreadyClosed: true)
            }
            // EmbeddedChannel performs no socket I/O. Stop before CONNECT end,
            // where the production handler would start its real upstream TLS.
            let outer = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "EXAMPLE.com:443")
            try connectChannel.writeInbound(HTTPServerRequestPart.head(outer))
            XCTAssertEqual(shared.authority?.host, "example.com")
            // Separate embedded channels represent the CONNECT decoder and the
            // decrypted HTTP boundary; both real handlers receive the same context.
            let inner = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/upload", headers: HTTPHeaders([("Host", "example.com")]))
            try channel.writeInbound(HTTPServerRequestPart.head(inner))
            try channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "first")))
            try channel.writeOutbound(HTTPClientResponsePart.head(.init(version: .http1_1, status: .init(statusCode: 413))))
            try channel.writeOutbound(HTTPClientResponsePart.end(nil))
            try channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(string: "last")))
            try channel.writeInbound(HTTPServerRequestPart.end(nil))
            XCTAssertEqual(recorder.events.map(\.phase), [.requestHeaders, .responseHeaders, .responseCompleted, .requestCompleted])
            XCTAssertEqual(recorder.events.last?.request.body, .complete(Data("firstlast".utf8)))
            guard case let .head(forwarded)? = try channel.readInbound(as: HTTPClientRequestPart.self) else {
                return XCTFail("Original request was not forwarded")
            }
            XCTAssertEqual(forwarded.uri, "/upload")
            XCTAssertEqual(forwarded.headers.first(name: "Host"), "example.com")
        }
    }

    func testNilSinkForwardsRequestAndResponseWithoutCaptureProvenance() throws {
        try withConsent(true) { _ in
            let channel = EmbeddedChannel(handler: ProxyHandler())
            defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
            let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/plain", headers: HTTPHeaders([("Host", "example.com")]))
            try channel.writeInbound(HTTPServerRequestPart.head(request))
            try channel.writeInbound(HTTPServerRequestPart.end(nil))
            try channel.writeOutbound(HTTPClientResponsePart.head(.init(version: .http1_1, status: .ok)))
            try channel.writeOutbound(HTTPClientResponsePart.end(nil))
            guard case let .head(head)? = try channel.readInbound(as: HTTPClientRequestPart.self) else { return XCTFail("Missing forwarded request") }
            XCTAssertEqual(head.uri, "/plain")
            guard case .end? = try channel.readInbound(as: HTTPClientRequestPart.self) else { return XCTFail("Missing request end") }
            guard case let .head(response)? = try channel.readOutbound(as: HTTPServerResponsePart.self) else { return XCTFail("Missing forwarded response") }
            XCTAssertEqual(response.status, .ok)
            guard case .end? = try channel.readOutbound(as: HTTPServerResponsePart.self) else { return XCTFail("Missing response end") }
        }
    }

    func testConsentRevocationClosesActualProxyBeforeAnotherCaptureOrForward() throws {
        try withConsent(true) { store in
            let recorder = Recorder()
            let shared = CaptureConnectionContext()
            shared.authority = CaptureHTTPSAuthority(connectAuthority: "example.com:443")
            let channel = EmbeddedChannel(handler: ProxyHandler(captureContext: shared, eventSink: recorder.offer))
            defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
            XCTAssertTrue(channel.isActive)
            var revoked = store.volatileDomain(forName: UserDefaults.argumentDomain)
            revoked[CaptureAuthorization.key] = 0
            store.setVolatileDomain(revoked, forName: UserDefaults.argumentDomain)
            XCTAssertFalse(CaptureAuthorization.isGranted)
            let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: HTTPHeaders([("Host", "example.com")]))
            try channel.writeInbound(HTTPServerRequestPart.head(request))
            XCTAssertFalse(channel.isActive)
            XCTAssertTrue(recorder.events.isEmpty)
            XCTAssertNil(try channel.readInbound(as: HTTPClientRequestPart.self))
        }
    }
}

import Foundation
@testable import Mudmouth
import XCTest

final class CaptureLifecycleTests: XCTestCase {
    /// A thread-safe recorder keeps the production sink's Sendable contract intact.
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

    private func headers(_ host: String = "example.com") -> [HeaderField] {
        [.init(name: "Host", value: host), .init(name: "Cookie", value: "a=1"), .init(name: "Cookie", value: "b=2")]
    }

    func testRequestEventsDoNotWaitForResponseAndPreserveDuplicateHeaders() throws {
        let recorder = Recorder()
        let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "EXAMPLE.com:443")), sink: recorder.offer)
        capture.requestHead(method: "POST", encodedTarget: "/api?a=1&a=2", headers: headers())
        XCTAssertEqual(recorder.events.map(\.phase), [.requestHeaders])
        capture.requestBody(Data("hello".utf8))
        capture.requestEnd()
        XCTAssertEqual(recorder.events.map(\.phase), [.requestHeaders, .requestCompleted])
        let request = try XCTUnwrap(recorder.events.last?.request)
        XCTAssertEqual(request.authority.host, "example.com")
        XCTAssertEqual(request.authority.port, 443)
        XCTAssertEqual(request.headers.map(\.name), ["host", "cookie", "cookie"])
        XCTAssertEqual(request.headers.map(\.value), ["example.com", "a=1", "b=2"])
        XCTAssertEqual(request.encodedTarget, "/api?a=1&a=2")
        XCTAssertEqual(request.body, .complete(Data("hello".utf8)))
        XCTAssertEqual(Set(recorder.events.map(\.eventID)).count, 2)
        XCTAssertEqual(Set(recorder.events.map(\.exchangeID)).count, 1)
    }

    func testPipelinedResponsesRetainTheirOriginalRequestAndIgnoreInformationalResponses() throws {
        let recorder = Recorder()
        let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
        capture.requestHead(method: "GET", encodedTarget: "/one", headers: headers()); capture.requestEnd()
        capture.requestHead(method: "GET", encodedTarget: "/two", headers: headers()); capture.requestEnd()
        capture.responseHead(status: 100, headers: []); capture.responseEnd()
        XCTAssertEqual(recorder.events.count, 4)
        capture.responseHead(status: 200, headers: [.init(name: "Set-Cookie", value: "a=1"), .init(name: "Set-Cookie", value: "b=2")])
        capture.responseBody(Data("one".utf8)); capture.responseEnd()
        capture.responseHead(status: 204, headers: []); capture.responseEnd()
        XCTAssertEqual(recorder.events.suffix(4).map(\.request.encodedTarget), ["/one", "/one", "/two", "/two"])
        XCTAssertEqual(recorder.events[5].response?.body, .complete(Data("one".utf8)))
        XCTAssertEqual(recorder.events[7].response?.body, .absent)
        XCTAssertEqual(recorder.events[5].request.body, .absent)
        XCTAssertEqual(recorder.events[5].response?.headers.map(\.value), ["a=1", "b=2"])
    }

    func testHostAdmissionRejectsMissingDuplicateConflictingAndMalformedAuthority() throws {
        for bad in [[], [.init(name: "Host", value: "other.com")], [.init(name: "Host", value: "example.com"), .init(name: "Host", value: "example.com")], [.init(name: "Host", value: "example.com:444")]] as [[HeaderField]] {
            let recorder = Recorder()
            let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
            capture.requestHead(method: "GET", encodedTarget: "/", headers: bad); capture.requestEnd()
            capture.responseHead(status: 200, headers: []); capture.responseEnd()
            XCTAssertTrue(recorder.events.isEmpty)
        }
        for invalid in ["example.com:80", "example.com:443@evil.com", "https://example.com:443", "bad..com:443", "example.com:443/path", "example.com\r:443"] {
            XCTAssertNil(CaptureHTTPSAuthority(connectAuthority: invalid), invalid)
        }
    }

    func testBodyCapAndIncompleteBodyNeverProduceCompletePartialBytes() throws {
        for count in [32_767, 32_768, 32_769] {
            let recorder = Recorder()
            let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
            capture.requestHead(method: "POST", encodedTarget: "/", headers: headers())
            capture.requestBody(Data(repeating: 65, count: count)); capture.requestEnd()
            XCTAssertEqual(recorder.events.last?.request.body, count <= 32_768 ? .complete(Data(repeating: 65, count: count)) : .truncated)
        }
        let recorder = Recorder()
        let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
        capture.requestHead(method: "POST", encodedTarget: "/", headers: headers()); capture.requestBody(Data("partial".utf8)); capture.finish()
        XCTAssertEqual(recorder.events.map(\.phase), [.requestHeaders])
        XCTAssertEqual(recorder.events.first?.request.body, .unavailable(.notCaptured))
    }

    func testCompressedBodyIsUnavailableAndRejectedOffersDoNotStopLifecycle() throws {
        let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: { _ in false })
        capture.requestHead(method: "POST", encodedTarget: "/", headers: headers()); capture.requestEnd()
        XCTAssertEqual(capture.rejectedOffers, 2)
        let recorder = Recorder()
        let encoded = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
        encoded.requestHead(method: "POST", encodedTarget: "/", headers: headers() + [.init(name: "Content-Encoding", value: "gzip")])
        encoded.requestBody(Data([31, 139])); encoded.requestEnd()
        XCTAssertEqual(recorder.events.last?.request.body, .unavailable(.unsupportedEncoding))
    }

    func testInvalidHeadersTargetsAndSaturatedPipelineRejectAdmission() throws {
        for bad in [[HeaderField(name: "Bad Name", value: "v")], [.init(name: "x", value: "a\r\nb")], [.init(name: "Connection", value: "ok,,bad")], [.init(name: "x", value: String(repeating: "a", count: 8_192))]] {
            let recorder = Recorder()
            let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
            capture.requestHead(method: "GET", encodedTarget: "/", headers: headers() + bad); capture.requestEnd()
            XCTAssertTrue(recorder.events.isEmpty)
        }
        for target in ["//evil.com/", "https://evil.com/", "/#fragment", "/bad%", "/" + String(repeating: "x", count: 8_192)] {
            let recorder = Recorder()
            let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
            capture.requestHead(method: "GET", encodedTarget: target, headers: headers()); capture.requestEnd()
            XCTAssertTrue(recorder.events.isEmpty, target)
        }
        let recorder = Recorder()
        let capture = try CaptureLifecycleAccumulator(authority: XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443")), sink: recorder.offer)
        for _ in 0 ..< 33 {
            capture.requestHead(method: "GET", encodedTarget: "/", headers: headers()); capture.requestEnd()
        }
        XCTAssertEqual(recorder.events.count, 64)
        XCTAssertEqual(capture.droppedPipelineExchanges, 1)
        for _ in 0 ..< 33 {
            capture.responseHead(status: 200, headers: []); capture.responseEnd()
        }
        XCTAssertEqual(recorder.events.count, 128)
        capture.requestHead(method: "GET", encodedTarget: "/fresh", headers: headers()); capture.requestEnd()
        capture.responseHead(status: 204, headers: []); capture.responseEnd()
        XCTAssertEqual(recorder.events.suffix(4).map(\.request.encodedTarget), ["/fresh", "/fresh", "/fresh", "/fresh"])
        XCTAssertEqual(recorder.events.count, 132)
    }

    func testEarlyFinalResponseKeepsRequestBodyUntilRequestEnd() throws {
        let recorder = Recorder()
        let authority = try XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443"))
        let capture = CaptureLifecycleAccumulator(authority: authority, sink: recorder.offer)
        capture.requestHead(method: "POST", encodedTarget: "/upload", headers: headers())
        capture.requestBody(Data("first".utf8))
        capture.responseHead(status: 413, headers: [])
        capture.responseEnd()
        capture.requestBody(Data("last".utf8))
        capture.requestEnd()
        XCTAssertEqual(recorder.events.map(\.phase), [.requestHeaders, .responseHeaders, .responseCompleted, .requestCompleted])
        XCTAssertEqual(recorder.events.last?.request.body, .complete(Data("firstlast".utf8)))
        XCTAssertEqual(Set(recorder.events.map(\.exchangeID)).count, 1)
        capture.requestHead(method: "GET", encodedTarget: "/next", headers: headers()); capture.requestEnd()
        capture.responseHead(status: 204, headers: []); capture.responseEnd()
        XCTAssertEqual(recorder.events.suffix(4).map(\.request.encodedTarget), ["/next", "/next", "/next", "/next"])
    }

    func testEncodedTargetAndSerializedHeaderBoundsIncludeExactLimit() throws {
        let authority = try XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443"))
        for size in [8_191, 8_192, 8_193] {
            let targetRecorder = Recorder()
            let targetCapture = CaptureLifecycleAccumulator(authority: authority, sink: targetRecorder.offer)
            targetCapture.requestHead(method: "GET", encodedTarget: "/" + String(repeating: "a", count: size - 1), headers: headers())
            targetCapture.requestEnd()
            XCTAssertEqual(targetRecorder.events.count, size <= 8_192 ? 2 : 0, "target size \(size)")
            let headerRecorder = Recorder()
            let headerCapture = CaptureLifecycleAccumulator(authority: authority, sink: headerRecorder.offer)
            // This literal pair array has 63 bytes before adding the x field value.
            headerCapture.requestHead(method: "GET", encodedTarget: "/", headers: [
                .init(name: "host", value: "example.com"), .init(name: "x", value: String(repeating: "a", count: size - 63)),
            ])
            headerCapture.requestEnd()
            XCTAssertEqual(headerRecorder.events.count, size <= 8_192 ? 2 : 0, "header size \(size)")
        }
    }

    func testIncompleteAndOverLimitResponseBodiesDoNotBecomeComplete() throws {
        let authority = try XCTUnwrap(CaptureHTTPSAuthority(connectAuthority: "example.com:443"))
        for size in [32_767, 32_768, 32_769] {
            let recorder = Recorder()
            let capture = CaptureLifecycleAccumulator(authority: authority, sink: recorder.offer)
            capture.requestHead(method: "GET", encodedTarget: "/", headers: headers()); capture.requestEnd()
            capture.responseHead(status: 500, headers: [])
            capture.responseBody(Data(repeating: 65, count: size)); capture.responseEnd()
            XCTAssertEqual(recorder.events.last?.response?.body, size <= 32_768 ? .complete(Data(repeating: 65, count: size)) : .truncated)
        }
        let recorder = Recorder()
        let capture = CaptureLifecycleAccumulator(authority: authority, sink: recorder.offer)
        capture.requestHead(method: "GET", encodedTarget: "/", headers: headers()); capture.requestEnd()
        capture.responseHead(status: 200, headers: [.init(name: "Content-Length", value: "12")])
        capture.responseBody(Data("partial".utf8)); capture.finish()
        XCTAssertEqual(recorder.events.map(\.phase), [.requestHeaders, .requestCompleted, .responseHeaders])
        XCTAssertEqual(recorder.events.last?.response?.body, .unavailable(.notCaptured))
    }
}

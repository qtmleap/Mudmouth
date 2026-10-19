//
//  BypassAndOverflowTests.swift
//  MudmouthHTTPHooksTests
//
//  Match gating, unsupported bodies, overflow replay, interim/HEAD/204/304 and upgrade bypass.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class BypassAndOverflowTests: XCTestCase {
    // MARK: Match gating

    func testUnmatchedTrafficStreamsPartByPartWithoutBufferingOrCallbacks() async throws {
        try await Rig.run(configure: { $0.matcher = { _ in false } }) { rig in
            try await rig.sendRequest(.head(Fixture.requestHead(contentLength: 20)))
            let head = try await rig.waitUpstream(1)
            XCTAssertEqual(head.count, 1, "the head of unmatched traffic is forwarded before the body arrives")
            try await rig.sendRequest(.body(Fixture.buffer("0123456789")))
            try await expectEqual(rig.waitUpstream(2).last, .body("0123456789"), "body parts stream through unbuffered")
            try await rig.sendRequest(.body(Fixture.buffer("0123456789")), .end(nil))
            try await expectEqual(rig.waitUpstream(4).last, .end)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls.isEmpty)
            XCTAssertEqual(rig.processor.authorizationCheckCount, 0)
        }
    }

    func testUnmatchedResponseStreamsAndNoProcessorMeansPlainProxy() async throws {
        try await Rig.run(installProcessor: false) { rig in
            try await rig.sendRequest(.head(Fixture.requestHead(contentLength: 0)), .end(nil))
            _ = try await rig.waitUpstream(2)
            try await rig.sendResponse(.head(Fixture.responseHead(contentLength: 10)))
            try await expectEqual(rig.waitDownstream(1).count, 1)
            try await rig.sendResponse(.body(Fixture.buffer("0123456789")), .end(nil))
            try await expectEqual(rig.waitDownstream(3).last, .end)
        }
    }

    func testMatchSeesTheHeadWithAnEmptyBodyAndRunsOncePerRequest() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            _ = try await rig.waitUpstream(3)
            XCTAssertEqual(rig.processor.matchedHeads.count, 1)
            XCTAssertEqual(rig.processor.matchedHeads[0].body, Data())
        }
    }

    // MARK: Ineligible bodies bypass

    private func assertBypass(
        head: HTTPRequestHead, body: String, file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        try await Rig.run { rig in
            try await rig.sendRequest(.head(head), .body(Fixture.buffer(body)), .end(nil))
            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire[1], .body(body), "bypassed body must be byte-identical", file: file, line: line)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.requestEnter).isEmpty, "no body hook for an ineligible message", file: file, line: line)
        }
    }

    func testNonJSONContentTypeBypasses() async throws {
        try await assertBypass(head: Fixture.requestHead(contentType: "text/plain", contentLength: 5), body: "hello")
    }

    func testMissingContentTypeBypasses() async throws {
        try await assertBypass(head: Fixture.requestHead(contentType: nil, contentLength: 8), body: #"{"a":1}"#)
    }

    func testCompressedBodyBypasses() async throws {
        try await assertBypass(
            head: Fixture.requestHead(contentLength: 7, extra: [("Content-Encoding", "gzip")]), body: #"{"a":1}"#,
        )
    }

    func testPlusJSONContentTypeIsEligible() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            try await rig.sendRequest(
                .head(Fixture.requestHead(contentType: "application/vnd.api+json; charset=utf-8", contentLength: Fixture.json.utf8.count)),
                .body(Fixture.buffer(Fixture.json)), .end(nil),
            )
            try await expectEqual(rig.waitUpstream(3)[1], .body(Fixture.mutated))
        }
    }

    func testIdentityContentEncodingIsEligible() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            try await rig.sendRequest(
                .head(Fixture.requestHead(contentLength: Fixture.json.utf8.count, extra: [("Content-Encoding", "identity")])),
                .body(Fixture.buffer(Fixture.json)), .end(nil),
            )
            try await expectEqual(rig.waitUpstream(3)[1], .body(Fixture.mutated))
        }
    }

    func testNonUTF8BodyBypasses() async throws {
        try await Rig.run { rig in
            let bytes: [UInt8] = [0x7B, 0x22, 0xFF, 0xFE, 0x22, 0x7D]
            try await rig.sendRequest(
                .head(Fixture.requestHead(contentLength: bytes.count)), .body(ByteBuffer(bytes: bytes)), .end(nil),
            )
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.requestEnter).isEmpty)
            let wire = try await rig.collectUpstream()
            XCTAssertEqual(wire.count, 3)
        }
    }

    func testInvalidJSONBodyBypasses() async throws {
        try await assertBypass(head: Fixture.requestHead(contentLength: 8), body: #"{"a":1,}"#)
    }

    func testUnsafeNumberJSONBypasses() async throws {
        let body = #"{"id":12345678901234567890}"#
        try await assertBypass(head: Fixture.requestHead(contentLength: body.utf8.count), body: body)
    }

    func testExpectContinueBypassesAndForwardsHeadImmediately() async throws {
        try await Rig.run { rig in
            try await rig.sendRequest(.head(Fixture.requestHead(contentLength: 7, extra: [("Expect", "100-continue")])))
            let head = try await rig.waitUpstream(1)
            XCTAssertEqual(head.count, 1, "the peer must see the head now or it never sends 100 Continue")
            try await rig.sendRequest(.body(Fixture.buffer(#"{"a":1}"#)), .end(nil))
            _ = try await rig.waitUpstream(3)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.requestEnter).isEmpty)
        }
    }

    func testBodylessRequestIsForwardedWithoutBodyHook() async throws {
        try await Rig.run { rig in
            try await rig.sendRequest(.head(Fixture.requestHead(.GET, contentType: nil, contentLength: nil)), .end(nil))
            try await expectEqual(rig.waitUpstream(2).count, 2)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.requestEnter).isEmpty)
        }
    }

    // MARK: Overflow

    func testRequestBodyOverCapReplaysOriginalPartsWithoutTruncationOrHooks() async throws {
        let limits = HTTPHookLimits(bodyBytes: 16)
        try await Rig.run(limits: limits) { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            let part1 = #"{"items":["aaaa","#
            let part2 = #""bbbb","cccc"]}"#
            try await rig.sendRequest(
                .head(Fixture.chunkedRequestHead()), .body(Fixture.buffer(part1)), .body(Fixture.buffer(part2)), .end(nil),
            )

            let wire = try await rig.waitUpstream(4)
            XCTAssertEqual(wire[0].headers["transfer-encoding"], "chunked", "original framing replayed")
            XCTAssertEqual(Array(wire[1...]), [.body(part1), .body(part2), .end], "original parts, in order, untruncated")
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.requestEnter).isEmpty, "an overflowed message never reaches a callback")
        }
    }

    func testDeclaredContentLengthOverCapBypassesBeforeBuffering() async throws {
        let limits = HTTPHookLimits(bodyBytes: 16)
        try await Rig.run(limits: limits) { rig in
            try await rig.sendRequest(.head(Fixture.requestHead(contentLength: 1000)))
            try await expectEqual(rig.waitUpstream(1).count, 1, "oversize declared length streams immediately")
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls.isEmpty)
        }
    }

    func testBodyExactlyAtCapIsEligible() async throws {
        let body = #"{"limit":10}"# // 12 bytes
        let limits = HTTPHookLimits(bodyBytes: body.utf8.count)
        try await Rig.run(limits: limits) { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            try await rig.sendPost(body)
            try await expectEqual(rig.waitUpstream(3)[1], .body(Fixture.mutated))
        }
    }

    func testConnectionBufferCapOverflowReplaysOriginalsWithoutHooks() async throws {
        // Body cap is generous, the connection-wide cap is what trips.
        let limits = HTTPHookLimits(bodyBytes: 1024, bufferedBytes: 24)
        try await Rig.run(limits: limits) { rig in
            let body = #"{"items":["aaaaaaaaaaaaaaaaaaaa"]}"#
            try await rig.sendRequest(
                .head(Fixture.chunkedRequestHead()),
                .body(Fixture.buffer(String(body.prefix(14)))),
                .body(Fixture.buffer(String(body.dropFirst(14)))),
                .end(nil),
            )
            let wire = try await rig.waitUpstream(4)
            let replay = wire.compactMap {
                part -> String? in if case let .body(text) = part {
                    text
                } else {
                    nil
                }
            }.joined()
            XCTAssertEqual(replay, body)
            XCTAssertTrue(rig.processor.calls(.requestEnter).isEmpty)
        }
    }

    func testResponseBodyOverCapReplaysOriginalWithoutHooks() async throws {
        let limits = HTTPHookLimits(bodyBytes: 16)
        try await Rig.run(limits: limits) { rig in
            try await rig.sendPost(Fixture.json)
            try await expectTrue(rig.waitForPhase(.requestLeave))
            let a = #"{"items":["aaaa","#
            let b = #""bbbb","cccc"]}"#
            try await rig.sendResponse(
                .head(Fixture.responseHead(contentLength: nil, extra: [("Transfer-Encoding", "chunked")])),
                .body(Fixture.buffer(a)), .body(Fixture.buffer(b)), .end(nil),
            )
            let wire = try await rig.waitDownstream(4)
            XCTAssertEqual(Array(wire[1...]), [.body(a), .body(b), .end])
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
        }
    }

    // MARK: Interim, HEAD, 204, 304

    func testInterimResponseDoesNotConsumeTheRequestAssociation() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendResponse(.head(Fixture.responseHead(.continue, contentType: nil, contentLength: nil)))
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty, "1xx is not a final response")
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            try await expectTrue(rig.waitForPhase(.responseEnter))
            let call = try XCTUnwrap(rig.processor.calls(.responseEnter).first)
            XCTAssertEqual(call.request.id, rig.processor.calls(.requestEnter)[0].request.id)
            XCTAssertEqual(call.response?.status, 200)
            let down = try await rig.waitDownstream(4)
            XCTAssertEqual(down.first, .responseHead(status: 100, headers: [:]), "interim response is forwarded as-is")
        }
    }

    func testHeadResponseBypassesBodyHooks() async throws {
        try await Rig.run { rig in
            try await rig.sendRequest(.head(Fixture.requestHead(.HEAD, contentType: nil, contentLength: nil)), .end(nil))
            _ = try await rig.waitUpstream(2)
            try await rig.sendResponse(.head(Fixture.responseHead(contentLength: 11)), .end(nil))
            let down = try await rig.waitDownstream(2)
            XCTAssertEqual(down[0].headers["content-length"], "11", "HEAD framing is untouched")
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
        }
    }

    func testNoContentAndNotModifiedResponsesBypassBodyHooks() async throws {
        for status in [HTTPResponseStatus.noContent, .notModified] {
            try await Rig.run { rig in
                try await rig.sendPost()
                try await expectTrue(rig.waitForPhase(.requestLeave))
                try await rig.sendResponse(.head(Fixture.responseHead(status, contentType: nil, contentLength: nil)), .end(nil))
                let down = try await rig.waitDownstream(2)
                XCTAssertEqual(down.count, 2)
                try await rig.quiet()
                XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty, "\(status)")
            }
        }
    }

    // MARK: Unsupported protocols

    func testUpgradeRequestIsRefusedBeforeMatching() async throws {
        try await Rig.run { rig in
            try await rig.sendRequest(
                .head(Fixture.requestHead(.GET, contentType: nil, contentLength: nil, extra: [("Connection", "Upgrade"), ("Upgrade", "websocket")])),
            )
            try await expectEqual(rig.waitDownstream(2).count, 2)
            XCTAssertEqual(rig.sentUpstream, [])
            try await expectTrue(rig.waitForClose())
            XCTAssertTrue(rig.processor.calls.isEmpty)
            XCTAssertTrue(rig.processor.matchedHeads.isEmpty)
        }
    }

    func testSwitchingProtocolsResponseWithoutUpgradeHeaderCloses() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendResponse(.head(Fixture.responseHead(.switchingProtocols, contentType: nil, contentLength: nil)))
            try await expectTrue(rig.waitForClose())
            XCTAssertEqual(rig.sentDownstream, [])
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
        }
    }

    func testNestedConnectRequestIsRefusedBeforeMatching() async throws {
        try await Rig.run { rig in
            try await rig.sendRequest(.head(Fixture.requestHead(.CONNECT, uri: "other.example.com:443", contentType: nil, contentLength: nil)))
            try await expectEqual(rig.waitDownstream(2).count, 2)
            XCTAssertEqual(rig.sentUpstream, [])
            try await expectTrue(rig.waitForClose())
            XCTAssertTrue(rig.processor.calls.isEmpty)
            XCTAssertTrue(rig.processor.matchedHeads.isEmpty)
        }
    }
}

//
//  MutationFramingTests.swift
//  MudmouthHTTPHooksTests
//
//  Body-only mutation, framing repair, unchanged wire bytes, errors and recording of what was forwarded.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class MutationFramingTests: XCTestCase {
    func testChangedRequestBodyRepairsContentLengthAndKeepsOtherHeaders() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(#"{"limit":5,"extra":"é"}"#.utf8)))
            try await rig.sendPost()

            let wire = try await rig.waitUpstream(3)
            let newBody = #"{"limit":5,"extra":"é"}"#
            guard case let .requestHead(method, uri, headers) = wire[0] else { return XCTFail("head expected") }
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(uri, "/search?q=1", "URL and method are never changed")
            XCTAssertEqual(headers["content-length"], "\(newBody.utf8.count)", "UTF-8 byte count, not character count")
            XCTAssertEqual(headers["host"], "api.example.com")
            XCTAssertEqual(headers["content-type"], "application/json")
            XCTAssertEqual(wire[1], .body(newBody))
            XCTAssertEqual(wire[2], .end)
        }
    }

    func testChangedChunkedRequestIsReframedWithContentLengthAndNoTransferEncoding() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            try await rig.sendRequest(
                .head(Fixture.chunkedRequestHead()),
                .body(Fixture.buffer(#"{"lim"#)),
                .body(Fixture.buffer(#"it":10}"#)),
                .end(nil),
            )

            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire[0].headers["content-length"], "\(Fixture.mutated.utf8.count)")
            XCTAssertNil(wire[0].headers["transfer-encoding"], "never send both framing headers")
            XCTAssertEqual(wire[1], .body(Fixture.mutated))
            XCTAssertEqual(rig.processor.calls(.requestEnter).first.map { String(data: $0.request.body, encoding: .utf8) }, Fixture.json,
                           "chunks are joined before the callback")
        }
    }

    func testNoopKeepsOriginalWireBytesAndFramingExactly() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(nil))
            try await rig.sendRequest(
                .head(Fixture.chunkedRequestHead()),
                .body(Fixture.buffer(#"{"lim"#)),
                .body(Fixture.buffer(#"it":10}"#)),
                .end(nil),
            )

            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire[0].headers["transfer-encoding"], "chunked", "unchanged messages keep their framing")
            XCTAssertNil(wire[0].headers["content-length"])
            let body = wire.compactMap {
                part -> String? in if case let .body(text) = part {
                    text
                } else {
                    nil
                }
            }.joined()
            XCTAssertEqual(body, Fixture.json)
            XCTAssertEqual(wire.last, .end)
        }
    }

    func testReturningIdenticalBytesIsTreatedAsUnchanged() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.json.utf8)))
            try await rig.sendRequest(
                .head(Fixture.chunkedRequestHead()),
                .body(Fixture.buffer(Fixture.json)),
                .end(nil),
            )
            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire[0].headers["transfer-encoding"], "chunked")
            XCTAssertNil(wire[0].headers["content-length"])
        }
    }

    func testChangedResponseRepairsFramingAndLeavesStatusAndHeadersAlone() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.responseEnter, .success(Data(#"{"maintenance":true}"#.utf8)))
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendResponse(
                .head(Fixture.responseHead(.accepted, contentLength: nil, extra: [("Transfer-Encoding", "chunked"), ("X-Trace", "abc")])),
                .body(Fixture.buffer(#"{"ok":"#)),
                .body(Fixture.buffer("true}")),
                .end(nil),
            )

            let wire = try await rig.waitDownstream(3)
            guard case let .responseHead(status, headers) = wire[0] else { return XCTFail("head expected") }
            XCTAssertEqual(status, 202)
            XCTAssertEqual(headers["content-length"], "\(#"{"maintenance":true}"#.utf8.count)")
            XCTAssertNil(headers["transfer-encoding"])
            XCTAssertEqual(headers["x-trace"], "abc")
            XCTAssertEqual(wire[1], .body(#"{"maintenance":true}"#))
        }
    }

    func testRuntimeErrorForwardsTheOriginalUnchangedInBothDirections() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .failure(TestError.boom))
            rig.processor.setResult(.responseEnter, .failure(TestError.boom))
            try await rig.sendPost()
            let up = try await rig.waitUpstream(3)
            XCTAssertEqual(up[0].headers["content-length"], "\(Fixture.json.utf8.count)")
            XCTAssertEqual(up[1], .body(Fixture.json))

            try await rig.sendJSONResponse(#"{"ok":true}"#)
            let down = try await rig.waitDownstream(3)
            XCTAssertEqual(down[1], .body(#"{"ok":true}"#))
            XCTAssertTrue(rig.downstream.isActive, "a runtime failure must not close the connection")
        }
    }

    func testInvalidReplacementJSONIsIgnoredAndOriginalIsForwarded() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data("not json".utf8)))
            try await rig.sendPost()
            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire[1], .body(Fixture.json))
        }
    }

    func testObserverRecordsTheActuallyForwardedMessagesNotTheOriginals() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            rig.processor.setResult(.responseEnter, .success(Data(#"{"ok":false}"#.utf8)))
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            try await expectTrue(rig.waitForPhase(.responseLeave))

            let obs = rig.recorder.matching(prefix: "obs:")
            XCTAssertEqual(obs, [
                "obs:req-head POST /search?q=1 cl=\(Fixture.mutated.utf8.count)",
                "obs:req-body \(Fixture.mutated)",
                "obs:res-head 200 cl=\(#"{"ok":false}"#.utf8.count)",
                "obs:res-body {\"ok\":false}",
                "obs:res-end",
            ])
        }
    }

    func testObserverStillRecordsPlainTrafficWithoutAProcessor() async throws {
        try await Rig.run(installProcessor: false) { rig in
            try await rig.sendPost()
            let up = try await rig.waitUpstream(3)
            XCTAssertEqual(up[1], .body(Fixture.json))
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            _ = try await rig.waitDownstream(3)
            XCTAssertEqual(rig.recorder.matching(prefix: "obs:").count, 5)
            XCTAssertTrue(rig.processor.calls.isEmpty)
        }
    }

    func testRecordedResponseEndsOnlyOnceAcrossInterimResponses() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendResponse(.head(Fixture.responseHead(.continue, contentType: nil, contentLength: nil)), .end(nil))
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            _ = try await rig.waitDownstream(5)
            XCTAssertEqual(rig.recorder.matching(prefix: "obs:res-end").count, 1)
        }
    }
}

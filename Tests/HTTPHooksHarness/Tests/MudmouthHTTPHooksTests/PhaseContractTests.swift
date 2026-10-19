//
//  PhaseContractTests.swift
//  MudmouthHTTPHooksTests
//
//  Enter / leave ordering around the local end-write promise, in both directions.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class PhaseContractTests: XCTestCase {
    private func phases(_ rig: Rig) -> [String] {
        rig.recorder.all.filter { !$0.hasPrefix("obs:") }
    }

    func testPhaseTypesAreSendableWithDottedRawValues() {
        let phases: [any Sendable] = [HTTPPluginPhase.requestEnter, HTTPPluginRequest(id: UUID(), method: "GET", host: "h", path: "/", headers: [:], body: Data())]
        XCTAssertEqual(phases.count, 2)
        XCTAssertEqual(HTTPPluginPhase(rawValue: "response.onLeave"), .responseLeave)
        XCTAssertEqual(Set(HTTPPluginPhase.allCases.map(\.rawValue)), ["request.onEnter", "request.onLeave", "response.onEnter", "response.onLeave"])
    }

    func testRequestEnterRunsBeforeForwardAndLeaveOnlyAfterEndWriteSucceeds() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestEnter)
            rig.upstreamControl.holdEnd = true
            try await rig.sendPost()

            try await expectTrue(rig.waitForPhase(.requestEnter))
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [], "nothing may be forwarded while enter is in flight")
            XCTAssertTrue(rig.processor.calls(.requestLeave).isEmpty)

            rig.processor.releaseGate(.requestEnter)
            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire.count, 3)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.requestLeave).isEmpty, "leave must wait for the end-write promise, not run with enter")

            try await rig.upstreamControl.completeHeld(on: rig.loop)
            try await expectTrue(rig.waitForPhase(.requestLeave))
            XCTAssertEqual(phases(rig), ["request.onEnter", "upstream-end-write", "request.onLeave"])
        }
    }

    func testRequestLeaveIsNotInvokedWhenEndWriteFailsAndNothingIsRetried() async throws {
        try await Rig.run { rig in
            rig.upstreamControl.failEnd = TestError.boom
            try await rig.sendPost()

            try await expectTrue(rig.waitForPhase(.requestEnter))
            try await expectTrue(rig.waitForClose(), "a failed forward write must close the connection")
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.requestLeave).isEmpty)
            XCTAssertEqual(rig.recorder.matching(prefix: "upstream-end-write").count, 1, "no retry or replay after a write failure")
            XCTAssertEqual(rig.processor.calls(.requestEnter).count, 1)
        }
    }

    func testRequestLeaveSeesTheForwardedRequestAndCannotMutate() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            rig.processor.setResult(.requestLeave, .success(Data(#"{"leave":"ignored"}"#.utf8)))
            try await rig.sendPost()

            try await expectTrue(rig.waitForPhase(.requestLeave))
            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire[1], .body(Fixture.mutated), "leave output is read-only and must not change the wire")
            XCTAssertEqual(String(data: rig.processor.calls(.requestLeave)[0].request.body, encoding: .utf8), Fixture.mutated)
        }
    }

    func testResponseEnterRunsBeforeForwardAndLeaveOnlyAfterEndWriteSucceeds() async throws {
        try await Rig.run { rig in
            rig.downstreamControl.holdEnd = true
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            rig.processor.gate(.responseEnter)
            try await rig.sendJSONResponse(#"{"ok":true}"#)

            try await expectTrue(rig.waitForPhase(.responseEnter))
            try await rig.quiet()
            XCTAssertEqual(rig.sentDownstream, [], "response must not be forwarded while enter is in flight")
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)

            rig.processor.releaseGate(.responseEnter)
            let wire = try await rig.waitDownstream(3)
            XCTAssertEqual(wire.count, 3)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)

            try await rig.downstreamControl.completeHeld(on: rig.loop)
            try await expectTrue(rig.waitForPhase(.responseLeave))
            let order = phases(rig)
            XCTAssertEqual(order.suffix(3), ["response.onEnter", "downstream-end-write", "response.onLeave"])
        }
    }

    func testResponseLeaveIsNotInvokedWhenEndWriteFails() async throws {
        try await Rig.run { rig in
            rig.downstreamControl.failEnd = TestError.boom
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendJSONResponse(#"{"ok":true}"#)

            try await expectTrue(rig.waitForPhase(.responseEnter))
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
            XCTAssertEqual(rig.recorder.matching(prefix: "downstream-end-write").count, 1)
        }
    }

    func testResponsePhasesReceiveTheRequestIdentityAndStatus() async throws {
        try await Rig.run { rig in
            try await rig.sendPost(uri: "/search?q=1")
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendJSONResponse(#"{"ok":true}"#, status: .created)
            try await expectTrue(rig.waitForPhase(.responseLeave))

            let requestEnter = try XCTUnwrap(rig.processor.calls(.requestEnter).first)
            let responseEnter = try XCTUnwrap(rig.processor.calls(.responseEnter).first)
            XCTAssertEqual(responseEnter.request.id, requestEnter.request.id)
            XCTAssertEqual(responseEnter.response?.status, 201)
            XCTAssertEqual(responseEnter.response?.headers["content-type"], "application/json")
            XCTAssertEqual(responseEnter.response.map { String(data: $0.body, encoding: .utf8) }, #"{"ok":true}"#)
            XCTAssertNil(requestEnter.response)
        }
    }

    func testRequestIdentityUsesAuthenticatedAuthorityAndPathWithoutQuery() async throws {
        try await Rig.run(authority: "api.example.com") { rig in
            rig.processor.matcher = { $0.host == "api.example.com" && $0.path == "/search" && $0.method == "POST" }
            // The decrypted Host header is attacker-controlled and must be ignored for matching.
            try await rig.downstream.writeInbound(HTTPServerRequestPart.head(Fixture.requestHead(
                uri: "/search?q=1&token=x", hostHeader: "evil.example.net", contentLength: Fixture.json.utf8.count,
            )))
            try await rig.downstream.writeInbound(HTTPServerRequestPart.body(Fixture.buffer(Fixture.json)))
            try await rig.downstream.writeInbound(HTTPServerRequestPart.end(nil))

            try await expectTrue(rig.waitForPhase(.requestEnter))
            let request = try XCTUnwrap(rig.processor.calls(.requestEnter).first?.request)
            XCTAssertEqual(request.host, "api.example.com")
            XCTAssertEqual(request.path, "/search")
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.headers["host"], "evil.example.net", "headers are reported verbatim in lowercase")
            XCTAssertEqual(request.headers["content-type"], "application/json")
            XCTAssertEqual(String(data: request.body, encoding: .utf8), Fixture.json)
        }
    }

    func testQueryItemsAreParsedFromTheOriginalURIBeforeThePathIsStripped() async throws {
        try await Rig.run { rig in
            try await rig.sendPost(uri: "/search?q=1&tag=a%20b&plus=x+y&flag&=skipped&q=second")
            try await expectTrue(rig.waitForPhase(.requestEnter))
            let request = try XCTUnwrap(rig.processor.calls(.requestEnter).first?.request)
            XCTAssertEqual(request.path, "/search")
            XCTAssertEqual(request.query, ["q": "1", "tag": "a b", "plus": "x y", "flag": ""], "first value wins, empty names are dropped")
            XCTAssertEqual(rig.processor.matchedHeads.first?.query["q"], "1", "match sees the query too")
            let wire = try await rig.waitUpstream(3)
            guard case let .requestHead(_, uri, _) = wire[0] else { return XCTFail("head expected") }
            XCTAssertEqual(uri, "/search?q=1&tag=a%20b&plus=x+y&flag&=skipped&q=second", "the forwarded URI is never rewritten")
        }
    }

    func testPublicInitializerDefaultsQueryToEmpty() {
        let request = HTTPPluginRequest(id: UUID(), method: "GET", host: "h", path: "/", headers: [:], body: Data())
        XCTAssertEqual(request.query, [:])
    }

    func testMissingAuthorityNeverMatchesOrRunsHooks() async throws {
        try await Rig.run(authority: nil) { rig in
            rig.processor.matcher = { _ in true }
            try await rig.sendPost()
            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire[1], .body(Fixture.json))
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls.isEmpty)
        }
    }
}

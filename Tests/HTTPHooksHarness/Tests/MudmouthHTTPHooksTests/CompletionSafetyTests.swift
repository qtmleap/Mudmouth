import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

/// Reproductions for paths absent from the original 71-test transport baseline.
@available(macOS 14, iOS 17, *)
final class CompletionSafetyTests: XCTestCase {
    private func jsonBody(bytes: Int) -> String {
        #"{"v":""# + String(repeating: "a", count: bytes - 8) + #""}"#
    }

    func testRequestOverflowRechecksRevokedActivationBeforeForwardingOriginal() async throws {
        try await Rig.run(limits: .init(queuedParts: 2)) { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.processor.setAuthorized(false)
            // A second complete request exceeds the queued-part cap while the first callback is stalled.
            try await rig.sendPost(uri: "/second")
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [], "overflow cannot forward the original after activation was revoked")
        }
    }

    func testResponseOverflowRechecksRevokedActivationBeforeForwardingOriginal() async throws {
        try await Rig.run(limits: .init(queuedParts: 2)) { rig in
            try await rig.sendPost(uri: "/first")
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendPost(uri: "/second")
            try await expectTrue(rig.waitForPhase(.requestLeave, count: 2))
            rig.processor.gate(.responseEnter)
            try await rig.sendJSONResponse(#"{"first":true}"#)
            try await expectTrue(rig.waitForPhase(.responseEnter))
            rig.processor.setAuthorized(false)
            try await rig.sendJSONResponse(#"{"second":true}"#)
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertEqual(rig.sentDownstream, [], "overflow cannot forward a buffered response after activation was revoked")
        }
    }

    func testRequestReplacementUsesRemainingAggregateBudget() async throws {
        let retained = jsonBody(bytes: 24_000)
        let replacement = jsonBody(bytes: 24_001)
        try await Rig.run { rig in
            try await rig.sendPost(retained, uri: "/first")
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendPost(retained, uri: "/second")
            try await expectTrue(rig.waitForPhase(.requestLeave, count: 2))
            rig.processor.setResult(.requestEnter, .success(Data(replacement.utf8)))
            try await rig.sendPost(uri: "/third")
            try await expectTrue(rig.waitForPhase(.requestLeave, count: 3))
            let wire = try await rig.waitUpstream(9)
            XCTAssertEqual(wire.count, 9)
            XCTAssertTrue(wire[7] == .body(Fixture.json), "48 KiB already retained leaves insufficient capacity for a 24 KiB replacement; forward the original")
        }
    }

    func testResponseReplacementUsesRemainingAggregateBudget() async throws {
        let retained = jsonBody(bytes: 24_000)
        let replacement = jsonBody(bytes: 24_001)
        try await Rig.run { rig in
            try await rig.sendPost(retained, uri: "/first")
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendPost(retained, uri: "/second")
            try await expectTrue(rig.waitForPhase(.requestLeave, count: 2))
            rig.processor.setResult(.responseEnter, .success(Data(replacement.utf8)))
            let original = #"{"ok":true}"#
            try await rig.sendJSONResponse(original)
            let wire = try await rig.waitDownstream(3)
            XCTAssertEqual(wire.count, 3)
            XCTAssertTrue(wire[1] == .body(original), "a response replacement must fit alongside request bodies retained for outstanding exchanges")
        }
    }

    func testUpstreamCloseAfterEnterWaitsForOutstandingResponseEndWrite() async throws {
        try await Rig.run { rig in
            rig.downstreamControl.holdEnd = true
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            let wire = try await rig.waitDownstream(3)
            XCTAssertEqual(wire.count, 3)
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
            // The enter task has finished, but the local response-end write has not succeeded yet.
            try await rig.upstream.close()
            await rig.loop.run()
            XCTAssertTrue(rig.downstream.isActive, "full close must wait for the outstanding end-write promise even after enter returned")
            try await rig.downstreamControl.completeHeld(on: rig.loop)
            try await expectTrue(rig.waitForClose())
        }
    }

    func testGatedLeaveBodiesRemainInsideConnectionBudgetAfterExchangeRetires() async throws {
        let body = jsonBody(bytes: 24_000)
        try await Rig.run { rig in
            rig.processor.gate(.responseLeave)
            for index in 1 ... 3 {
                try await rig.sendPost(body, uri: "/r\(index)")
                _ = try await rig.waitUpstream(index * 3)
                try await rig.sendJSONResponse(#"{"ok":true}"#)
                _ = try await rig.waitDownstream(index * 3)
                try await rig.quiet()
            }
            // These callbacks remain gated, so each still owns its distinct request body after FIFO retirement.
            let bytes = rig.processor.calls(.responseLeave).reduce(0) { $0 + $1.request.body.count + ($1.response?.body.count ?? 0) }
            XCTAssertLessThanOrEqual(bytes, 64 * 1024, "retiring an exchange cannot remove bytes still retained by a leave task from the connection budget")
        }
    }
}

@available(macOS 14, iOS 17, *)
extension CompletionSafetyTests {
    func testHungOverflowAuthorizationRecheckClosesAtDeadlineWithoutForwarding() async throws {
        try await Rig.run(limits: .init(queuedParts: 2)) { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.processor.gateAuthorization()
            try await rig.sendPost(uri: "/queued")
            try await expectTrue(rig.eventually { rig.processor.authorizationWaiterCount > 0 })
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [])
            await rig.loop.advanceTime(by: .seconds(6))
            try await expectTrue(rig.waitForClose(), "a hung fresh grant check must close, never forward unchecked")
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [])
        }
    }

    func testAdditionalDecodedBurstDuringAuthorizationRecheckClosesAtHardCap() async throws {
        try await Rig.run(limits: .init(queuedParts: 2)) { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.processor.gateAuthorization()
            try await rig.sendPost(uri: "/queued")
            try await expectTrue(rig.eventually { rig.processor.authorizationWaiterCount > 0 })
            try await rig.sendRequest(.head(Fixture.requestHead(uri: "/overflow", contentLength: Fixture.json.utf8.count)))
            try await expectTrue(rig.waitForClose(), "a held grant check cannot retain an unbounded already-decoded pipeline")
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [])
        }
    }
}

@available(macOS 14, iOS 17, *)
extension CompletionSafetyTests {
    func testPartialSecondResponseRemainsCollectingAfterFirstEnterCompletes() async throws {
        try await Rig.run { rig in
            try await rig.sendPost(uri: "/first")
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendPost(uri: "/second")
            try await expectTrue(rig.waitForPhase(.requestLeave, count: 2))
            rig.processor.gate(.responseEnter)
            try await rig.sendJSONResponse(#"{"first":true}"#)
            try await expectTrue(rig.waitForPhase(.responseEnter))
            let second = #"{"second":true}"#
            let prefix = String(second.prefix(5))
            let suffix = String(second.dropFirst(5))
            try await rig.sendResponse(.head(Fixture.responseHead(contentLength: second.utf8.count)), .body(Fixture.buffer(prefix)))
            rig.processor.releaseGate(.responseEnter)
            _ = try await rig.waitDownstream(3)
            // Request 2's body is split across socket reads; draining its prefix must not turn off its hooks.
            rig.processor.setResult(.responseEnter, .success(Data(Fixture.mutated.utf8)))
            try await rig.sendResponse(.body(Fixture.buffer(suffix)), .end(nil))
            try await expectTrue(rig.waitForPhase(.responseEnter, count: 2), "a queued partial response must stay collected until its end arrives")
            let wire = try await rig.waitDownstream(6)
            XCTAssertEqual(wire.count, 6)
            if wire.count == 6 {
                XCTAssertEqual(wire[4], .body(Fixture.mutated))
            }
        }
    }
}

@available(macOS 14, iOS 17, *)
extension CompletionSafetyTests {
    func testOverflowDrainEndingAtPartialRequestReenablesHooksAfterItsEnd() async throws {
        try await Rig.run(limits: .init(queuedParts: 3)) { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost(uri: "/first")
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.processor.gateAuthorization()
            try await rig.sendPost(uri: "/second")
            try await rig.sendRequest(.head(Fixture.requestHead(uri: "/partial", contentLength: Fixture.json.utf8.count)))
            try await expectTrue(rig.eventually { rig.processor.authorizationWaiterCount > 0 })
            rig.processor.releaseAuthorization()
            _ = try await rig.waitUpstream(7)
            try await rig.sendRequest(.body(Fixture.buffer(Fixture.json)), .end(nil))
            _ = try await rig.waitUpstream(9)
            rig.processor.releaseGate(.requestEnter)
            try await rig.sendPost(uri: "/later")
            _ = try await rig.waitUpstream(12)
            XCTAssertEqual(rig.processor.calls(.requestEnter).map(\.request.path), ["/first", "/later"],
                           "a partially queued overflow request must not disable hooks for later messages")
        }
    }

    func testFourLeaveTaskSlotsDoNotBlockFifthSuccessfulForward() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestLeave)
            for index in 1 ... 4 {
                try await rig.sendPost(uri: "/leave-\(index)")
                _ = try await rig.waitUpstream(index * 3)
                try await expectTrue(rig.waitForPhase(.requestLeave, count: index))
            }
            try await rig.sendPost(uri: "/leave-5")
            _ = try await rig.waitUpstream(15)
            try await rig.quiet()
            XCTAssertEqual(rig.processor.calls(.requestEnter).count, 5)
            XCTAssertEqual(rig.processor.calls(.requestLeave).count, 4, "excess observational leave callbacks are dropped at four task slots")
            XCTAssertEqual(rig.sentUpstream.count, 15)
        }
    }
}

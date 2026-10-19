//
//  TransportReviewTests.swift
//  MudmouthHTTPHooksTests
//
//  Regression tests for the transport review: close ordering, deadline revocation, half-close flush,
//  hard memory bounds, bounded/cancelled leave tasks and scoped upgrade bypass.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class TransportReviewTests: XCTestCase {
    private func heads(_ wire: [Wire]) -> [String] {
        wire.compactMap {
            part -> String? in if case let .requestHead(_, uri, _) = part {
                uri
            } else {
                nil
            }
        }
    }

    // MARK: Full close vs. pending response phase

    func testUpstreamFullCloseWhileResponseEnterIsPendingFlushesResponseBeforeClosing() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            rig.processor.gate(.responseEnter)
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            try await expectTrue(rig.waitForPhase(.responseEnter))
            // Connection: close / idle FIN right after the body: the remote glue fully closes the client leg.
            try await rig.upstream.close()
            await rig.loop.run()
            rig.processor.releaseGate(.responseEnter)

            let wire = try await rig.waitDownstream(3)
            XCTAssertEqual(wire.count, 3, "the buffered response must reach the client before the close")
            XCTAssertEqual(wire.last, .end)
            try await expectTrue(rig.waitForClose(), "the deferred full close happens after the flush")
        }
    }

    // MARK: Deadline must re-check activation

    func testRequestDeadlineWithRevokedActivationClosesWithoutForwarding() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.processor.setAuthorized(false)
            await rig.loop.advanceTime(by: .seconds(6))
            try await expectTrue(rig.waitForClose(), "revocation seen at the deadline closes the connection")
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [], "the original must not be forwarded after revocation")
        }
    }

    func testResponseDeadlineWithRevokedActivationClosesWithoutForwarding() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            rig.processor.gate(.responseEnter)
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            try await expectTrue(rig.waitForPhase(.responseEnter))
            rig.processor.setAuthorized(false)
            await rig.loop.advanceTime(by: .seconds(6))
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertEqual(rig.sentDownstream, [], "the original response must not be forwarded after revocation")
        }
    }

    // MARK: Half-close ordering

    func testQueuedHalfCloseIsPrecededByAFlushOfEverythingWritten() async throws {
        try await Rig.run { rig in
            try await rig.upstream.pipeline.addHandler(OrderProbe(recorder: rig.recorder), position: .first).get()
            rig.processor.gate(.requestEnter)
            try await rig.sendPost(#"{"n":1}"#, uri: "/a")
            try await expectTrue(rig.waitForPhase(.requestEnter))
            // Request 2 is only partly received (still collecting) when the client half-closes.
            try await rig.sendRequest(.head(Fixture.requestHead(uri: "/b", contentLength: 7)), .body(Fixture.buffer(#"{"n":2}"#)))
            try await rig.downstream.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            rig.processor.releaseGate(.requestEnter)
            try await expectTrue(rig.eventually { rig.recorder.all.contains("order:close-output") })

            let order = rig.recorder.all.filter { $0.hasPrefix("order:") }
            let close = try XCTUnwrap(order.firstIndex(of: "order:close-output"))
            let before = Array(order[..<close])
            let lastWrite = before.lastIndex(of: "order:write")
            let lastFlush = before.lastIndex(of: "order:flush")
            expectTrue(lastWrite != nil && lastFlush != nil && lastFlush! > lastWrite!, "unflushed writes precede the output close: \(order)")
        }
    }

    // MARK: Hard memory bounds

    func testQueueOverflowDuringPhaseCancelsItAndForwardsInOrderWithoutGrowing() async throws {
        let limits = HTTPHookLimits(queuedParts: 8, pipelinedExchanges: 64, outstandingExchanges: 64)
        try await Rig.run(limits: limits) { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost(#"{"n":1}"#, uri: "/r1")
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.processor.gateAuthorization()
            for index in 2 ... 4 {
                try await rig.sendPost(#"{"n":\#(index)}"#, uri: "/r\(index)")
            }

            // The enter gate stays closed. Fill the queue to its first overflow, then explicitly
            // permit the fresh grant check before sending any more already-decoded parts.
            try await expectTrue(rig.eventually { rig.processor.authorizationWaiterCount > 0 })
            XCTAssertEqual(rig.sentUpstream, [])
            rig.processor.releaseAuthorization()
            let wire = try await rig.waitUpstream(12)
            XCTAssertEqual(heads(wire), (1 ... 4).map { "/r\($0)" }, "whole messages, in order, none partially written")
            let bodies = wire.compactMap {
                part -> String? in if case let .body(text) = part {
                    text
                } else {
                    nil
                }
            }
            XCTAssertEqual(bodies, (1 ... 4).map { #"{"n":\#($0)}"# })

            rig.processor.releaseGate(.requestEnter)
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream.count, 12, "the cancelled phase must not replay or duplicate anything")
        }
    }

    func testRetainedRequestBodiesCountTowardsTheConnectionBudget() async throws {
        let limits = HTTPHookLimits(bodyBytes: 1000, bufferedBytes: 2500, pipelinedExchanges: 8)
        try await Rig.run(limits: limits) { rig in
            let body = #"{"v":""# + String(repeating: "a", count: 892) + #""}"#
            XCTAssertEqual(body.utf8.count, 900)
            for index in 1 ... 4 {
                try await rig.sendPost(body, uri: "/r\(index)")
                try await rig.quiet()
            }
            XCTAssertEqual(heads(rig.sentUpstream), (1 ... 4).map { "/r\($0)" }, "everything is still forwarded in order")
            XCTAssertLessThanOrEqual(rig.processor.calls(.requestEnter).count, 2, "retained bodies of unanswered exchanges (900 B each) exhaust the 2500 B budget")
        }
    }

    func testExchangeHardCapClosesInsteadOfGrowingOrMisassociating() async throws {
        let limits = HTTPHookLimits(pipelinedExchanges: 2, outstandingExchanges: 4)
        try await Rig.run(limits: limits) { rig in
            func get(_ index: Int) -> [HTTPServerRequestPart] {
                [.head(Fixture.requestHead(.GET, uri: "/g\(index)", contentType: nil, contentLength: nil)), .end(nil)]
            }
            for index in 1 ... 4 {
                for part in get(index) {
                    try await rig.downstream.writeInbound(part)
                }
            }
            try await rig.quiet()
            XCTAssertEqual(heads(rig.sentUpstream), (1 ... 4).map { "/g\($0)" })
            for part in get(5) {
                try await rig.downstream.writeInbound(part)
            }
            try await expectTrue(rig.waitForClose(), "the fifth outstanding exchange exceeds the hard cap")
            try await rig.quiet()
            XCTAssertEqual(heads(rig.sentUpstream), (1 ... 4).map { "/g\($0)" }, "nothing beyond the cap is forwarded")
        }
    }

    // MARK: Leave tasks

    func testSlowLeaveCallbacksAreBoundedAndDoNotBlockTraffic() async throws {
        let limits = HTTPHookLimits(pipelinedExchanges: 32)
        try await Rig.run(limits: limits) { rig in
            rig.processor.gate(.requestLeave)
            for index in 1 ... 12 {
                try await rig.sendPost(#"{"n":\#(index)}"#, uri: "/r\(index)")
            }
            let wire = try await rig.waitUpstream(36)
            XCTAssertEqual(heads(wire).count, 12, "slow leave callbacks never hold up forwarding")
            try await rig.quiet()
            XCTAssertLessThanOrEqual(rig.processor.calls(.requestLeave).count, 4, "at most 4 leave callbacks may be in flight per connection")
        }
    }

    func testInFlightLeaveIsCancelledWhenTheConnectionCloses() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestLeave)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.downstream.close()
            try await expectTrue(rig.eventually { rig.recorder.all.contains("cancel request.onLeave") }, "teardown cancels outstanding leave tasks")
        }
    }

    // MARK: Unsupported protocol write ordering

    func testRefusalIsNotWrittenAfterAnEarlierResponseEndFails() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendRequest(.head(Fixture.requestHead(.GET, contentType: nil, contentLength: nil, extra: [("Upgrade", "websocket")])))
            rig.downstreamControl.failEnd = ChannelError.ioOnClosedChannel
            try await rig.sendJSONResponse(Fixture.json)
            try await expectTrue(rig.waitForClose())
            XCTAssertFalse(rig.sentDownstream.contains {
                if case .responseHead(501, _) = $0 {
                    true
                } else {
                    false
                }
            })
            XCTAssertEqual(rig.processor.matchedHeads.count, 1)
        }
    }

    func testRefusalCloseWaitsForItsEndWriteToSucceedOrFail() async throws {
        for fails in [false, true] {
            try await Rig.run { rig in
                rig.downstreamControl.holdEnd = true
                try await rig.sendRequest(.head(Fixture.requestHead(.GET, contentType: nil, contentLength: nil, extra: [("Upgrade", "h2c")])))
                try await expectEqual(rig.waitDownstream(2).count, 2)
                XCTAssertTrue(rig.downstream.isActive, "close must wait for the refusal's end-write promise")
                try await rig.downstreamControl.completeHeld(on: rig.loop, with: fails ? ChannelError.ioOnClosedChannel : nil)
                try await expectTrue(rig.waitForClose())
                XCTAssertEqual(rig.sentUpstream, [])
                XCTAssertTrue(rig.processor.calls.isEmpty)
            }
        }
    }
}

//
//  PipeliningAndRevocationTests.swift
//  MudmouthHTTPHooksTests
//
//  FIFO exchange association, pipelining cap, peer read holds, explicit flush and revocation.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class PipeliningAndRevocationTests: XCTestCase {
    // MARK: Backpressure and flush

    func testDownstreamReadIsHeldWhileEnterIsInFlightAndResumesAfterRelease() async throws {
        try await Rig.run { rig in
            await rig.loop.run()
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            try await rig.quiet()
            let readsWhileHeld = rig.downstreamReads.count

            // Glue asks for more input; the hook handler must swallow it while the phase is running.
            try await rig.pipelineRead(rig.downstream)
            await rig.loop.run()
            XCTAssertEqual(rig.downstreamReads.count, readsWhileHeld, "no peer read may reach the socket during an async phase")

            rig.processor.releaseGate(.requestEnter)
            try await expectTrue(rig.eventually { rig.downstreamReads.count > readsWhileHeld }, "the held read is resumed after release")
        }
    }

    func testUpstreamReadIsHeldWhileResponseEnterIsInFlight() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            rig.processor.gate(.responseEnter)
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            try await expectTrue(rig.waitForPhase(.responseEnter))
            try await rig.quiet()
            let readsWhileHeld = rig.upstreamReads.count

            try await rig.pipelineRead(rig.upstream)
            await rig.loop.run()
            XCTAssertEqual(rig.upstreamReads.count, readsWhileHeld, "the upstream peer is held while the response phase runs")

            rig.processor.releaseGate(.responseEnter)
            try await expectTrue(rig.eventually { rig.upstreamReads.count > readsWhileHeld })
        }
    }

    func testAsyncReleaseFlushesExplicitlyWithoutAnotherReadCycle() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            try await rig.quiet()
            let flushesBefore = rig.upstreamFlushes.count
            // No channelReadComplete is delivered after this point; only the async release can flush.
            rig.processor.releaseGate(.requestEnter)
            let wire = try await rig.waitUpstream(3)
            XCTAssertEqual(wire.count, 3)
            XCTAssertGreaterThan(rig.upstreamFlushes.count, flushesBefore, "released parts must be flushed explicitly")
        }
    }

    func testEndWriteCompletionIsPromiseCarryingAndFlushed() async throws {
        try await Rig.run { rig in
            rig.upstreamControl.holdEnd = true
            try await rig.sendPost()
            _ = try await rig.waitUpstream(3)
            XCTAssertNotNil(rig.upstreamControl.heldPromise, "the glue must carry a promise for the end write")
            XCTAssertGreaterThan(rig.upstreamFlushes.count, 0)
        }
    }

    // MARK: Pipelining

    func testPipelinedRequestsAreForwardedInOrderAndAssociatedFIFOWithTheirResponses() async throws {
        try await Rig.run { rig in
            try await rig.sendPost(#"{"n":1}"#, uri: "/a")
            try await rig.sendPost(#"{"n":2}"#, uri: "/b")
            try await expectTrue(rig.waitForPhase(.requestLeave, count: 2))
            let wire = try await rig.waitUpstream(6)
            let heads = wire.compactMap {
                part -> String? in if case let .requestHead(_, uri, _) = part {
                    uri
                } else {
                    nil
                }
            }
            XCTAssertEqual(heads, ["/a", "/b"], "FIFO forwarding")

            try await rig.sendJSONResponse(#"{"r":1}"#)
            try await rig.sendJSONResponse(#"{"r":2}"#)
            try await expectTrue(rig.waitForPhase(.responseEnter, count: 2))
            let responses = rig.processor.calls(.responseEnter)
            let requests = rig.processor.calls(.requestEnter)
            XCTAssertEqual(responses[0].request.id, requests[0].request.id)
            XCTAssertEqual(responses[1].request.id, requests[1].request.id)
            XCTAssertEqual(responses[0].request.path, "/a")
            XCTAssertEqual(responses[1].request.path, "/b")
        }
    }

    func testSecondPipelinedRequestWaitsForTheFirstAsyncPhaseAndStaysOrdered() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost(#"{"n":1}"#, uri: "/a")
            try await expectTrue(rig.waitForPhase(.requestEnter))
            // The second request is already on the wire (pipelined); it must not overtake the first.
            try await rig.sendPost(#"{"n":2}"#, uri: "/b")
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [])
            XCTAssertEqual(rig.processor.calls(.requestEnter).count, 1, "phases for one connection never run concurrently")

            rig.processor.releaseGate(.requestEnter)
            let wire = try await rig.waitUpstream(6)
            let heads = wire.compactMap {
                part -> String? in if case let .requestHead(_, uri, _) = part {
                    uri
                } else {
                    nil
                }
            }
            XCTAssertEqual(heads, ["/a", "/b"])
        }
    }

    func testPipeliningCapStopsHooksButNeverReordersOrDrops() async throws {
        let limits = HTTPHookLimits(pipelinedExchanges: 2)
        try await Rig.run(limits: limits) { rig in
            for index in 1 ... 4 {
                try await rig.sendPost(#"{"n":\#(index)}"#, uri: "/r\(index)")
            }
            let wire = try await rig.waitUpstream(12)
            let heads = wire.compactMap {
                part -> String? in if case let .requestHead(_, uri, _) = part {
                    uri
                } else {
                    nil
                }
            }
            XCTAssertEqual(heads, ["/r1", "/r2", "/r3", "/r4"])
            XCTAssertLessThanOrEqual(rig.processor.calls(.requestEnter).count, 2, "requests beyond the cap bypass body hooks")
            let bodies = wire.compactMap {
                part -> String? in if case let .body(text) = part {
                    text
                } else {
                    nil
                }
            }
            XCTAssertEqual(bodies, (1 ... 4).map { #"{"n":\#($0)}"# })
        }
    }

    func testQueuedPartCapReplaysOriginalsInOrder() async throws {
        let limits = HTTPHookLimits(queuedParts: 5)
        try await Rig.run(limits: limits) { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost(#"{"n":1}"#, uri: "/a")
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.processor.gateAuthorization()
            for index in 2 ... 3 {
                try await rig.sendPost(#"{"n":\#(index)}"#, uri: "/p\(index)")
            }
            try await expectTrue(rig.eventually { rig.processor.authorizationWaiterCount > 0 })
            XCTAssertEqual(rig.sentUpstream, [], "overflow waits for a fresh grant before replay")
            rig.processor.releaseAuthorization()
            _ = try await rig.waitUpstream(9)
            rig.processor.releaseGate(.requestEnter)
            for index in 4 ... 6 {
                try await rig.sendPost(#"{"n":\#(index)}"#, uri: "/p\(index)")
                _ = try await rig.waitUpstream(index * 3)
            }
            let wire = try await rig.waitUpstream(18)
            let heads = wire.compactMap {
                part -> String? in if case let .requestHead(_, uri, _) = part {
                    uri
                } else {
                    nil
                }
            }
            XCTAssertEqual(heads, ["/a", "/p2", "/p3", "/p4", "/p5", "/p6"], "nothing dropped, nothing reordered")
            XCTAssertEqual(rig.processor.calls(.requestEnter).count, 4, "ordinary hooks resume after the overflow queue drains")
        }
    }

    // MARK: Revocation

    func testRevokedAuthorizationBeforeCallbackClosesWithoutCallbackOrForward() async throws {
        try await Rig.run(configure: { $0.setAuthorized(false) }) { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls.isEmpty, "no callback after revocation")
            XCTAssertEqual(rig.sentUpstream, [], "no forward after revocation")
        }
    }

    func testRevocationDuringAnEnterPhaseDropsTheResultAndClosesBeforeForwarding() async throws {
        try await Rig.run { rig in
            rig.processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            rig.processor.afterProcess = { [processor = rig.processor] _ in processor.setAuthorized(false) }
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [], "the buffered result must not be applied or forwarded after revocation")
            XCTAssertTrue(rig.processor.calls(.requestLeave).isEmpty)
        }
    }

    func testRevocationBeforeResponseEnterClosesWithoutForwardingTheResponse() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            rig.processor.setAuthorized(false)
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertEqual(rig.sentDownstream, [])
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
        }
    }

    func testRevokedConsentClosesOnTheNextPartAndForwardsNothing() async throws {
        try await Rig.run(installProcessor: false) { rig in
            rig.consent.set(false)
            try await rig.sendRequest(.head(Fixture.requestHead(contentLength: 0)), .end(nil))
            try await expectTrue(rig.waitForClose())
            try await expectEqual(rig.collectUpstream(), [])
        }
    }

    func testRevokedConsentWhileEnterIsInFlightClosesWithoutForwarding() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            rig.consent.set(false)
            rig.processor.releaseGate(.requestEnter)
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [])
        }
    }

    func testConnectionClosedWhileEnterIsInFlightNeverForwardsAfterwards() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            try await rig.downstream.close()
            rig.processor.releaseGate(.requestEnter)
            try await rig.quiet()
            XCTAssertEqual(rig.sentUpstream, [])
            XCTAssertTrue(rig.processor.calls(.requestLeave).isEmpty)
        }
    }

    // MARK: Event loop

    func testEventLoopIsNotBlockedWhileAPhaseIsInFlight() async throws {
        try await Rig.run { rig in
            rig.processor.gate(.requestEnter)
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestEnter))
            // Other work on the same loop must still complete while the processor is suspended.
            let ran = rig.loop.submit { 42 }
            await rig.loop.run()
            let value = try await ran.get()
            XCTAssertEqual(value, 42)
        }
    }
}

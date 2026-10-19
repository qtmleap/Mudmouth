import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class WriteLifetimeTests: XCTestCase {
    func testAdministrativeAbortClosesWithoutWaitingForHeldResponseEnd() async throws {
        try await Rig.run { rig in
            rig.downstreamControl.holdEnd = true
            try await rig.sendPost()
            try await expectTrue(rig.waitForPhase(.requestLeave))
            try await rig.sendJSONResponse(Fixture.json)
            _ = try await rig.waitDownstream(3)
            await rig.loop.run()
            rig.downstream.pipeline.fireUserInboundEventTriggered(HTTPHookAbort())
            await rig.loop.run()
            XCTAssertFalse(rig.downstream.isActive, "administrative abort cannot wait for a held response-end write")
            XCTAssertFalse(rig.upstream.isActive)
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
            try await rig.downstreamControl.completeHeld(on: rig.loop)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty, "late write completion after abort must never start leave")
        }
    }

    func testInlineStreamingEndAdvancesFIFOBeforeDrainingEligibleThirdResponse() async throws {
        try await Rig.run { rig in
            for (index, path) in ["/first", "/second", "/third"].enumerated() {
                try await rig.sendPost(uri: path)
                _ = try await rig.waitUpstream((index + 1) * 3)
                try await rig.quiet()
            }
            rig.processor.gate(.responseEnter)
            rig.processor.setResult(.responseEnter, .success(Data(Fixture.mutated.utf8)))
            try await rig.sendJSONResponse(Fixture.json)
            try await expectTrue(rig.waitForPhase(.responseEnter))
            try await rig.sendResponse(.head(Fixture.responseHead(contentType: "text/plain", contentLength: 1)), .body(Fixture.buffer("x")), .end(nil))
            try await rig.sendJSONResponse(Fixture.json)
            rig.downstreamControl.completeEndInline = true
            rig.processor.releaseGate(.responseEnter)
            let wire = try await rig.waitDownstream(9)
            XCTAssertEqual(rig.processor.calls(.responseEnter).map(\.request.path), ["/first", "/third"])
            XCTAssertEqual(wire.count, 9)
            if wire.count == 9 {
                XCTAssertEqual(wire[7], .body(Fixture.mutated))
            }
        }
    }

    func testHeldResponseEndBodiesRemainBudgetedUntilCompletionThenAdmissionRecovers() async throws {
        try await Rig.run { rig in
            rig.downstreamControl.holdEnd = true
            for index in 1 ... 3 {
                let body = #"{"v":""# + String(repeating: "a", count: 23_990) + String(index) + #""}"#
                try await rig.sendPost(body, uri: "/r\(index)")
                _ = try await rig.waitUpstream(index * 3)
                try await rig.quiet()
                try await rig.sendJSONResponse("{}")
                _ = try await rig.waitDownstream(index * 3)
                try await rig.quiet()
            }
            let retainedRequests = rig.processor.calls(.responseEnter).reduce(0) { $0 + $1.request.body.count }
            XCTAssertLessThanOrEqual(retainedRequests, 64 * 1024, "pending end-write callbacks must reserve their distinct retained request bodies")
            XCTAssertEqual(rig.processor.calls(.requestEnter).map(\.request.path), ["/r1", "/r2"], "pending-write storage participates in admission")
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
            rig.downstreamControl.holdEnd = false
            try await rig.downstreamControl.completeHeld(on: rig.loop)
            try await rig.quiet()
            let after = #"{"v":""# + String(repeating: "b", count: 23_991) + #""}"#
            try await rig.sendPost(after, uri: "/after-writes")
            _ = try await rig.waitUpstream(12)
            XCTAssertEqual(rig.processor.calls(.requestEnter).last?.request.path, "/after-writes", "completed write reservations must release capacity")
        }
    }
}

@available(macOS 14, iOS 17, *)
extension WriteLifetimeTests {
    func testInlineReplayAndAbandonEndsKeepThirdResponseAssociatedWithItsOwnRequest() async throws {
        for abandonsBeforeEnd in [false, true] {
            try await Rig.run(limits: .init(bodyBytes: 16)) { rig in
                for (index, path) in ["/first", "/fallback", "/third"].enumerated() {
                    try await rig.sendPost(uri: path)
                    _ = try await rig.waitUpstream((index + 1) * 3)
                }
                rig.processor.gate(.responseEnter)
                try await rig.sendJSONResponse(Fixture.json)
                try await expectTrue(rig.waitForPhase(.responseEnter))
                let body = abandonsBeforeEnd ? String(repeating: "x", count: 17) : "x"
                let head = abandonsBeforeEnd
                    ? Fixture.responseHead(contentLength: nil, extra: [("Transfer-Encoding", "chunked")])
                    : Fixture.responseHead(contentLength: 1)
                try await rig.sendResponse(.head(head), .body(Fixture.buffer(body)), .end(nil))
                try await rig.sendJSONResponse(Fixture.json)
                rig.downstreamControl.completeEndInline = true
                rig.processor.releaseGate(.responseEnter)
                _ = try await rig.waitDownstream(9)
                XCTAssertEqual(rig.processor.calls(.responseEnter).map(\.request.path), ["/first", "/third"],
                               "inline completion of a replayed or abandoned response cannot reuse its request association")
            }
        }
    }

    func testEarlyResponsesDoNotReleaseBodyBudgetOfHeldRequestEndWrites() async throws {
        try await Rig.run { rig in
            rig.upstreamControl.holdEnd = true
            for index in 1 ... 3 {
                let body = #"{"v":""# + String(repeating: "q", count: 23_990) + String(index) + #""}"#
                try await rig.sendPost(body, uri: "/early-\(index)")
                _ = try await rig.waitUpstream(index * 3)
                try await rig.sendResponse(.head(Fixture.responseHead(.noContent, contentType: nil, contentLength: nil)), .end(nil))
                _ = try await rig.waitDownstream(index * 2)
                try await rig.quiet()
            }
            XCTAssertTrue(rig.processor.calls(.requestLeave).isEmpty)
            let pendingBodies = rig.processor.calls(.requestEnter).reduce(0) { $0 + $1.request.body.count }
            XCTAssertLessThanOrEqual(pendingBodies, 64 * 1024, "an early response cannot unaccount bodies still retained by request write callbacks")
            XCTAssertEqual(rig.processor.calls(.requestEnter).map(\.request.path), ["/early-1", "/early-2"])
            rig.upstreamControl.holdEnd = false
            try await rig.upstreamControl.completeHeld(on: rig.loop)
            try await rig.quiet()
            let after = #"{"v":""# + String(repeating: "r", count: 23_991) + #""}"#
            try await rig.sendPost(after, uri: "/after-early")
            _ = try await rig.waitUpstream(12)
            XCTAssertEqual(rig.processor.calls(.requestEnter).last?.request.path, "/after-early")
        }
    }
}

//
//  GzipResponseLeaveTests.swift
//  MudmouthHTTPHooksTests
//
//  A gzip JSON response never reaches responseEnter and is forwarded byte for byte; its bounded decoded
//  body is only observed by responseLeave after the local end-write succeeded.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class GzipResponseLeaveTests: XCTestCase {
    // `gzip -n` of {"limit":10}
    private static let validHex = "1f8b0800000000000003ab56cac9cccd2c51b23234a805007d2559fe0c000000"
    private static let decoded = #"{"limit":10}"#
    // two members: {"limit":10} then {"b":1}
    private static let multiMemberHex = validHex + "1f8b0800000000000003ab564a52b232ac05007fd6bb1107000000"
    private static let trailingHex = validHex + "7a7a"
    private static let badJSONHex = "1f8b0800000000000003cbcb2f51c82acecf030066cb8cc608000000"
    // {"a":"<24568 x 'a'>"} = exactly 24576 decoded bytes, and the same with 24569
    private static let exactHex = "1f8b0800000000000203edc1311100000804a02e1fc336e6f0ec6e076760d2a9340000000000000000000000000000000000000000000000f0963dade2562100600000"
    private static let overHex = "1f8b0800000000000203edc1311100000804a02e1fc336e6f0ec6e076760d2a9340000000000000000000000000000000000000000000000f0973db9190f1b01600000"
    // {"limit":10,"pad":"<300 x 'a'>"}, 321 decoded bytes
    private static let paddedHex = "1f8b0800000000000003ab56cac9cccd2c51b23234d0512a484c51b2524a1c054403a55a00d2eaa39c41010000"

    private static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    private static var valid: Data {
        bytes(validHex)
    }

    private func phases(_ rig: Rig) -> [String] {
        rig.recorder.all.filter { !$0.hasPrefix("obs:") }
    }

    private func gzipHead(
        length: Int?, encoding: [String] = ["gzip"], extra: [(String, String)] = [],
    ) -> HTTPResponseHead {
        Fixture.responseHead(
            contentLength: length, extra: encoding.map { ("Content-Encoding", $0) } + extra,
        )
    }

    private func sendGzip(_ rig: Rig, _ body: Data, encoding: [String] = ["gzip"], status: HTTPResponseStatus = .ok) async throws {
        var head = gzipHead(length: body.count, encoding: encoding)
        head.status = status
        try await rig.sendResponse(
            .head(head), .body(ByteBuffer(bytes: body)), .end(nil),
        )
    }

    /// Request done (leave seen), so the next response pairs with it.
    private func primed(_ rig: Rig) async throws {
        try await rig.sendPost()
        try await expectTrue(rig.waitForPhase(.requestLeave))
    }

    private func assertForwardedUnchanged(
        _ rig: Rig, body: Data, expectedEncoding: String = "gzip", file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        let wire = try await rig.waitDownstream(3)
        XCTAssertEqual(wire.count, 3, file: file, line: line)
        XCTAssertEqual(rig.sentDownstreamRawBodies, [body], "wire bytes must be the original compressed bytes", file: file, line: line)
        XCTAssertEqual(wire[0].headers["content-encoding"], expectedEncoding, file: file, line: line)
        XCTAssertEqual(wire[0].headers["content-length"], "\(body.count)", file: file, line: line)
    }

    private func assertBypass(
        _ body: Data, encoding: [String] = ["gzip"], limits: HTTPHookLimits = .init(),
        file: StaticString = #filePath, line: UInt = #line,
    ) async throws {
        try await Rig.run(limits: limits) { rig in
            try await primed(rig)
            try await sendGzip(rig, body, encoding: encoding)
            try await assertForwardedUnchanged(rig, body: body, expectedEncoding: encoding.first ?? "", file: file, line: line)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty, file: file, line: line)
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty, file: file, line: line)
        }
    }

    // MARK: Success

    func testGzipContentLengthResponseForwardsOriginalBytesAndLeavesWithDecodedBody() async throws {
        try await Rig.run { rig in
            try await primed(rig)
            try await sendGzip(rig, Self.valid, status: .created)
            try await assertForwardedUnchanged(rig, body: Self.valid)
            try await expectTrue(rig.waitForPhase(.responseLeave))
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty, "compressed bodies never reach enter")
            let leave = try (XCTUnwrap(rig.processor.calls(.responseLeave).first))
            XCTAssertEqual(leave.response.map { String(data: $0.body, encoding: .utf8) }, Self.decoded)
            XCTAssertNil(leave.response?.headers["content-encoding"])
            XCTAssertNil(leave.response?.headers["content-length"])
            XCTAssertEqual(leave.response?.headers["content-type"], "application/json")
            XCTAssertEqual(leave.response?.status, 201)
            XCTAssertEqual(phases(rig).suffix(2), ["downstream-end-write", "response.onLeave"])
        }
    }

    func testGzipChunkedResponseWithSplitBodyPartsAndMixedCaseEncoding() async throws {
        try await Rig.run { rig in
            try await primed(rig)
            let body = Self.valid
            let head = Fixture.responseHead(contentLength: nil, extra: [("Transfer-Encoding", "chunked"), ("Content-Encoding", "  GZip ")])
            try await rig.sendResponse(
                .head(head), .body(ByteBuffer(bytes: body.prefix(10))), .body(ByteBuffer(bytes: body.dropFirst(10))), .end(nil),
            )
            let wire = try await rig.waitDownstream(4)
            XCTAssertEqual(wire.count, 4)
            XCTAssertEqual(rig.sentDownstreamRawBodies.reduce(Data(), +), body)
            XCTAssertEqual(wire[0].headers["transfer-encoding"], "chunked")
            try await expectTrue(rig.waitForPhase(.responseLeave))
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
            XCTAssertEqual(try (XCTUnwrap(rig.processor.calls(.responseLeave).first)).response.map { String(data: $0.body, encoding: .utf8) }, Self.decoded)
        }
    }

    func testLeaveWaitsForHeldEndWriteAndIsSkippedWhenItFails() async throws {
        try await Rig.run { rig in
            rig.downstreamControl.holdEnd = true
            try await primed(rig)
            try await sendGzip(rig, Self.valid)
            _ = try await rig.waitDownstream(3)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty, "leave must wait for the end-write promise")
            try await rig.downstreamControl.completeHeld(on: rig.loop)
            try await expectTrue(rig.waitForPhase(.responseLeave))
        }
        try await Rig.run { rig in
            rig.downstreamControl.failEnd = TestError.boom
            try await primed(rig)
            try await sendGzip(rig, Self.valid)
            try await expectTrue(rig.waitForClose())
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
        }
    }

    func testAuthorizationRevocationDuringLeaveStillClosesLikeIdentityLeave() async throws {
        try await Rig.run { rig in
            try await primed(rig)
            rig.processor.setAuthorized(false)
            try await sendGzip(rig, Self.valid)
            _ = try await rig.waitDownstream(3)
            try await expectTrue(rig.waitForClose())
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
        }
    }

    // MARK: Bypass: malformed streams

    func testTruncatedStreamBypasses() async throws {
        try await assertBypass(Self.valid.dropLast(4))
        try await assertBypass(Self.valid.prefix(20))
    }

    func testBadCRCAndBadISIZEBypass() async throws {
        var crc = Self.valid
        crc[crc.count - 8] ^= 0x01
        try await assertBypass(crc)
        var size = Self.valid
        size[size.count - 4] ^= 0x01
        try await assertBypass(size)
    }

    func testConcatenatedMembersAndTrailingBytesBypass() async throws {
        try await assertBypass(Self.bytes(Self.multiMemberHex))
        try await assertBypass(Self.bytes(Self.trailingHex))
    }

    func testInvalidJSONAndNonGzipBytesBypass() async throws {
        try await assertBypass(Self.bytes(Self.badJSONHex))
        try await assertBypass(Data(Self.decoded.utf8))
    }

    // MARK: Bypass: ambiguous encodings

    func testAmbiguousContentEncodingBypasses() async throws {
        for encoding in [["gzip, gzip"], ["gzip", "gzip"], ["gzip", ""], ["", "gzip"], ["gzip,"], [",gzip"], ["gzip,,"], ["gzip, identity"], ["identity, gzip"], ["deflate"], ["br"], ["x-gzip"], ["gzip;q=1"], [""]] {
            try await assertBypass(Self.valid, encoding: encoding)
        }
    }

    // MARK: Bounds

    func testDecodedSizeAtExactCapSucceedsAndOneOverBypasses() async throws {
        try await Rig.run { rig in
            try await primed(rig)
            try await sendGzip(rig, Self.bytes(Self.exactHex))
            _ = try await rig.waitDownstream(3)
            try await expectTrue(rig.waitForPhase(.responseLeave))
            XCTAssertEqual(try (XCTUnwrap(rig.processor.calls(.responseLeave).first)).response?.body.count, 24 * 1024)
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
        }
        try await assertBypass(Self.bytes(Self.overHex))
    }

    func testWireOverBodyLimitBypassesForChunkedAndContentLength() async throws {
        let big = Data(repeating: 0x61, count: 24 * 1024 + 1)
        try await Rig.run { rig in
            try await primed(rig)
            try await rig.sendResponse(
                .head(Fixture.responseHead(contentLength: nil, extra: [("Transfer-Encoding", "chunked"), ("Content-Encoding", "gzip")])),
                .body(ByteBuffer(bytes: big)), .end(nil),
            )
            _ = try await rig.waitDownstream(3)
            XCTAssertEqual(rig.sentDownstreamRawBodies.reduce(Data(), +), big)
            try await rig.quiet()
            XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
        }
        try await assertBypass(big)
    }

    func testDecodedCapShrinksWithConnectionBudget() async throws {
        let padded = Self.bytes(Self.paddedHex)
        // 321 decoded bytes fit a generous budget...
        try await Rig.run { rig in
            try await primed(rig)
            try await sendGzip(rig, padded)
            try await expectTrue(rig.waitForPhase(.responseLeave))
            XCTAssertEqual(try (XCTUnwrap(rig.processor.calls(.responseLeave).first)).response?.body.count, 321)
        }
        // ...but not when wire + retained bytes leave less than 321 of the budget.
        try await assertBypass(padded, limits: HTTPHookLimits(bodyBytes: 24 * 1024, bufferedBytes: 300))
    }

    func testTrailersLengthMismatchAndNonJSONTypeBypassWithoutChangingWire() async throws {
        for variant in 0 ..< 3 {
            try await Rig.run { rig in
                try await primed(rig)
                var head = gzipHead(length: variant == 1 ? Self.valid.count + 1 : Self.valid.count)
                if variant == 2 {
                    head.headers.replaceOrAdd(name: "Content-Type", value: "text/plain")
                }
                let trailers: HTTPHeaders? = variant == 0 ? HTTPHeaders([("X-Trailer", "value")]) : nil
                try await rig.sendResponse(.head(head), .body(ByteBuffer(bytes: Self.valid)), .end(trailers))
                let wire = try await rig.waitDownstream(3)
                XCTAssertEqual(wire.count, 3)
                XCTAssertEqual(rig.sentDownstreamRawBodies, [Self.valid])
                XCTAssertEqual(wire[0].headers["content-length"], "\(variant == 1 ? Self.valid.count + 1 : Self.valid.count)")
                XCTAssertEqual(wire[2], variant == 0 ? .endWithTrailers : .end)
                try await rig.quiet()
                XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
                XCTAssertTrue(rig.processor.calls(.responseLeave).isEmpty)
            }
        }
    }

    // MARK: Unchanged behaviour

    func testIdentityResponseStillRunsEnterAndRequestsAreUntouched() async throws {
        try await Rig.run { rig in
            try await primed(rig)
            try await rig.sendJSONResponse(#"{"ok":true}"#)
            try await expectTrue(rig.waitForPhase(.responseLeave))
            XCTAssertEqual(rig.processor.calls(.responseEnter).count, 1)
            XCTAssertEqual(rig.processor.calls(.requestEnter).count, 1)
        }
    }

    func testPipelinedGzipResponsesEachLeaveWithTheirOwnDecodedBody() async throws {
        try await Rig.run { rig in
            try await rig.sendPost()
            try await rig.sendPost(#"{"second":2}"#)
            try await expectTrue(rig.waitForPhase(.requestLeave, count: 2))
            try await sendGzip(rig, Self.valid)
            try await sendGzip(rig, Self.bytes(Self.badJSONHex))
            let wire = try await rig.waitDownstream(6)
            XCTAssertEqual(wire.count, 6)
            XCTAssertEqual(rig.sentDownstreamRawBodies, [Self.valid, Self.bytes(Self.badJSONHex)])
            try await expectTrue(rig.waitForPhase(.responseLeave))
            try await rig.quiet()
            XCTAssertEqual(rig.processor.calls(.responseLeave).count, 1, "the invalid second response bypasses")
            XCTAssertEqual(try (XCTUnwrap(rig.processor.calls(.responseLeave).first)).request.body, Data(Fixture.json.utf8))
            XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
        }
    }
}

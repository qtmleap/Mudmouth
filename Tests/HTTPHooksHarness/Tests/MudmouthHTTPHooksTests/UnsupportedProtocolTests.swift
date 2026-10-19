import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class UnsupportedProtocolTests: XCTestCase {
    private func decoder(_ rig: Rig) async throws {
        try await rig.downstream.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), position: .first).get()
    }

    func testRealDecoderRejectsUpgradeHeaderSupersetAndNestedConnectWithOrWithoutProcessor() async throws {
        let requests = [
            "GET / HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: h2c\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: api.example.com\r\nUpgrade:\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: api.example.com\r\nConnection: keep-alive,  uPgRaDe \r\n\r\n",
            "GET / HTTP/1.1\r\nHost: api.example.com\r\nConnection: keep-alive\r\nConnection: Upgrade\r\n\r\n",
            "CONNECT nested.example.com:443 HTTP/1.1\r\nHost: nested.example.com\r\n\r\n",
        ]
        for processor in [false, true] {
            for request in requests {
                try await Rig.run(installProcessor: processor) { rig in
                    try await self.decoder(rig)
                    try await rig.downstream.writeInbound(ByteBuffer(string: request))
                    try await rig.quiet()
                    XCTAssertEqual(rig.sentUpstream, [], "unsupported requests must never reach the origin")
                    XCTAssertEqual(rig.sentDownstream.count, 2)
                    if let head = rig.sentDownstream.first {
                        XCTAssertEqual(head.headers["content-length"], "0")
                        XCTAssertEqual(head.headers["connection"], "close")
                        guard case let .responseHead(status, _) = head else { return XCTFail("expected a refusal head") }
                        XCTAssertEqual(status, 501)
                    }
                    XCTAssertFalse(rig.downstream.isActive)
                    XCTAssertTrue(rig.processor.calls.isEmpty)
                    XCTAssertTrue(rig.processor.matchedHeads.isEmpty)
                }
            }
        }
    }

    func testRefusalWaitsForEarlierResponseEndWriteAndHoldsReads() async throws {
        for processor in [false, true] {
            try await Rig.run(installProcessor: processor) { rig in
                try await self.decoder(rig)
                rig.downstreamControl.holdEnd = true
                let firstBody = Fixture.json
                let first = "POST /first HTTP/1.1\r\nHost: api.example.com\r\nContent-Type: application/json\r\nContent-Length: \(firstBody.utf8.count)\r\n\r\n" + firstBody
                let upgrade = "GET /upgrade HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
                try await rig.downstream.writeInbound(ByteBuffer(string: first + upgrade))
                _ = try await rig.waitUpstream(3)
                try await rig.quiet()
                let heads = rig.sentUpstream.compactMap {
                    part -> String? in if case let .requestHead(_, uri, _) = part {
                        uri
                    } else {
                        nil
                    }
                }
                XCTAssertEqual(heads, ["/first"])
                let reads = rig.downstreamReads.count
                try await rig.pipelineRead(rig.downstream)
                XCTAssertEqual(rig.downstreamReads.count, reads, "unsupported protocol bytes must not keep arriving while prior responses drain")
                try await rig.sendJSONResponse(#"{"first":true}"#)
                _ = try await rig.waitDownstream(3)
                try await rig.quiet()
                XCTAssertEqual(rig.sentDownstream.count, 3, "refusal cannot interleave before the previous response-end write succeeds")
                XCTAssertTrue(rig.downstream.isActive)
                rig.downstreamControl.holdEnd = false
                try await rig.downstreamControl.completeHeld(on: rig.loop)
                let wire = try await rig.waitDownstream(5)
                XCTAssertEqual(wire.count, 5)
                if wire.count == 5 {
                    guard case let .responseHead(status, _) = wire[3] else { return XCTFail("expected refusal after first response") }
                    XCTAssertEqual(status, 501)
                    XCTAssertEqual(wire[4], .end)
                }
                try await expectTrue(rig.waitForClose())
                XCTAssertTrue(rig.processor.calls.allSatisfy { $0.request.path == "/first" })
            }
        }
    }

    func testUnsolicited101ClosesBeforeForwardingItToTheClient() async throws {
        for processor in [false, true] {
            try await Rig.run(installProcessor: processor) { rig in
                try await rig.upstream.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)), position: .first).get()
                try await rig.sendPost()
                _ = try await rig.waitUpstream(3)
                var response = ByteBuffer(string: "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
                response.writeBytes([UInt8](repeating: 0xFF, count: 1024))
                try await rig.upstream.writeInbound(response)
                try await rig.quiet()
                XCTAssertEqual(rig.sentDownstream, [])
                XCTAssertFalse(rig.downstream.isActive)
                XCTAssertTrue(rig.processor.calls(.responseEnter).isEmpty)
            }
        }
    }
}

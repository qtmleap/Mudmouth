import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import XCTest

@available(macOS 14, iOS 17, *)
final class InformationalResponseTests: XCTestCase {
    func testRealDecoderHeadOnly100And103PreserveFinalHooksAndNextExchange() async throws {
        for code in [100, 103] {
            try await Rig.run { rig in
                try await rig.upstream.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder(
                    leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward,
                )), position: .first).get()
                rig.processor.setResult(.responseEnter, .success(Data(Fixture.mutated.utf8)))
                for (index, path) in ["/first", "/next"].enumerated() {
                    try await rig.sendPost(uri: path)
                    _ = try await rig.waitUpstream((index + 1) * 3)
                }
                let final = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(Fixture.json.utf8.count)\r\n\r\n" + Fixture.json
                try await rig.upstream.writeInbound(ByteBuffer(string: "HTTP/1.1 \(code) Informational\r\n\r\n" + final + final))
                let wire = try await rig.waitDownstream(7)
                XCTAssertEqual(wire.count, 7, "a forwarded informational response is exactly one head")
                XCTAssertEqual(rig.processor.calls(.responseEnter).map(\.request.path), ["/first", "/next"])
                if wire.count == 7 {
                    guard case .responseHead(code, _) = wire[0] else { return XCTFail("missing informational head") }
                    XCTAssertEqual(wire[2], .body(Fixture.mutated))
                    XCTAssertEqual(wire[5], .body(Fixture.mutated))
                }
            }
        }
    }
}

import Foundation

/// Neutral immutable values offered by the TLS capture path. They contain no channel,
/// persistence object, script capability, or authorization decision.
public struct HeaderField: Sendable, Equatable, Codable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct CaptureHTTPSAuthority: Sendable, Equatable {
    public let host: String
    public let port: Int

    /// The initial capture transport supports DNS HTTPS authorities on port 443 only.
    public init?(connectAuthority: String) {
        guard connectAuthority.utf8.count <= 257 else { return nil }
        let parts = connectAuthority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "443",
              let host = Self.normalizedHost(String(parts[0])) else { return nil }
        self.host = host
        port = 443
    }

    private static func normalizedHost(_ input: String) -> String? {
        guard !input.isEmpty, input.utf8.count <= 253, input.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        var host = input.lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }

    func matchesHost(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && parts[1] == "443") else { return false }
        return Self.normalizedHost(String(parts[0])) == host
    }
}

public enum CaptureBodyUnavailableReason: String, Sendable {
    case notCaptured
    case unsupportedEncoding
    case decodeLimit
}

public enum CaptureBodyState: Sendable, Equatable {
    case absent
    case complete(Data)
    case truncated
    case unavailable(CaptureBodyUnavailableReason)
}

public struct CaptureRequestSnapshot: Sendable, Equatable {
    public let authority: CaptureHTTPSAuthority
    public let method: String
    public let encodedTarget: String
    public let headers: [HeaderField]
    public let body: CaptureBodyState
}

public struct CaptureResponseSnapshot: Sendable, Equatable {
    public let status: Int
    public let headers: [HeaderField]
    public let body: CaptureBodyState
}

public enum CaptureLifecyclePhase: String, Sendable {
    case requestHeaders = "request.headers"
    case requestCompleted = "request.completed"
    case responseHeaders = "response.headers"
    case responseCompleted = "response.completed"
}

public struct CaptureLifecycleEvent: Sendable, Equatable {
    public let eventID: UUID
    public let exchangeID: UUID
    public let time: Date
    public let phase: CaptureLifecyclePhase
    public let request: CaptureRequestSnapshot
    public let response: CaptureResponseSnapshot?
}

/// The consumer must perform a bounded, nonblocking try-offer and return false on
/// contention/full capacity. It must not run JS, disk/network I/O, await, or create
/// unbounded Tasks. Rejection never changes forwarding or legacy recording.
public typealias CaptureLifecycleSink = @Sendable (CaptureLifecycleEvent) -> Bool

/// Shared only by handlers on the accepted channel's event loop. The authority is
/// set after validating CONNECT and before any decrypted request can be forwarded.
final class CaptureConnectionContext {
    var authority: CaptureHTTPSAuthority?
}

/// Event-loop confined bounded capture. The legacy recording path is independent.
/// At most 32 exchanges and 32 KiB per encoded body are retained; compressed bodies
/// are unavailable rather than being decompressed on the forwarding loop.
final class CaptureLifecycleAccumulator {
    static let bodyLimit = 32 * 1_024
    static let headerLimit = 8 * 1_024
    static let targetLimit = 8 * 1_024
    static let exchangeLimit = 32

    private let authority: CaptureHTTPSAuthority
    private let sink: CaptureLifecycleSink
    private var exchanges: [Exchange] = []
    private var openRequestID: UUID?
    private var informationalResponse = false
    private var active = true
    // Overflow requests are counted rather than retained. Admission resumes only
    // once their ordered responses and the current request have drained.
    private var droppedResponses: UInt64 = 0
    private var droppedRequestOpen = false
    private(set) var droppedPipelineExchanges: UInt64 = 0
    private(set) var rejectedOffers: UInt64 = 0

    init(authority: CaptureHTTPSAuthority, sink: @escaping CaptureLifecycleSink) {
        self.authority = authority
        self.sink = sink
    }

    func requestHead(method: String, encodedTarget: String, headers: some Sequence<HeaderField>) {
        guard active else { return }
        guard openRequestID == nil, !droppedRequestOpen else { finish(); return }
        if exchanges.count >= Self.exchangeLimit || droppedResponses > 0 {
            // Never wrap a framing counter and risk associating another request.
            guard droppedResponses < .max else { finish(); return }
            droppedResponses += 1
            droppedRequestOpen = true
            if droppedPipelineExchanges < .max {
                droppedPipelineExchanges += 1
            }
            return
        }
        let id = UUID()
        openRequestID = id
        let fields = Self.validatedHeaders(headers)
        let hosts = fields?.filter { $0.name == "host" } ?? []
        let valid = method.utf8.count <= 32 && Self.isToken(method)
            && Self.validTarget(encodedTarget) && hosts.count == 1 && authority.matchesHost(hosts[0].value)
        let request = valid ? fields.map {
            CaptureRequestSnapshot(authority: authority, method: method, encodedTarget: encodedTarget, headers: $0, body: .unavailable(.notCaptured))
        } : nil
        exchanges.append(Exchange(id: id, request: request, requestBody: Body(headers: fields ?? [])))
        if let request {
            emit(.requestHeaders, id: id, request: request)
        }
    }

    func requestBody(_ bytes: some Collection<UInt8>) {
        guard active, let id = openRequestID, let index = exchanges.firstIndex(where: { $0.id == id }), exchanges[index].request != nil else { return }
        exchanges[index].requestBody.append(bytes)
    }

    func requestEnd() {
        guard active else { return }
        if droppedRequestOpen {
            droppedRequestOpen = false; return
        }
        guard let id = openRequestID else { return }
        openRequestID = nil
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        exchanges[index].requestCompleted = true
        if let request = exchanges[index].request {
            let completed = CaptureRequestSnapshot(authority: request.authority, method: request.method, encodedTarget: request.encodedTarget,
                                                   headers: request.headers, body: exchanges[index].requestBody.completed)
            exchanges[index].request = completed
            emit(.requestCompleted, id: id, request: completed)
        }
        if exchanges[index].responseCompleted {
            exchanges.remove(at: index)
        }
    }

    func responseHead(status: Int, headers: some Sequence<HeaderField>) {
        guard active, !exchanges.isEmpty || droppedResponses > 0 else { return }
        if (100 ..< 200).contains(status) {
            if status == 101 {
                finish()
            } else {
                informationalResponse = true
            }
            return
        }
        informationalResponse = false
        guard let index = exchanges.firstIndex(where: { !$0.responseCompleted }) else { return }
        guard exchanges[index].response == nil else { finish(); return }
        guard let request = exchanges[index].request, let fields = Self.validatedHeaders(headers), (200 ... 599).contains(status) else { return }
        let noBody = request.method == "HEAD" || status == 204 || status == 304
        exchanges[index].responseBody = Body(headers: fields, forbidsBody: noBody)
        let response = CaptureResponseSnapshot(status: status, headers: fields, body: noBody ? .absent : .unavailable(.notCaptured))
        exchanges[index].response = response
        emit(.responseHeaders, id: exchanges[index].id, request: request, response: response)
    }

    func responseBody(_ bytes: some Collection<UInt8>) {
        guard active, !informationalResponse, let index = exchanges.firstIndex(where: { !$0.responseCompleted }), exchanges[index].response != nil else { return }
        exchanges[index].responseBody?.append(bytes)
    }

    func responseEnd() {
        guard active else { return }
        if informationalResponse {
            informationalResponse = false; return
        }
        guard let index = exchanges.firstIndex(where: { !$0.responseCompleted }) else {
            if droppedResponses > 0 {
                droppedResponses -= 1
            }
            return
        }
        exchanges[index].responseCompleted = true
        let exchange = exchanges[index]
        if exchange.requestCompleted {
            exchanges.remove(at: index)
        }
        if let request = exchange.request, let response = exchange.response, let body = exchange.responseBody {
            emit(.responseCompleted, id: exchange.id, request: request,
                 response: CaptureResponseSnapshot(status: response.status, headers: response.headers, body: body.completed))
        }
    }

    /// EOF/error never manufactures request.completed or response.completed.
    func finish() {
        active = false
        exchanges.removeAll(keepingCapacity: false)
        openRequestID = nil
        droppedResponses = 0
        droppedRequestOpen = false
    }

    private func emit(_ phase: CaptureLifecyclePhase, id: UUID, request: CaptureRequestSnapshot, response: CaptureResponseSnapshot? = nil) {
        let event = CaptureLifecycleEvent(eventID: UUID(), exchangeID: id, time: Date(), phase: phase, request: request, response: response)
        if !sink(event), rejectedOffers != .max {
            rejectedOffers += 1
        }
    }

    private struct Exchange {
        let id: UUID
        var request: CaptureRequestSnapshot?
        var requestBody: Body
        var response: CaptureResponseSnapshot?
        var responseBody: Body?
        var requestCompleted = false
        var responseCompleted = false
    }

    private struct Body {
        private var data = Data()
        private var receivedBytes = 0
        private var truncated = false
        private let unsupported: Bool
        private let expectedLength: Int?
        private let forbidsBody: Bool

        init(headers: [HeaderField], forbidsBody: Bool = false) {
            self.forbidsBody = forbidsBody
            let encodings = headers.filter { $0.name == "content-encoding" }.map { $0.value.lowercased().trimmingCharacters(in: .whitespaces) }
            unsupported = encodings.contains { $0 != "identity" }
            let lengths = headers.filter { $0.name == "content-length" }.map(\.value)
            expectedLength = lengths.count == 1 ? Int(lengths[0]) : nil
        }

        mutating func append(_ bytes: some Collection<UInt8>) {
            guard !truncated else { return }
            guard bytes.count <= CaptureLifecycleAccumulator.bodyLimit - receivedBytes, !forbidsBody || bytes.isEmpty else {
                truncated = true; data.removeAll(keepingCapacity: false); return
            }
            receivedBytes += bytes.count
            if !unsupported {
                data.append(contentsOf: bytes)
            }
        }

        var completed: CaptureBodyState {
            guard !truncated else { return .truncated }
            if !forbidsBody, let expectedLength, expectedLength != receivedBytes {
                return .truncated
            }
            if receivedBytes == 0 {
                return .absent
            }
            if unsupported {
                return .unavailable(.unsupportedEncoding)
            }
            return .complete(data)
        }
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    private static func validatedHeaders(_ input: some Sequence<HeaderField>) -> [HeaderField]? {
        var result: [HeaderField] = []
        var byteCount = 2
        for field in input {
            // Bound before normalizing, parsing, or serializing hostile field strings.
            guard field.name.utf8.count <= headerLimit - byteCount,
                  field.value.utf8.count <= headerLimit - byteCount - field.name.utf8.count,
                  isToken(field.name), field.value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { return nil }
            byteCount += field.name.utf8.count + field.value.utf8.count + 22 + (result.isEmpty ? 0 : 1)
            guard byteCount <= headerLimit else { return nil }
            let name = field.name.lowercased()
            if name == "connection" {
                let tokens = field.value.split(separator: ",", omittingEmptySubsequences: false)
                guard tokens.allSatisfy({ isToken($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
            }
            result.append(HeaderField(name: name, value: field.value))
        }
        // JSON escaping can expand values, so the semantic pair budget alone is insufficient.
        guard let encoded = try? JSONEncoder().encode(result), encoded.count <= headerLimit else { return nil }
        return result
    }

    private static func validTarget(_ target: String) -> Bool {
        guard !target.isEmpty, target.utf8.count <= targetLimit, target.hasPrefix("/"), !target.hasPrefix("//") else { return false }
        let bytes = Array(target.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte > 32, byte < 127, byte != 35, byte != 92 else { return false }
            if byte == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 2
            }
            index += 1
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
    }
}

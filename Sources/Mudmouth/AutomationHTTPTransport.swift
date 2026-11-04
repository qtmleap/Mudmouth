import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// Direct, non-proxy native egress. Only the workflow service owns this capability.
public final class AutomationHTTPTransport: @unchecked Sendable {
    public struct Header: Sendable, Equatable {
        public let name: String
        public let value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    public struct Origin: Sendable, Equatable {
        public let host: String
        public let port: Int
        public init(host: String, port: Int = 443) throws {
            let ascii = Array(host.utf8)
            guard !ascii.isEmpty, ascii.count <= 253, (1...65535).contains(port),
                  ascii.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                  !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
                  host.split(separator: ".").allSatisfy({ $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { throw Failure.invalidRequest }
            self.host = host.lowercased(); self.port = port
        }
    }
    public struct Request: Sendable {
        public let origin: Origin
        public let method: String
        public let encodedTarget: String
        public let headers: [Header]
        public let body: Data?
        public let contentType: String?
        public init(origin: Origin, method: String, encodedTarget: String, headers: [Header], body: Data? = nil, contentType: String? = nil) {
            self.origin = origin; self.method = method; self.encodedTarget = encodedTarget; self.headers = headers; self.body = body; self.contentType = contentType
        }
    }
    public struct Response: Sendable {
        public let status: Int
        public let headers: [Header]
        public let body: Data?
    }
    public enum EndpointCredentials: Sendable { case none; case bearer(String) }
    public enum Failure: Error, Sendable, Equatable {
        case invalidRequest, saturated, cancelled, deadline, connection, tls, framing, earlyEOF, headerLimit, bodyLimit, redirect, upgrade, unsupportedEncoding, closed
    }
    /// A token belongs to exactly one operation. It never cancels another request.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var owner: UUID?
        private var callback: (@Sendable () -> Void)?
        public init() {}
        public func cancel() {
            let call = lock.withLock { cancelled = true; return callback }
            call?()
        }
        fileprivate func register(owner: UUID, _ callback: @escaping @Sendable () -> Void) -> Bool {
            lock.withLock {
                guard self.owner == nil, !cancelled else { return false }
                self.owner = owner; self.callback = callback; return true
            }
        }
        fileprivate func clear(owner: UUID) { lock.withLock { if self.owner == owner { callback = nil } } }
    }
    private let group: MultiThreadedEventLoopGroup
    private let tls: NIOSSLContext
    private let timeout: TimeAmount
    private let lock = NSLock()
    private var operations: [UUID: HTTPExchange] = [:]
    private var closed = false

    public convenience init() throws {
        try self.init(configuration: .makeClientConfiguration(), timeout: .seconds(10))
    }
    /// Internal fixture trust root retains full certificate AND hostname verification.
    internal convenience init(testRoot: String, timeout: TimeAmount = .seconds(10)) throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .file(testRoot)
        try self.init(configuration:configuration, timeout:timeout)
    }
    private init(configuration: TLSConfiguration, timeout: TimeAmount) throws {
        var verified = configuration
        verified.certificateVerification = .fullVerification
        self.tls = try NIOSSLContext(configuration:verified)
        self.timeout = timeout
        self.group = MultiThreadedEventLoopGroup(numberOfThreads:1)
    }
    /// Must be called by the owning service after its tasks finish; closes owned I/O.
    public func shutdown() {
        let active: [HTTPExchange]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            return Array(operations.values)
        }
        guard let active else { return }
        for exchange in active { exchange.cancel(.closed) }
        try? group.syncShutdownGracefully()
    }

    public func executeSameOrigin(_ request: Request, cancellation: Cancellation = .init()) async throws -> Response {
        let headers = try Self.prepare(request)
        let id = UUID()
        let loop = group.next()
        let exchange = try lock.withLock {
            guard !closed else { throw Failure.closed }
            guard operations.count < 2 else { throw Failure.saturated }
            let exchange = HTTPExchange(loop:loop, request:request, headers:headers, tls:tls, timeout:timeout)
            operations[id] = exchange
            return exchange
        }
        defer { cancellation.clear(owner:id); _ = lock.withLock { operations.removeValue(forKey:id) } }
        guard cancellation.register(owner:id, { exchange.cancel(.cancelled) }) else {
            exchange.cancel(.cancelled)
            return try await exchange.promise.futureResult.get()
        }
        return try await withTaskCancellationHandler {
            exchange.start()
            return try await exchange.promise.futureResult.get()
        } onCancel: { cancellation.cancel() }
    }

    /// No captured header input exists on this API. Each attempt uses immutable bytes,
    /// the recorded delivery identity and only independently configured credentials.
    public func deliver(endpoint: URL, payload: Data, deliveryID: UUID, credentials: EndpointCredentials, cancellation: Cancellation = .init()) async throws -> Response {
        guard let parts = URLComponents(url:endpoint,resolvingAgainstBaseURL:false),
              parts.scheme?.lowercased() == "https", let host = parts.host,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw Failure.invalidRequest }
        let origin = try Origin(host:host,port:parts.port ?? 443)
        var headers = [Header(name:"Idempotency-Key", value:deliveryID.uuidString)]
        switch credentials {
        case .none: break
        case .bearer(let value):
            guard !value.isEmpty, Self.validValue(value), value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw Failure.invalidRequest }
            headers.append(.init(name:"Authorization",value:"Bearer " + value))
        }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let target = path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        return try await executeSameOrigin(.init(origin:origin,method:"POST",encodedTarget:target,headers:headers,body:payload,contentType:"application/json"), cancellation:cancellation)
    }

    fileprivate static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
    fileprivate static func validValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }
    /// Only dechunking is implemented. Do not expose transfer-compressed bytes as
    /// a complete decoded body; reject malformed lists and duplicate codings too.
    fileprivate static func chunkedTransfer(_ values: [String]) throws -> Bool {
        guard !values.isEmpty else { return false }
        var tokens: [String] = []
        var seen = Set<String>()
        for value in values {
            for component in value.split(separator:",",omittingEmptySubsequences:false) {
                let token = component.trimmingCharacters(in:CharacterSet(charactersIn:" \t")).lowercased()
                guard validName(token), seen.insert(token).inserted else { throw Failure.framing }
                tokens.append(token)
            }
        }
        guard tokens == ["chunked"] else { throw Failure.unsupportedEncoding }
        return true
    }

    private static func prepare(_ request: Request) throws -> HTTPHeaders {
        guard ["GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"].contains(request.method),
              request.encodedTarget.hasPrefix("/"), !request.encodedTarget.hasPrefix("//"),
              request.encodedTarget.utf8.count <= 8192,
              request.encodedTarget.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 35 && $0 != 92 }) else { throw Failure.invalidRequest }
        // Enforce a completely encoded target, including well-formed percent triplets.
        let target = Array(request.encodedTarget.utf8)
        var i = 0
        while i < target.count {
            if target[i] == 37 {
                guard i + 2 < target.count, target[(i+1)...(i+2)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidRequest }
                i += 3
            } else { i += 1 }
        }
        guard (request.body?.count ?? 0) <= 32768 else { throw Failure.bodyLimit }
        let forbidden: Set<String> = ["host","connection","keep-alive","proxy-connection","proxy-authenticate","proxy-authorization","te","trailer","transfer-encoding","upgrade","content-length","content-type","content-encoding","content-md5","digest","content-digest","repr-digest","expect"]
        var output = HTTPHeaders()
        let host = request.origin.host + (request.origin.port == 443 ? "" : ":\(request.origin.port)")
        output.add(name:"Host",value:host)
        for header in request.headers {
            guard validName(header.name), validValue(header.value), !forbidden.contains(header.name.lowercased()) else { throw Failure.invalidRequest }
            // Native representation negotiation is regenerated independently of
            // inherited headers because this bounded transport does not decode gzip/br.
            if header.name.lowercased() == "accept-encoding" { continue }
            output.add(name:header.name,value:header.value)
        }
        if let body = request.body {
            output.add(name:"Content-Length",value:String(body.count))
            if let contentType = request.contentType {
                guard !contentType.isEmpty, validValue(contentType) else { throw Failure.invalidRequest }
                output.add(name:"Content-Type",value:contentType)
            }
        } else {
            guard request.contentType == nil else { throw Failure.invalidRequest }
            // Explicit length avoids encoder-dependent implicit chunking on POST/PUT.
            output.add(name:"Content-Length",value:"0")
        }
        output.add(name:"Accept-Encoding",value:"identity")
        output.add(name:"Connection",value:"close")
        guard output.reduce(2, { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }) <= 8192 else { throw Failure.headerLimit }
        return output
    }
}

/// Confined to one EventLoop; no state or cancellation is shared across connections.
private final class HTTPExchange: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let loop: EventLoop
    let promise: EventLoopPromise<AutomationHTTPTransport.Response>
    let request: AutomationHTTPTransport.Request
    let headers: HTTPHeaders
    let tls: NIOSSLContext
    let timeout: TimeAmount
    var channels: [Channel] = []
    var deadline: Scheduled<Void>?
    var finished = false
    var finalHead: HTTPResponseHead?
    var body = Data()
    var headerBytes = 0
    var informationalCount = 0
    init(loop:EventLoop,request:AutomationHTTPTransport.Request,headers:HTTPHeaders,tls:NIOSSLContext,timeout:TimeAmount) {
        self.loop=loop; self.promise=loop.makePromise(); self.request=request; self.headers=headers; self.tls=tls; self.timeout=timeout
    }
    func start() { loop.execute { self.connect() } }
    func cancel(_ failure: AutomationHTTPTransport.Failure) { loop.execute { self.finish(.failure(failure)) } }
    func connect() {
        guard !finished else { return }
        deadline = loop.scheduleTask(in:timeout) { self.finish(.failure(.deadline)) }
        ClientBootstrap(group:loop).connectTimeout(timeout).channelInitializer { channel in
            // Initializer runs BEFORE connecting, so cancellation owns a connecting channel too.
            self.channels.append(channel)
            guard !self.finished else { return channel.close() }
            do {
                let isIPAddress = self.request.origin.host.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
                let ssl = try NIOSSLClientHandler(context:self.tls, serverHostname:isIPAddress ? nil : self.request.origin.host)
                try channel.pipeline.syncOperations.addHandlers([ssl, ResponseWireBudget(isHEAD:self.request.method == "HEAD") { self.finish(.failure($0)) }, HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy:.dropBytes, informationalResponseStrategy:.forward)), self])
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch { return channel.eventLoop.makeFailedFuture(AutomationHTTPTransport.Failure.tls) }
        }.connect(host:request.origin.host,port:request.origin.port).whenComplete { result in
            switch result {
            case .failure(let error): self.finish(.failure(self.failure(error)))
            case .success(let channel):
                guard !self.finished else { channel.close(promise:nil); return }
                let head = HTTPRequestHead(version:.http1_1,method:HTTPMethod(rawValue:self.request.method),uri:self.request.encodedTarget,headers:self.headers)
                channel.write(HTTPClientRequestPart.head(head),promise:nil)
                if let body = self.request.body, !body.isEmpty {
                    channel.write(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(bytes:body))),promise:nil)
                }
                channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { self.finish(.failure(self.failure($0))) }
            }
        }
    }
    func channelRead(context:ChannelHandlerContext,data:NIOAny) {
        guard !finished else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            headerBytes += head.headers.reduce(2, { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 })
            guard headerBytes <= 8192 else { finish(.failure(.headerLimit)); return }
            let status = Int(head.status.code)
            guard status != 101 else { finish(.failure(.upgrade)); return }
            if status < 200 {
                informationalCount += 1
                if informationalCount > 16 { finish(.failure(.framing)) }
                return
            }
            guard finalHead == nil else { finish(.failure(.framing)); return }
            // 304 is a terminal no-body response, not a redirect to follow.
            guard !(300...399).contains(status) || status == 304 else { finish(.failure(.redirect)); return }
            guard head.headers.allSatisfy({ AutomationHTTPTransport.validName($0.name) && AutomationHTTPTransport.validValue($0.value) }) else { finish(.failure(.framing)); return }
            do { _ = try AutomationHTTPTransport.chunkedTransfer(head.headers["Transfer-Encoding"]) }
            catch { finish(.failure((error as? AutomationHTTPTransport.Failure) ?? .framing)); return }
            let noBody = request.method == "HEAD" || status == 204 || status == 304
            if !noBody {
                let encodings = head.headers["Content-Encoding"]
                guard encodings.allSatisfy({ $0.trimmingCharacters(in:.whitespaces).lowercased() == "identity" }) else { finish(.failure(.unsupportedEncoding)); return }
                if let length = head.headers.first(name:"Content-Length"), let count = UInt64(length), count > 32768 { finish(.failure(.bodyLimit)); return }
            }
            finalHead = head
        case .body(var bytes):
            guard finalHead != nil else { finish(.failure(.framing)); return }
            guard body.count + bytes.readableBytes <= 32768 else { finish(.failure(.bodyLimit)); return }
            body.append(contentsOf:bytes.readBytes(length:bytes.readableBytes) ?? [])
        case .end(let trailers):
            guard let head = finalHead else { return } // informational responses are never final
            if let trailers {
                headerBytes += trailers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 })
                guard headerBytes <= 8192 else { finish(.failure(.headerLimit)); return }
            }
            let noBody = request.method == "HEAD" || head.status.code == 204 || head.status.code == 304
            finish(.success(.init(status:Int(head.status.code),headers:head.headers.map { .init(name:$0.name,value:$0.value) },body:noBody ? nil : body)))
        }
    }
    func channelInactive(context:ChannelHandlerContext) { finish(.failure(.earlyEOF)); context.fireChannelInactive() }
    func errorCaught(context:ChannelHandlerContext,error:Error) { finish(.failure(failure(error))) }
    func failure(_ error: Error) -> AutomationHTTPTransport.Failure {
        if let failure = error as? AutomationHTTPTransport.Failure { return failure }
        if let parser = error as? HTTPParserError {
            if parser == .headerOverflow { return .headerLimit }
            if parser == .invalidEOFState { return .earlyEOF }
            return .framing
        }
        if let sslError = error as? NIOSSLError {
            if case .uncleanShutdown = sslError { return .earlyEOF }
            return .tls
        }
        if error is NIOSSLExtraError { return .tls }
        if let connection = error as? NIOConnectionError,
           connection.connectionErrors.contains(where: { failure($0.error) == .tls }) { return .tls }
        return .connection
    }
    func finish(_ result: Result<AutomationHTTPTransport.Response, AutomationHTTPTransport.Failure>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        for channel in channels { channel.close(promise:nil) }
        channels.removeAll()
        promise.completeWith(result.mapError { $0 as Error })
    }
}

/// Enforces budgets before NIO can buffer incomplete heads or trailers. Chunk
/// lengths identify trailer boundaries; body contents are never delimiter-scanned.
/// NIO remains responsible for complete HTTP syntax and semantic validation.
private final class ResponseWireBudget: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    private enum State { case head, chunkSize, chunkData(Int), chunkCRLF(Int), trailers, passthrough, failed }
    private var state: State = .head
    private var headerBytes = 0
    private var line: [UInt8] = []
    private var bodyBytes = 0
    private let isHEAD: Bool
    private let fail: (AutomationHTTPTransport.Failure) -> Void
    init(isHEAD: Bool, fail: @escaping (AutomationHTTPTransport.Failure) -> Void) { self.isHEAD = isHEAD; self.fail = fail }

    func channelRead(context:ChannelHandlerContext,data:NIOAny) {
        do {
            let buffer = unwrapInboundIn(data)
            for byte in buffer.readableBytesView {
                switch state {
                case .head:
                    try countHeaderByte()
                    line.append(byte)
                    if line.count >= 4 && line.suffix(4).elementsEqual([13,10,13,10]) { try finishHead() }
                case .chunkSize:
                    // Extensions and unfinished size lines are bounded independently;
                    // only status/head/trailer bytes consume the aggregate header cap.
                    guard line.count < 8192 else { throw AutomationHTTPTransport.Failure.framing }
                    line.append(byte)
                    if line.count >= 2 && line.suffix(2).elementsEqual([13,10]) { try finishChunkSize() }
                case .chunkData(let remaining):
                    state = remaining == 1 ? .chunkCRLF(0) : .chunkData(remaining-1)
                case .chunkCRLF(let index):
                    guard byte == (index == 0 ? 13 : 10) else { throw AutomationHTTPTransport.Failure.framing }
                    state = index == 0 ? .chunkCRLF(1) : .chunkSize
                case .trailers:
                    try countHeaderByte()
                    line.append(byte)
                    if line.count >= 2 && line.suffix(2).elementsEqual([13,10]) {
                        if line.count == 2 { state = .passthrough }
                        line.removeAll(keepingCapacity:true)
                    }
                case .passthrough:
                    context.fireChannelRead(data)
                    return
                case .failed: return
                }
            }
            context.fireChannelRead(data)
        } catch {
            state = .failed
            fail((error as? AutomationHTTPTransport.Failure) ?? .framing)
        }
    }
    private func countHeaderByte() throws {
        headerBytes += 1
        guard headerBytes <= 8192 else { throw AutomationHTTPTransport.Failure.headerLimit }
    }
    private func finishHead() throws {
        let lines = String(decoding:line,as:UTF8.self).components(separatedBy:"\r\n")
        let statusParts = lines[0].split(separator:" ")
        guard statusParts.count > 1, let status = Int(statusParts[1]) else { throw AutomationHTTPTransport.Failure.framing }
        line.removeAll(keepingCapacity:true)
        if (100..<200).contains(status), status != 101 { return }
        var transferValues: [String] = []
        for field in lines.dropFirst() {
            guard let colon = field.firstIndex(of:":") else { continue }
            if field[..<colon].lowercased() == "transfer-encoding" { transferValues.append(String(field[field.index(after:colon)...])) }
        }
        let chunked = try AutomationHTTPTransport.chunkedTransfer(transferValues)
        state = chunked && !isHEAD && status != 204 && status != 304 ? .chunkSize : .passthrough
    }
    private func finishChunkSize() throws {
        let content = line.dropLast(2)
        let size = content.prefix(while: { $0 != 59 }) // bounded optional chunk extension
        guard !size.isEmpty, size.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let count = UInt64(String(decoding:size,as:UTF8.self),radix:16) else { throw AutomationHTTPTransport.Failure.framing }
        guard count <= UInt64(32768-bodyBytes) else { throw AutomationHTTPTransport.Failure.bodyLimit }
        line.removeAll(keepingCapacity:true)
        bodyBytes += Int(count)
        state = count == 0 ? .trailers : .chunkData(Int(count))
    }
}

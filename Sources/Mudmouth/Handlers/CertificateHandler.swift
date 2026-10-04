//
//  CertificateHandler.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/12.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import NIOCore
import NIOHTTP1
import X509

/// X509証明書をインストールするためのChannelInboundHandler
/// PacketTunnelには直接関与しない
class CertificateHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let certificate: Certificate

    init(certificate: Certificate) {
        self.certificate = certificate
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let httpData = unwrapInboundIn(data)
        guard case .head = httpData else {
            return
        }
        guard CaptureAuthorization.isGranted else {
            let head = HTTPResponseHead(version: .http1_1, status: .forbidden,
                                        headers: HTTPHeaders([("Content-Length", "0"), ("Connection", "close")]))
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
            return
        }
        let pemString: String = certificate.pemRepresentation
        let headers: HTTPHeaders = .init([
            ("Content-Length", String(pemString.utf8.count)),
            ("Content-Type", "application/x-x509-ca-cert"),
        ])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let buffer: ByteBuffer = context.channel.allocator.buffer(string: pemString)
        let body: HTTPServerResponsePart = .body(.byteBuffer(buffer))
        context.write(wrapOutboundOut(body), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

extension HTTPResponseEncoder: @unchecked @retroactive Sendable {}

extension ByteToMessageHandler: @unchecked @retroactive Sendable {}

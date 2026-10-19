//
//  NewConnectHandler.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

final class NewConnectHandler: ChannelInboundHandler {
    // MARK: Internal

    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let httpData: InboundIn = unwrapInboundIn(data)
        switch state {
            case .idle:
                switch httpData {
                    case let .head(head):
                        handleHead(context: context, head: head)
                    default:
                        return
                }
                state = .established

            case .awaitingEnd:
                switch httpData {
                    case let .end(headers):
                        handleEnd(context: context, headers: headers)
                    default:
                        break
                }

            case .established:
                context.fireChannelRead(data)
        }
    }

    // MARK: Private

    private enum State {
        case idle
        case awaitingEnd
        case established
    }

    private var state: State = .idle
    private let host: String = "api.lp1.av5ja.srv.nintendo.net"
    private let port: Int = 443

    private func handleEnd(context: ChannelHandlerContext, headers: HTTPHeaders?) {
        context.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self)
            // swiftlint:disable:next closure_body_length
            .whenSuccess { [self] handler in
                NSLog("HandleEnd->WhenSuccess")
                context.pipeline.removeHandler(context: handler, promise: nil)
                ClientBootstrap(group: context.eventLoop)
                    .channelInitializer { channel in
                        let configuration: TLSConfiguration = .makeClientConfiguration()
                        // swiftlint:disable:next force_try
                        let context: NIOSSLContext = try! .init(configuration: configuration)
                        return channel.pipeline.addHandlers([
                            // swiftlint:disable:next force_try
                            try! NIOSSLClientHandler(context: context, serverHostname: self.host),
                            HTTPRequestEncoder(),
                            ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                        ])
                    }
                    .connect(host: host, port: port)
                    .whenComplete { [self] result in
                        NSLog("HandleEnd->WhenSuccess->Result")
                        let headers: HTTPHeaders = .init([("Content-Length", "0")])
                        switch result {
                            case let .success(client):
                                let head: HTTPResponseHead = .init(
                                    version: .init(major: 1, minor: 1), status: .ok, headers: headers,
                                )
                                context.write(wrapOutboundOut(.head(head)), promise: nil)
                                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                                context.pipeline.context(handlerType: HTTPResponseEncoder.self)
                                    .whenSuccess { handler in
                                        NSLog("HandleEnd->WhenSuccess->Result->WhenSuccess")
                                        context.pipeline.removeHandler(context: handler, promise: nil)
                                        let (local, remote) = GlueHandler.matchedPair()
                                        context.pipeline.addHandler(local)
                                            .and(client.pipeline.addHandler(remote))
                                            .whenComplete { result in
                                                NSLog("HandleEnd->WhenSuccess->Result->WhenSuccess->WhenComplete")
                                                switch result {
                                                    case .success:
                                                        self.state = .established
                                                    case .failure:
                                                        context.close(promise: nil)
                                                }
                                            }
                                    }

                            case .failure:
                                let head: HTTPResponseHead = .init(
                                    version: .init(major: 1, minor: 1), status: .notFound, headers: headers,
                                )
                                context.write(wrapOutboundOut(.head(head)), promise: nil)
                                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                        }
                    }
            }
    }

    private func handleHead(context: ChannelHandlerContext, head: HTTPRequestHead) {
        switch head.method {
            case .CONNECT:
                state = .awaitingEnd
            default:
                let headers: HTTPHeaders = .init([("Content-Length", "0")])
                let head: HTTPResponseHead = .init(
                    version: .init(major: 1, minor: 1), status: .methodNotAllowed, headers: headers,
                )
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

//
//  ProxyHandler.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import DequeModule
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import OSLog
import SwiftData
import SwiftyLogger
import UserNotifications

final class ProxyHandler: NotificationHandler, ChannelDuplexHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPClientRequestPart
    typealias OutboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private let options: [ProxyOption]

    init(options: [ProxyOption] = []) {
        self.options = options
    }

    private var queues: Deque<HTTP.MessageContainer> = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard CaptureAuthorization.isGranted else { context.close(promise: nil); return }
        let httpData = unwrapInboundIn(data)
        switch httpData {
            case let .head(head):
                queues.append(.init(request: .init(head: head)))
                context.fireChannelRead(wrapInboundOut(.head(head)))

            case let .body(body):
                queues.last?.request.add(body)
                context.fireChannelRead(wrapInboundOut(.body(.byteBuffer(body))))

            case .end:
                context.fireChannelRead(wrapInboundOut(.end(nil)))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard CaptureAuthorization.isGranted else {
            promise?.fail(CaptureAuthorization.Failure.consentRequired)
            context.close(promise: nil)
            return
        }
        let httpData = unwrapOutboundIn(data)
        switch httpData {
            case let .head(head):
                if var queue = queues.popFirst() {
                    queue.response = .init(head: head)
                    queues.prepend(queue)
                }
                context.write(wrapOutboundOut(.head(head)), promise: promise)

            case let .body(body):
                if var message = queues.popFirst() {
                    message.response?.add(body)
                    queues.prepend(message)
                }
                context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: promise)

            case .end:
                if let queue = queues.popFirst() {
                    guard CaptureAuthorization.isGranted,
                          let option = options.first(where: { $0.capture && $0.host == queue.request.host }) else { context.write(wrapOutboundOut(.end(nil)), promise: promise); return }
                    Task { @MainActor in
                        guard CaptureAuthorization.isGranted else { return }
                        let context = ModelContainer.default.mainContext
                        let record = Record(container: queue)
                        context.insert(record)
                        let host = queue.request.host
                        let existing = try? context.fetch(FetchDescriptor<RecordGroup>(predicate: #Predicate { $0.host == host })).first
                        if let existing {
                            existing.records.append(record)
                        } else {
                            context.insert(RecordGroup(host: host, records: [record]))
                        }
                        do { try context.save() } catch { return }
                        guard CaptureAuthorization.isGranted, option.notify,
                              let path = URL(string: queue.request.path)?.path,
                              option.targets(keyPath: \.notify).contains(path) else { return }
                        let center = UNUserNotificationCenter.current()
                        let settings = await center.notificationSettings()
                        guard CaptureAuthorization.isGranted, settings.authorizationStatus == .authorized else { return }
                        let content = UNMutableNotificationContent()
                        content.title = NSLocalizedString("UNNOTIFICATION_REQUEST_TITLE", bundle: .module, comment: "")
                        content.body = NSLocalizedString("UNNOTIFICATION_REQUEST_BODY", bundle: .module, comment: "")
                        content.userInfo = ["recordID": record.id.uuidString]
                        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                        try? await center.add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: trigger))
                        if !CaptureAuthorization.isGranted {
                            center.removePendingNotificationRequests(withIdentifiers: [record.id.uuidString])
                            center.removeDeliveredNotifications(withIdentifiers: [record.id.uuidString])
                        }
                    }
                }

                context.write(wrapOutboundOut(.end(nil)), promise: promise)
        }
    }

    func channelInactive(context _: ChannelHandlerContext) {}
}

//
//  ProxyRecorder.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import DequeModule
import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import SwiftData
import SwiftyLogger
import UserNotifications

/// Persists and notifies for the messages the lifecycle handler actually forwarded.
/// Lifecycle handling (`HTTPHookHandler`) and record persistence are deliberately separate.
final class ProxyRecorder: NotificationHandler, HTTPExchangeObserving {
    private let options: [ProxyOption]
    /// One slot per outstanding exchange, in FIFO order. `nil` keeps the association for a hostless request
    /// or one seen without capture authorization, so later responses never pair with the wrong request.
    private var queues: Deque<HTTP.MessageContainer?> = []

    init(options: [ProxyOption] = []) {
        self.options = options
    }

    func requestHead(_ head: HTTPRequestHead) {
        guard CaptureAuthorization.isGranted, head.host != nil else {
            queues.append(nil)
            return
        }
        queues.append(.init(request: .init(head: head)))
    }

    func requestBody(_ buffer: ByteBuffer) {
        queues.last??.request.add(buffer)
    }

    func responseHead(_ head: HTTPResponseHead) {
        if let first = queues.first, var queue = first {
            queue.response = .init(head: head)
            queues[0] = queue
        }
    }

    func responseBody(_ buffer: ByteBuffer) {
        if let first = queues.first, var message = first {
            message.response?.add(buffer)
            queues[0] = message
        }
    }

    func responseEnd() {
        guard let slot = queues.popFirst(), let queue = slot else { return }
        persist(queue)
    }

    /// Pops synchronously (FIFO), but persists only once the forwarded end was actually written.
    func responseEnd(written: EventLoopFuture<Void>) {
        guard let slot = queues.popFirst(), let queue = slot else { return }
        written.whenSuccess { [self] in persist(queue) }
    }

    private func persist(_ queue: HTTP.MessageContainer) {
        guard CaptureAuthorization.isGranted,
              let option = options.first(where: { $0.capture && $0.host == queue.request.host }) else { return }
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
}

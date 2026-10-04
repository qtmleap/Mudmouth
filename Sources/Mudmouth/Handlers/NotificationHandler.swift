//
//  NotificationHandler.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation

// import Gzip
import NIOHTTP1
import UserNotifications

class NotificationHandler {
    ///    @MainActor
    func requestNotification(request: HTTP.Request) async throws {
        let content: UNMutableNotificationContent = .init()
        content.title = NSLocalizedString("TOKEN_CAPTURED_TITLE", bundle: .module, comment: "")
        content.body = NSLocalizedString("TOKEN_CAPTURED_BODY", bundle: .module, comment: "")
//        content.userInfo = [
//            "headers": request.headers.base64EncodedString,
//            "body": request.body.base64EncodedString,
//        ]
        let triger: UNTimeIntervalNotificationTrigger = .init(timeInterval: 1, repeats: false)
        let request: UNNotificationRequest = .init(
            identifier: UUID().uuidString, content: content, trigger: triger,
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}

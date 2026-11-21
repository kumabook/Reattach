import UIKit
import UserNotifications

/// Numbered reply buttons on permission notifications. They also appear on a
/// paired Apple Watch, where a tap is delivered to this app in the background.
enum PermissionNotificationActions {
    static let maxChoices = 6
    private static let actionPrefix = "choice-"

    static var categories: Set<UNNotificationCategory> {
        Set((2...maxChoices).map { count in
            UNNotificationCategory(
                identifier: "PERMISSION_\(count)",
                actions: (1...count).map { number in
                    UNNotificationAction(identifier: actionPrefix + String(number),
                                         title: String(number),
                                         options: [.authenticationRequired])
                },
                intentIdentifiers: []
            )
        })
    }

    static func choice(for actionIdentifier: String) -> String? {
        guard actionIdentifier.hasPrefix(actionPrefix) else { return nil }
        let number = String(actionIdentifier.dropFirst(actionPrefix.count))
        return Int(number).map { _ in number }
    }

    @MainActor
    static func reply(choice: String, userInfo: [AnyHashable: Any]) async {
        guard let deviceID = userInfo["deviceId"] as? String,
              let target = userInfo["paneTarget"] as? String,
              let receivedAt = (userInfo["receivedAt"] as? NSNumber)?.int64Value,
              let digest = userInfo["promptDigest"] as? String,
              let server = ServerConfigManager.shared.servers.first(where: { $0.id == deviceID }) else { return }
        let background = UIApplication.shared.beginBackgroundTask()
        defer { UIApplication.shared.endBackgroundTask(background) }
        do {
            try await ReattachAPI(server: server).respondToPermission(
                target: target, receivedAt: receivedAt, digest: digest, choice: choice)
        } catch {
            await notifyFailure(target: target, deviceID: deviceID, error: error)
        }
    }

    private static func notifyFailure(target: String, deviceID: String, error: Error) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Reply not sent · \(target)")
        switch (error as? APIError) {
        case .serverError("changed"):
            content.body = String(localized: "The request changed. Open the pane to review it.")
        case .serverError("no_longer_pending"):
            content.body = String(localized: "This request is no longer pending.")
        default:
            content.body = error.localizedDescription
        }
        content.userInfo = ["deviceId": deviceID, "paneTarget": target]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

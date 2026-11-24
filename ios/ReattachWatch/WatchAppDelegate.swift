import UserNotifications
import WatchConnectivity
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate, WCSessionDelegate, UNUserNotificationCenterDelegate {
    private static let actionPrefix = "choice-"

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(Self.categories)
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Same categories as the iPhone app, so the buttons look identical either way.
    private static var categories: Set<UNNotificationCategory> {
        Set((2...6).map { count in
            UNNotificationCategory(
                identifier: "PERMISSION_\(count)",
                actions: (1...count).map {
                    UNNotificationAction(identifier: actionPrefix + String($0), title: String($0),
                                         options: [.authenticationRequired])
                },
                intentIdentifiers: [])
        })
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        receive(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    private func receive(_ context: [String: Any]) {
        guard let data = context["connections"] as? Data else { return }
        Task { @MainActor in WatchStore.shared.replaceConnections(with: data) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        Task { @MainActor in await WatchStore.shared.refresh() }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let serverID = info["deviceId"] as? String, let target = info["paneTarget"] as? String else { return }
        let receivedAt = (info["receivedAt"] as? NSNumber)?.int64Value
        let action = response.actionIdentifier
        if action.hasPrefix(Self.actionPrefix), let receivedAt, let digest = info["promptDigest"] as? String {
            let choice = String(action.dropFirst(Self.actionPrefix.count))
            do {
                try await WatchStore.shared.respond(serverID: serverID, target: target, receivedAt: receivedAt,
                                                    digest: digest, choice: choice)
                return
            } catch {
                // Fall through and show the request so the user can answer from the app.
            }
        }
        await MainActor.run {
            WatchStore.shared.focus = NotificationFocus(serverID: serverID, target: target, receivedAt: receivedAt)
        }
        await WatchStore.shared.refresh()
    }
}

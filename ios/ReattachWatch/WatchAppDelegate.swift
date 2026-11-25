import UserNotifications
import WatchConnectivity
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate, WCSessionDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
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
        await MainActor.run {
            WatchStore.shared.focus = NotificationFocus(serverID: serverID, target: target, receivedAt: receivedAt)
        }
        await WatchStore.shared.refresh()
    }
}

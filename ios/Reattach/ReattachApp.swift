//
//  ReattachApp.swift
//  Reattach
//

import CryptoKit
import SwiftUI
import UserNotifications

@main
struct ReattachApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { PermissionWidgetRoute.shared.open($0) }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?
    private(set) var deviceToken: String?
    var pendingNavigationTarget: String?
    var unreadPanes: Set<String> = []  // Tracks "deviceId:paneTarget" keys (e.g., "abc123:dev:0.0")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppDelegate.shared = self
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(PermissionNotificationActions.categories)
        setupNotifications()
        return true
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    UIApplication.shared.registerForRemoteNotifications()
                case .notDetermined:
                    self.requestNotificationPermission()
                case .denied:
                    print("Notification permission denied")
                @unknown default:
                    break
                }
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        self.deviceToken = token
        let fingerprint = SHA256.hash(data: deviceToken).prefix(6).map { String(format: "%02x", $0) }.joined()
        print("APNs device token received (fingerprint: \(fingerprint), sandbox: \(PushNotificationEnvironment.currentSandbox))")
        registerDeviceTokenWithServer()
    }

    func registerDeviceTokenWithServer() {
        Task { _ = await synchronizeNotificationPreferences() }
    }

    func synchronizeNotificationPreferences() async -> [String] {
        guard !ServerConfigManager.shared.isDemoMode else { return [] }
        guard let token = deviceToken else { return [String(localized: "Allow notifications in iOS Settings, then reopen Reattach.")] }
        let servers = ServerConfigManager.shared.servers
        return await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for server in servers {
                group.addTask { @MainActor in
                    do {
                        try await ReattachAPI(server: server).registerAPNsDevice(token: token)
                        return nil
                    } catch { return server.serverName }
                }
            }
            var failures: [String] = []
            for await failure in group { if let failure { failures.append(failure) } }
            return failures.sorted()
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Failed to register for remote notifications: \(error)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let deviceId = userInfo["deviceId"] as? String,
           let paneTarget = userInfo["paneTarget"] as? String {
            let key = "\(deviceId):\(paneTarget)"
            unreadPanes.insert(key)
            NotificationCenter.default.post(name: .unreadPanesChanged, object: nil)
        }
        completionHandler([.banner, .badge, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let choice = PermissionNotificationActions.choice(for: response.actionIdentifier) {
            Task { @MainActor in
                await PermissionNotificationActions.reply(choice: choice, userInfo: userInfo)
                completionHandler()
            }
            return
        }
        if let deviceId = userInfo["deviceId"] as? String,
           let paneTarget = userInfo["paneTarget"] as? String {
            let key = "\(deviceId):\(paneTarget)"
            unreadPanes.insert(key)
            pendingNavigationTarget = key
            NotificationCenter.default.post(
                name: .navigateToPane,
                object: nil,
                userInfo: ["deviceId": deviceId, "paneTarget": paneTarget]
            )
        }
        completionHandler()
    }

    func markPaneAsRead(deviceId: String, paneTarget: String) {
        let key = "\(deviceId):\(paneTarget)"
        if unreadPanes.remove(key) != nil {
            NotificationCenter.default.post(name: .unreadPanesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let navigateToPane = Notification.Name("navigateToPane")
    static let unreadPanesChanged = Notification.Name("unreadPanesChanged")
    static let authenticationRestored = Notification.Name("authenticationRestored")
}

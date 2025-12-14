//
//  ReattachApp.swift
//  Reattach
//

import SwiftUI
import UserNotifications

@main
struct ReattachApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?
    private(set) var deviceToken: String?
    var pendingNavigationDirName: String?
    var unreadPanes: Set<String> = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppDelegate.shared = self
        UNUserNotificationCenter.current().delegate = self
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
        print("Device token: \(token)")
        registerDeviceTokenWithServer()
    }

    func registerDeviceTokenWithServer() {
        guard let token = deviceToken else {
            print("No device token available")
            return
        }

        Task {
            do {
                try await ReattachAPI.shared.registerDevice(token: token)
                print("Device registered successfully")
            } catch {
                print("Failed to register device: \(error)")
            }
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
        if let dirName = userInfo["dirName"] as? String {
            unreadPanes.insert(dirName)
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
        if let dirName = userInfo["dirName"] as? String {
            unreadPanes.insert(dirName)
            pendingNavigationDirName = dirName
            NotificationCenter.default.post(
                name: .navigateToPane,
                object: nil,
                userInfo: ["dirName": dirName]
            )
        }
        completionHandler()
    }

    func markPaneAsRead(_ shortPath: String) {
        if unreadPanes.remove(shortPath) != nil {
            NotificationCenter.default.post(name: .unreadPanesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let navigateToPane = Notification.Name("navigateToPane")
    static let unreadPanesChanged = Notification.Name("unreadPanesChanged")
}

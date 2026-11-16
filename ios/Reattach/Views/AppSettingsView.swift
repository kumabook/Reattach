import SwiftUI

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoOpenPermissionInbox") private var autoOpenPermissionInbox = false

    @AppStorage("autoClosePermissionInbox") private var autoClose = true
    @AppStorage(PushNotificationPreference.key) private var notificationMode = PushNotificationPreference.all.rawValue
    @State private var syncing = false
    @State private var failures: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Push notifications"), selection: $notificationMode) {
                        ForEach(PushNotificationPreference.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .accessibilityIdentifier("pushNotificationPreference")
                    if syncing { ProgressView() }
                    if !failures.isEmpty {
                        Text(String(localized: "Notification settings could not be applied to all servers. They will be retried when the app opens."))
                            .foregroundStyle(.orange)
                        Text(failures.joined(separator: ", ")).font(.caption)
                    }
                } header: {
                    Label(String(localized: "Notifications"), systemImage: "bell")
                } footer: {
                    Text("Applies to all servers on this device. Unread indicators and widgets update independently of push notification settings. Servers must run the latest reattachd.")
                }

                Section {
                    Toggle(String(localized: "Open permission requests automatically"), isOn: $autoOpenPermissionInbox)
                        .accessibilityIdentifier("autoOpenPermissionInbox")
                    Toggle(String(localized: "Close when no requests remain"), isOn: $autoClose)
                        .accessibilityIdentifier("autoClosePermissionInbox")
                } header: {
                    Label(String(localized: "Permission Requests"), systemImage: "hand.raised")
                } footer: {
                    Text("Applies to all servers on this device. While using Reattach, new requests open the inbox automatically. Requests you dismiss stay dismissed.")
                }
            }
            .task(id: notificationMode) {
                syncing = true
                let result = await AppDelegate.shared?.synchronizeNotificationPreferences() ?? []
                guard !Task.isCancelled else { return }
                failures = result
                syncing = false
            }
            .navigationTitle(String(localized: "App Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
        }
    }
}

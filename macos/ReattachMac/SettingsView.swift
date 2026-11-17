import SwiftUI
import ServiceManagement
import Carbon

struct SettingsView: View {
    let delegate: AppDelegate
    @State private var selectedTab: String

    init(delegate: AppDelegate, initialTab: String = "general") {
        self.delegate = delegate
        _selectedTab = State(initialValue: initialTab)
    }
    @State private var address = UserDefaults.standard.string(forKey: "serverAddress") ?? "http://127.0.0.1"
    @State private var port = UserDefaults.standard.object(forKey: "serverPort") as? Int ?? 8787
    @State private var token = ""
    @State private var accessClientID = ""
    @State private var accessClientSecret = ""
    @State private var setupToken = ""
    @State private var status = ""
    @State private var busy = false
    @State private var key = UserDefaults.standard.object(forKey: "hotKeyCode") as? Int ?? kVK_Space
    @State private var modifiers = UserDefaults.standard.object(forKey: "hotKeyModifiers") as? Int ?? (controlKey | shiftKey)
    @AppStorage("backgroundTransparency") private var backgroundTransparency = 0.65
    @AppStorage("backgroundBlurStrength") private var backgroundBlurStrength: Double =
        UserDefaults.standard.object(forKey: "backgroundBlurEnabled") as? Bool == false ? 0 : 1
    @AppStorage("requestPresentation") private var requestPresentation = RequestPresentation.current().rawValue
    @AppStorage("hidePanelOnFocusLoss") private var hidePanelOnFocusLoss = false
    @AppStorage("autoClosePermissionPanel") private var autoClosePermissionPanel = false
    @AppStorage("panelWidthFraction") private var panelWidthFraction: Double =
        UserDefaults.standard.object(forKey: "panelSizeFraction") as? Double ?? 0.94
    @AppStorage("panelHeightFraction") private var panelHeightFraction: Double =
        UserDefaults.standard.object(forKey: "panelSizeFraction") as? Double ?? 0.94
    @AppStorage("panelHorizontalPosition") private var panelHorizontalPosition = 0.5
    @AppStorage("panelVerticalPosition") private var panelVerticalPosition = 0.5
    @AppStorage("panelDisplayIdentifier") private var panelDisplayIdentifier = "automatic"
    @State private var availableDisplays: [AppDelegate.DisplayOption] = []
    @AppStorage("confirmationTerminalBundleID") private var confirmationTerminalBundleID = ""
    @State private var availableTerminals: [AppDelegate.TerminalOption] = []
    @AppStorage("localWorkSummariesEnabled") private var localSummariesEnabled = false
    @AppStorage("localWorkSummaryPrompt") private var summaryPrompt = LocalSummaryPrompt.defaultText
    @State private var summaryPromptDraft = ""
    @State private var modelStatus = LocalWorkSummaryEngine.unavailableMessage
    @State private var login = SMAppService.mainApp.status == .enabled

    private var connection: Connection {
        Connection(address: address.trimmingCharacters(in: .whitespacesAndNewlines), port: port, token: token,
                   accessClientID: accessClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                   accessClientSecret: accessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                Form {
                    hotkeySection
                    automaticSection
                    summarySection
                    terminalSection
                    launchSection
                }
                .formStyle(.grouped)
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }.tag("general")

                Form {
                    appearanceSection
                    placementSection
                }
                .formStyle(.grouped)
                .tabItem { Label(String(localized: "Appearance"), systemImage: "display") }.tag("appearance")

                Form {
                    connectionSection
                    registrationSection
                }
                .formStyle(.grouped)
                .tabItem { Label(String(localized: "Connection"), systemImage: "network") }.tag("connection")
            }
            if busy || !status.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    if busy { ProgressView().controlSize(.small) }
                    if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
        .padding(12).frame(width: 550, height: 600)
        .disabled(busy)
        .onAppear {
            loadToken()
            modelStatus = LocalWorkSummaryEngine.unavailableMessage
            summaryPromptDraft = summaryPrompt
            status = delegate.hotKeyError ?? ""
            availableDisplays = delegate.availableDisplays
            availableTerminals = delegate.availableTerminals
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            availableDisplays = delegate.availableDisplays
        }
        .onChange(of: panelDisplayIdentifier) { _, _ in delegate.movePanelToPreferredScreen() }
        .onChange(of: address) { _, _ in loadToken() }
        .onChange(of: port) { _, _ in loadToken() }
    }

    private var summarySection: some View {
        Section {
            Toggle(String(localized: "Summarize work on this Mac"), isOn: $localSummariesEnabled)
                .onChange(of: localSummariesEnabled) { _, _ in modelStatus = LocalWorkSummaryEngine.unavailableMessage }
            Text(String(localized: "Uses Apple Intelligence on this Mac. Terminal output is not sent to a cloud service. Summaries may be inaccurate; use Space to check the original output. Recent output is shown when unavailable."))
                .font(.caption).foregroundStyle(.secondary)
            if let modelStatus {
                Text(modelStatus).font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "Check availability")) { self.modelStatus = LocalWorkSummaryEngine.unavailableMessage }
            }
            DisclosureGroup(String(localized: "Summary prompt")) {
                TextEditor(text: $summaryPromptDraft)
                    .font(.body).frame(height: 150)
                    .accessibilityLabel(String(localized: "Summary prompt"))
                    .onChange(of: summaryPromptDraft) { _, value in
                        if value.count > LocalSummaryPrompt.maximumLength {
                            summaryPromptDraft = String(value.prefix(LocalSummaryPrompt.maximumLength))
                        }
                    }
                Text(String(localized: "Customize the language, length, and focus of summaries. Applying changes regenerates cached summaries. Up to 1,200 characters."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "Restore default prompt")) {
                        summaryPromptDraft = LocalSummaryPrompt.defaultText
                    }
                    Spacer()
                    Button(String(localized: "Apply prompt")) {
                        summaryPrompt = LocalSummaryPrompt.effective(summaryPromptDraft)
                        summaryPromptDraft = summaryPrompt
                    }.disabled(LocalSummaryPrompt.effective(summaryPromptDraft) == summaryPrompt)
                }
            }
        } header: {
            Label(String(localized: "On-device summaries"), systemImage: "sparkles")
        }
    }

    private var hotkeySection: some View {
        Section {
            Text(String(localized: "Work overview")).font(.headline)
            shortcutPickers(key: $key, modifiers: $modifiers)
            Button(String(localized: "Apply Hotkey"), systemImage: "keyboard") {
                UserDefaults.standard.set(key, forKey: "hotKeyCode")
                UserDefaults.standard.set(modifiers, forKey: "hotKeyModifiers")
                delegate.registerHotKey()
                status = delegate.hotKeyError ?? String(localized: "Hotkey updated.")
            }
        } header: {
            Label(String(localized: "Global Hotkey"), systemImage: "keyboard")
        }
    }

    private func shortcutPickers(key: Binding<Int>, modifiers: Binding<Int>) -> some View {
        Group {
            Picker(String(localized: "Modifiers"), selection: modifiers) {
                Text("⌃ ⇧").tag(controlKey | shiftKey)
                Text("⌘ ⇧").tag(cmdKey | shiftKey)
                Text("⌃ ⌥").tag(controlKey | optionKey)
                Text("⌘ ⌥").tag(cmdKey | optionKey)
                Text("⌃ ⌥ ⌘").tag(controlKey | optionKey | cmdKey)
            }
            Picker(String(localized: "Key"), selection: key) {
                Text("A").tag(kVK_ANSI_A); Text("R").tag(kVK_ANSI_R)
                Text("P").tag(kVK_ANSI_P); Text("W").tag(kVK_ANSI_W)
                Text("Space").tag(kVK_Space)
            }
        }
    }

    private var automaticSection: some View {
        Section {
            Picker(String(localized: "When a new request arrives"), selection: $requestPresentation) {
                Text(String(localized: "Do nothing")).tag(RequestPresentation.none.rawValue)
                Text(String(localized: "Show notification")).tag(RequestPresentation.notification.rawValue)
                Text(String(localized: "Show panel automatically")).tag(RequestPresentation.panel.rawValue)
            }
            .onChange(of: requestPresentation) { _, mode in
                delegate.presentationModeChanged()
                if mode == RequestPresentation.notification.rawValue {
                    Task { status = await delegate.requestNotificationPermission() }
                }
            }
            if requestPresentation == RequestPresentation.notification.rawValue {
                Text(String(localized: "Notifications arrive only while Reattach is running. Click a notification to open its request. Enable notifications for Reattach in System Settings if needed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(String(localized: "Close when no requests remain"), isOn: $autoClosePermissionPanel)
            Toggle(String(localized: "Hide panel when focus moves away"), isOn: $hidePanelOnFocusLoss)
            Text(String(localized: "Hides the panel when you switch to another app. Draft replies are kept. Opening Settings or a panel sheet does not hide it."))
                .font(.caption).foregroundStyle(.secondary)
            Text(String(localized: "After you close the panel, it stays closed until a new request arrives. Connection errors do not close it. Automatic display waits while Settings is open."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(String(localized: "Automatic Display"), systemImage: "sparkles.rectangle.stack")
        }
    }

    private var terminalSection: some View {
        Section {
            Picker(String(localized: "Bring to Front"), selection: $confirmationTerminalBundleID) {
                Text(String(localized: "Return to the previous app")).tag("")
                ForEach(availableTerminals) { terminal in
                    Text(terminal.name).tag(terminal.id)
                }
                if !confirmationTerminalBundleID.isEmpty, !availableTerminals.contains(where: { $0.id == confirmationTerminalBundleID }) {
                    Text(String(localized: "Selected app (not found)")).tag(confirmationTerminalBundleID)
                }
            }
            Text(String(localized: "Brings a running terminal to the front. It does not locate a specific terminal window or switch to another tmux session."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(String(localized: "View in tmux"), systemImage: "terminal")
        }
    }

    private var appearanceSection: some View {
        Section {
            HStack {
                Text(String(localized: "Background Transparency"))
                Spacer()
                Text("\(Int(backgroundTransparency * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $backgroundTransparency, in: 0...1, step: 0.05) {
                Text(String(localized: "Background Transparency"))
            } minimumValueLabel: {
                Text(String(localized: "Opaque"))
            } maximumValueLabel: {
                Text(String(localized: "Transparent"))
            }
            HStack {
                Text(String(localized: "Blur Strength"))
                Spacer()
                Text("\(Int((backgroundBlurStrength * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $backgroundBlurStrength, in: 0...1, step: 0.05) {
                Text(String(localized: "Blur Strength"))
            } minimumValueLabel: {
                Text(String(localized: "None"))
            } maximumValueLabel: {
                Text(String(localized: "Strong"))
            }
            Text(String(localized: "Transparency controls the background tint; blur strength controls how much frosted glass is blended in. At 100% transparency and 0% blur, the background is clear. Text and buttons stay opaque. Changes are saved automatically."))
                .font(.caption).foregroundStyle(.secondary)
            Text(String(localized: "The macOS blur material retains a slight tint. When Reduce Transparency is enabled, the background stays opaque."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(String(localized: "Background"), systemImage: "square.on.square")
        }
    }

    private var placementSection: some View {
        Section {
            Picker(String(localized: "Display"), selection: $panelDisplayIdentifier) {
                Text(String(localized: "Automatic (display under the pointer)")).tag("automatic")
                ForEach(availableDisplays) { display in
                    Text(display.name).tag(display.id)
                }
                if panelDisplayIdentifier != "automatic", !availableDisplays.contains(where: { $0.id == panelDisplayIdentifier }) {
                    Text(String(localized: "Selected display (disconnected)")).tag(panelDisplayIdentifier)
                }
            }
            Text(String(localized: "If the selected display is disconnected, the panel uses another display and returns when it reconnects."))
                .font(.caption).foregroundStyle(.secondary)
            percentageControl(String(localized: "Width"), value: $panelWidthFraction, range: 0.01...1, low: String(localized: "Small"), high: String(localized: "Full width"))
            percentageControl(String(localized: "Height"), value: $panelHeightFraction, range: 0.01...1, low: String(localized: "Small"), high: String(localized: "Full height"))
            percentageControl(String(localized: "Horizontal Position"), value: $panelHorizontalPosition, range: 0...1, low: String(localized: "Left"), high: String(localized: "Right"))
            percentageControl(String(localized: "Vertical Position"), value: $panelVerticalPosition, range: 0...1, low: String(localized: "Top"), high: String(localized: "Bottom"))
            HStack {
                Button(String(localized: "Center"), systemImage: "scope") {
                    panelHorizontalPosition = 0.5
                    panelVerticalPosition = 0.5
                    delegate.resizePanel()
                }
                Button(String(localized: "Reset Layout"), systemImage: "arrow.counterclockwise") {
                    panelWidthFraction = 0.94
                    panelHeightFraction = 0.94
                    panelHorizontalPosition = 0.5
                    panelVerticalPosition = 0.5
                    delegate.resizePanel()
                }
            }
            Text(String(localized: "Adjust in 1% steps or enter a value. Position ranges from one edge to the other; 50% is centered. Mouse changes are also saved. Settings apply immediately. A full-size panel cannot be repositioned. A minimum size keeps the content readable."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(String(localized: "Position & Size"), systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    private var connectionSection: some View {
        Section {
            TextField(String(localized: "Address"), text: $address)
            TextField(String(localized: "Port"), value: $port, format: .number.grouping(.never))
            SecureField(String(localized: "Device Token"), text: $token)
            Text(String(localized: "Default: http://127.0.0.1:8787. If the daemon runs with Tailscale, use its HTTPS address."))
                .font(.caption).foregroundStyle(.secondary)
            TextField(String(localized: "Cloudflare Access Client ID"), text: $accessClientID)
            SecureField(String(localized: "Cloudflare Access Client Secret"), text: $accessClientSecret)
            Text(String(localized: "Only needed when the server is protected by a Cloudflare Access service token."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Save & Test Connection"), systemImage: "network") { saveAndTest() }
                Button(String(localized: "Restore Defaults"), systemImage: "arrow.counterclockwise") { address = "http://127.0.0.1"; port = 8787 }
            }
        } header: {
            Label(String(localized: "Server"), systemImage: "server.rack")
        }
    }

    private var registrationSection: some View {
        Section {
            SecureField(String(localized: "Setup Token"), text: $setupToken)
            Text(String(localized: "Run reattachd setup --url <server-url> and enter the setup_token value from the generated URL."))
                .font(.caption).textSelection(.enabled)
            Button(String(localized: "Register & Save"), systemImage: "key") { register() }.disabled(setupToken.isEmpty)
        } header: {
            Label(String(localized: "Register This Mac"), systemImage: "key")
        }
    }

    private var launchSection: some View {
        Section {
            Toggle(String(localized: "Launch at login"), isOn: $login)
                .onChange(of: login) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        if SMAppService.mainApp.status == .requiresApproval {
                            status = String(localized: "Allow Reattach in Login Items in System Settings.")
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    } catch { status = error.localizedDescription }
                    login = SMAppService.mainApp.status == .enabled
                }
        } header: {
            Label(String(localized: "Startup"), systemImage: "power")
        }
    }

    private func percentageControl(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, low: String, high: String) -> some View {
        let editingValue = Binding<Double>(get: { value.wrappedValue }, set: {
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0))
            delegate.resizePanel()
        })
        return VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, value: Binding(
                    get: { (value.wrappedValue * 100).rounded() },
                    set: { editingValue.wrappedValue = $0 / 100 }),
                    format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                    .accessibilityLabel(String(localized: "\(title) (percent)"))
                Text("%")
            }
            Slider(value: editingValue, in: range, step: 0.01) {
                Text(title)
            } minimumValueLabel: {
                Text(low).font(.caption)
            } maximumValueLabel: {
                Text(high).font(.caption)
            }
        }
    }

    private func loadToken() {
        var config = connection
        config.token = ""; config.accessClientID = ""; config.accessClientSecret = ""
        defer { token = config.token; accessClientID = config.accessClientID; accessClientSecret = config.accessClientSecret }
        do { try config.loadCredentials() }
        catch { status = error.localizedDescription }
    }

    private func save(_ config: Connection) throws {
        try config.saveCredentials()
        UserDefaults.standard.set(config.address, forKey: "serverAddress")
        UserDefaults.standard.set(config.port, forKey: "serverPort")
        delegate.store.reloadConnection()
    }

    private func saveAndTest() {
        let config = connection
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try save(config)
                let entries = try await config.entries()
                status = String(localized: "Connected. Pending requests: \(entries.count)")
                await delegate.store.poll()
            } catch { status = error.localizedDescription }
        }
    }

    private func register() {
        var config = connection
        let setup = setupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                struct Registration: Decodable { let device_token: String }
                let data = try await config.request(["register"], method: "POST", body: ["setup_token": setup, "device_name": "Reattach Mac"])
                config.token = try JSONDecoder().decode(Registration.self, from: data).device_token
                token = config.token
                try save(config)
                setupToken = ""
                status = String(localized: "Registration complete.")
                await delegate.store.poll()
            } catch { status = error.localizedDescription }
        }
    }
}

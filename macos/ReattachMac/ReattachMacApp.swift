import SwiftUI
import AppKit
import Carbon
import UserNotifications

private enum StatusBarIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 1.75, width: 22.5, height: 14.5),
                                     xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5
            frame.stroke()

            let prompt = NSBezierPath()
            prompt.lineWidth = 1.6
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.move(to: NSPoint(x: 4, y: 11.5))
            prompt.line(to: NSPoint(x: 7.2, y: 9))
            prompt.line(to: NSPoint(x: 4, y: 6.5))
            prompt.move(to: NSPoint(x: 8.8, y: 6.5))
            prompt.line(to: NSPoint(x: 11.7, y: 6.5))
            prompt.stroke()

            let phone = NSBezierPath(roundedRect: NSRect(x: 15, y: 5, width: 5, height: 8.5),
                                     xRadius: 1.1, yRadius: 1.1)
            phone.lineWidth = 1.2
            phone.stroke()
            let homeIndicator = NSBezierPath()
            homeIndicator.lineWidth = 1
            homeIndicator.lineCapStyle = .round
            homeIndicator.move(to: NSPoint(x: 16.7, y: 6.7))
            homeIndicator.line(to: NSPoint(x: 18.3, y: 6.7))
            homeIndicator.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Reattach"
        return image
    }
}

@main
struct ReattachMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(String(localized: "Settings…")) { delegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

// Borderless panels need to opt in to keyboard focus for navigation and replies.
final class PermissionPanel: NSPanel, PanelDragNotifying {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var drag: (CGFloat) -> Void = { _ in }
    var endDrag: (CGFloat, Bool) -> Void = { _, _ in }
    var paging = TrackpadPaging()
    var didFinishDragging: () -> Void = {}
    var cycleWork: (Bool) -> Bool = { _ in false }

    override func sendEvent(_ event: NSEvent) {
        // Tab navigation can be consumed by AppKit before SwiftUI's onKeyPress.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Tab),
           modifiers == .control || modifiers == [.control, .shift],
           attachedSheet == nil, cycleWork(modifiers.contains(.shift)) {
            return
        }
        if event.type == .scrollWheel, event.hasPreciseScrollingDeltas,
           attachedSheet == nil, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            if event.phase.contains(.cancelled) {
                endDrag(0, true)
                paging = TrackpadPaging()
            } else {
                let result = paging.update(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                           began: event.phase.contains(.began),
                                           momentum: !event.momentumPhase.isEmpty)
                if result.handled {
                    if event.momentumPhase.isEmpty {
                        if event.phase.contains(.ended) { endDrag(result.translation, false) }
                        else { drag(result.translation) }
                    }
                    return
                }
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let store = InboxStore()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var settings: NSWindow?
    private var welcomeWindow: NSPanel?
    private var workWindow: NSWindow?
    private let workStore = WorkOverviewStore()
    private var previousApp: NSRunningApplication?
    private var polling: Task<Void, Never>?
    private var visibilityAnimation: Task<Void, Never>?
    private var wantsPanelVisible = false
    private var focusLossCheck: Task<Void, Never>?
    private var presentationPolicy = InboxPresentationPolicy()
    private var notificationPolicy = InboxNotificationPolicy(defaults: .standard)
    private let notificationCenter = UNUserNotificationCenter.current()
    private var deliveredRequests: [String: PermissionAttention] = [:]
    private var notificationServer = ""
    private var hotKey: EventHotKeyRef?
    private var workHotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var screenObserver: NSObjectProtocol?
    var hotKeyError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The native Mac app uses local notifications. Retire any APNs
        // registration inherited from the iOS app running on this Mac.
        NSApp.unregisterForRemoteNotifications()
        notificationCenter.delegate = self

        configureStatusItem()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x52415454 else { return OSStatus(eventNotHandledErr) }
            let action = identifier.id
            Task { @MainActor in
                if action == 1 { delegate.toggle(fromHotkey: true) }
                else if action == 2 {
                    if delegate.workWindow?.isVisible == true { delegate.closeWork() }
                    else { delegate.showWork() }
                }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        registerHotKey()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.movePanelToPreferredScreen() }
        }
        polling = Task {
            await restoreDeliveredNotifications()
            while !Task.isCancelled {
                await store.poll()
                if store.hasConnected { store.welcome.connectionSucceeded() }
                updateStatusItem()
                if store.error == nil { store.refreshWorkTitlesIfNeeded() }
                await updateRequestNotifications()
                if panel?.isVisible != true, RequestPresentation.current() == .panel, !store.entries.isEmpty {
                    await store.prepareAutomaticPresentation()
                }
                updateAutomaticPresentation()
                if panel?.isVisible == true, !store.sent.contains(store.selected ?? ""), !store.requiresReload.contains(store.selected ?? "") {
                    await store.refresh(background: true)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = StatusBarIcon.makeImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = String(localized: "Click to show or hide Reattach. Right-click for Settings and Quit.")
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.button?.title = store.error == nil ? " \(store.entries.count)" : " !"
        statusItem?.button?.setAccessibilityLabel(store.error == nil
            ? String(localized: "Reattach: Pending requests: \(store.entries.count)") : String(localized: "Reattach: Connection error"))
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettingsFromStatusMenu), keyEquivalent: ",")
            settingsItem.target = self
            let workItem = NSMenuItem(title: String(localized: "All Work"), action: #selector(openWorkFromStatusMenu), keyEquivalent: "")
            workItem.target = self
            menu.addItem(workItem)
            menu.addItem(settingsItem)
            menu.addItem(.separator())
            let quitItem = NSMenuItem(title: String(localized: "Quit Reattach"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quitItem.target = NSApp
            menu.addItem(quitItem)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else {
            toggle()
        }
    }

    @objc private func openWorkFromStatusMenu() { showWork() }

    @objc private func openSettingsFromStatusMenu() { showSettings() }

    private func updateAutomaticPresentation() {
        let defaults = UserDefaults.standard
        let action = presentationPolicy.update(
            entries: store.entries,
            server: (try? store.connection.baseURL.absoluteString) ?? "",
            succeeded: store.error == nil,
            visible: panel?.isVisible == true,
            blocked: (panel?.isVisible != true && !store.entries.isEmpty && !store.readyForAutomaticPresentation) || workWindow?.isVisible == true || store.welcome.active || store.isShowingReplyFeedback || visibilityAnimation != nil || store.busy || store.isSwiping || settings?.isVisible == true || panel?.attachedSheet != nil,
            autoShow: RequestPresentation.current(defaults) == .panel,
            autoClose: defaults.bool(forKey: "autoClosePermissionPanel"))
        switch action {
        case .none: break
        case .show: toggle()
        case .close:
            let restoreFocus = panel?.isKeyWindow == true
            closePanel(restoreFocus: restoreFocus)
        }
    }

    func requestNotificationPermission() async -> String {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            return granted ? "" : String(localized: "Notifications are disabled. Allow Reattach notifications in System Settings.")
        } catch { return error.localizedDescription }
    }

    func presentationModeChanged() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: Array(deliveredRequests.keys))
        notificationCenter.removeDeliveredNotifications(withIdentifiers: Array(deliveredRequests.keys))
        deliveredRequests.removeAll()
    }

    private func restoreDeliveredNotifications() async {
        let notifications = await notificationCenter.deliveredNotifications()
        notificationServer = (try? store.connection.baseURL.absoluteString) ?? ""
        for notification in notifications where notification.request.identifier.hasPrefix("permission-") {
            let info = notification.request.content.userInfo
            guard RequestPresentation.current() == .notification,
                  info["server"] as? String == notificationServer,
                  let target = info["target"] as? String,
                  let tool = info["tool"] as? String,
                  let receivedAt = (info["receivedAt"] as? NSNumber)?.int64Value else {
                notificationCenter.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
                continue
            }
            deliveredRequests[notification.request.identifier] = PermissionAttention(target: target, tool: tool, receivedAt: receivedAt)
        }
    }

    private func updateRequestNotifications() async {
        let server = (try? store.connection.baseURL.absoluteString) ?? ""
        let fresh = notificationPolicy.update(entries: store.entries, server: server, succeeded: store.error == nil)
        guard store.error == nil else { return }
        let obsolete = deliveredRequests.filter { notificationServer != server || !store.entries.contains($0.value) }.map(\.key)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: obsolete)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: obsolete)
        for id in obsolete { deliveredRequests[id] = nil }
        notificationServer = server
        guard RequestPresentation.current() == .notification else { return }
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for entry in fresh {
            guard RequestPresentation.current() == .notification,
                  server == (try? store.connection.baseURL.absoluteString), store.entries.contains(entry) else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Permission Required")
            content.body = String(localized: "Open Reattach to review the pending request.")
            content.sound = .default
            content.userInfo = ["server": server, "target": entry.target, "receivedAt": entry.receivedAt, "tool": entry.tool]
            let id = "permission-" + UUID().uuidString
            do {
                try await notificationCenter.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                if RequestPresentation.current() == .notification,
                   server == (try? store.connection.baseURL.absoluteString), store.entries.contains(entry) {
                    deliveredRequests[id] = entry
                } else {
                    notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
                    notificationCenter.removeDeliveredNotifications(withIdentifiers: [id])
                }
            } catch { store.responseMessage = String(localized: "Could not show notification: \(error.localizedDescription)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            completionHandler(RequestPresentation.current() == .notification ? [.banner, .sound, .list] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let server = info["server"] as? String
        let target = info["target"] as? String
        let receivedAt = (info["receivedAt"] as? NSNumber)?.int64Value
        let tool = info["tool"] as? String
        let isOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard isOpen, server == (try? store.connection.baseURL.absoluteString) else { return }
            await store.poll()
            guard server == (try? store.connection.baseURL.absoluteString) else { return }
            if let entry = store.entries.first(where: { $0.target == target && $0.receivedAt == receivedAt && $0.tool == tool }) {
                store.cancelSwipe()
                store.selected = entry.target
            }
            if !wantsPanelVisible { toggle() }
            else { NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil) }
            await store.refresh()
        }
    }

    var hotkeyDisplay: String {
        let defaults = UserDefaults.standard
        let modifiers = defaults.object(forKey: "hotKeyModifiers") as? Int ?? (controlKey | shiftKey)
        let key = defaults.object(forKey: "hotKeyCode") as? Int ?? kVK_Space
        let prefix = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map { $0.1 }.joined()
        let name = [kVK_ANSI_A: "A", kVK_ANSI_R: "R", kVK_ANSI_P: "P", kVK_ANSI_W: "W", kVK_Space: "Space"][key] ?? ""
        return prefix + name
    }

    func registerHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let workHotKey { UnregisterEventHotKey(workHotKey) }
        workHotKey = nil
        let defaults = UserDefaults.standard
        let key = UInt32(defaults.object(forKey: "hotKeyCode") as? Int ?? kVK_Space)
        let modifiers = UInt32(defaults.object(forKey: "hotKeyModifiers") as? Int ?? (controlKey | shiftKey))
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x52415454, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        hotKeyError = status == noErr ? nil : String(localized: "Could not register the hotkey (\(status)). Choose a different combination.")

    }

    func toggle(fromHotkey: Bool = false) {
        store.welcome.panelWillToggle(visible: wantsPanelVisible, fromHotkey: fromHotkey)
        if wantsPanelVisible, panel?.isVisible == true {
            closePanel(restoreFocus: !store.welcome.active)
            if store.welcome.active { welcomeWindow?.makeKeyAndOrderFront(nil) }
            return
        }
        let wasVisible = panel?.isVisible == true
        if !wasVisible, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        let screen = preferredScreen()
        let panelFrame = fittedPanelFrame(on: screen)
        if panel == nil {
            let window = PermissionPanel(contentRect: panelFrame,
                                 styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.drag = { [weak self] translation in
                guard let self, self.store.showingUnifiedRequest, !self.store.welcome.active, !self.store.isShowingReplyFeedback else { return }
                self.store.updateSwipe(translation)
            }
            window.endDrag = { [weak self] translation, cancelled in self?.store.finishSwipe(translation, cancelled: cancelled) }
            window.didFinishDragging = { [weak self] in self?.saveManualPanelLayout() }
            window.cycleWork = { [weak self] backwards in
                guard let self, !self.store.showingUnifiedRequest, !self.store.welcome.active else { return false }
                NotificationCenter.default.post(name: WorkCycleSelection.notification, object: self.panel,
                                                userInfo: ["backwards": backwards])
                return true
            }
            window.title = "Reattach"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.animationBehavior = .none
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.minSize = NSSize(width: 780, height: 520)
            window.delegate = self
            panel = window
        }
        if !wasVisible {
            workStore.prepareToOpen(connection: store.connection)
            let hostingView = NSHostingView(rootView: UnifiedWorkPanel(model: workStore, inbox: store,
                close: { [weak self] in self?.closePanel() },
                settings: { [weak self] in self?.showSettings() },
                welcome: { [weak self] in self?.showWelcome(restart: true) },
                confirmInTerminal: { [weak self] in await self?.confirmInTerminal() },
                openPane: { [weak self] target in await self?.openWorkPane(target) ?? false }))
            hostingView.sizingOptions = []
            panel?.contentView = hostingView
        }
        // Fit the panel to the selected display on every invocation.
        (panel as? PermissionPanel)?.paging = TrackpadPaging()
        if !wasVisible {
            panel?.setFrame(panelFrame, display: true)
            panel?.alphaValue = 0
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        animatePanelVisibility(show: true)
        if store.welcome.active || !UserDefaults.standard.bool(forKey: "hasCompletedMacWelcome") {
            showWelcome()
        }
        Task { await store.poll(); if !store.sent.contains(store.selected ?? ""), !store.requiresReload.contains(store.selected ?? "") { await store.refresh() } }
    }

    struct DisplayOption: Identifiable {
        let id: String
        let name: String
    }

    private func displayIdentifier(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var availableDisplays: [DisplayOption] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = displayIdentifier(screen) else { return nil }
            return DisplayOption(id: id, name: "\(index + 1): \(screen.localizedName)（\(Int(screen.frame.width)) × \(Int(screen.frame.height))）")
        }
    }

    private func preferredScreen(keepCurrentForAutomatic: Bool = false) -> NSScreen? {
        let selected = UserDefaults.standard.string(forKey: "panelDisplayIdentifier") ?? "automatic"
        if selected != "automatic", let fixed = NSScreen.screens.first(where: { displayIdentifier($0) == selected }) {
            return fixed
        }
        if selected == "automatic", keepCurrentForAutomatic,
           let current = panel?.screen, NSScreen.screens.contains(current) { return current }
        return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func movePanelToPreferredScreen() {
        panel?.setFrame(fittedPanelFrame(on: preferredScreen()), display: true)
    }

    private func fittedPanelFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        return PanelLayout().frame(in: visible)
    }

    func resizePanel() {
        panel?.setFrame(fittedPanelFrame(on: preferredScreen(keepCurrentForAutomatic: true)), display: true)
    }

    private func saveManualPanelLayout() {
        guard let panel, let screen = panel.screen else { return }
        PanelLayout(frame: panel.frame, in: screen.visibleFrame).save()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        saveManualPanelLayout()
    }

    struct TerminalOption: Identifiable {
        let id: String
        let name: String
    }

    var availableTerminals: [TerminalOption] {
        [("com.mitchellh.ghostty", "Ghostty"), ("com.googlecode.iterm2", "iTerm2"), ("com.apple.Terminal", "Terminal")]
            .compactMap { id, name in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil ? nil : TerminalOption(id: id, name: name)
            }
    }

    func confirmInTerminal() async {
        let bundleID = UserDefaults.standard.string(forKey: "confirmationTerminalBundleID") ?? ""
        let terminal: NSRunningApplication?
        if bundleID.isEmpty {
            terminal = nil
        } else {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                let name = availableTerminals.first { $0.id == bundleID }?.name ?? String(localized: "the selected terminal")
                store.responseMessage = String(localized: "Open \(name) and connect to tmux, then choose “View in tmux” again.")
                return
            }
            terminal = running
        }
        guard await store.selectPane() else { return }
        if let terminal {
            guard terminal.activate(options: []) else {
                store.responseMessage = String(localized: "The pane was selected, but the terminal could not be brought to the front.")
                return
            }
            closePanel(restoreFocus: false)
        } else {
            closePanel()
        }
    }

    func closePanel(restoreFocus: Bool = true) {
        // A manual open/close may happen between polling ticks. Remember the
        // requests the user just dismissed before the next automatic check.
        _ = presentationPolicy.update(entries: store.entries,
            server: (try? store.connection.baseURL.absoluteString) ?? "",
            succeeded: true, visible: false, blocked: false, autoShow: false, autoClose: false)
        store.cancelSwipe()
        animatePanelVisibility(show: false, restoreFocus: restoreFocus)
    }

    private func animatePanelVisibility(show: Bool, restoreFocus: Bool = false) {
        visibilityAnimation?.cancel()
        wantsPanelVisible = show
        guard let panel else { visibilityAnimation = nil; return }
        let startAlpha = panel.alphaValue
        let targetAlpha: CGFloat = show ? 1 : 0
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (show ? 0.20 : 0.15)
        visibilityAnimation = Task { @MainActor [weak self, weak panel] in
            guard let self, let panel else { return }
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let progress = duration == 0 ? 1 : min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                let eased = progress * progress * (3 - 2 * progress)
                panel.alphaValue = startAlpha + (targetAlpha - startAlpha) * eased
                if progress >= 1 { break }
                do { try await Task.sleep(for: .milliseconds(8)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            self.visibilityAnimation = nil
            if !show {
                panel.orderOut(nil)
                panel.contentView = nil
                self.workStore.visibleTargets.removeAll()
                self.workStore.viewingTarget = nil
                // Do not steal focus if the user moved to Settings or another app during the fade.
                if restoreFocus, self.settings?.isKeyWindow != true,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                   let previous = self.previousApp, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    previous.activate(options: [])
                }
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        focusLossCheck?.cancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        scheduleFocusLossCheck()
    }

    func applicationDidResignActive(_ notification: Notification) {
        scheduleFocusLossCheck()
    }

    private func scheduleFocusLossCheck() {
        focusLossCheck?.cancel()
        focusLossCheck = Task { @MainActor [weak self] in
            // Let AppKit finish transferring focus to Settings, a sheet or popover.
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self, !self.store.welcome.active, UserDefaults.standard.bool(forKey: "hidePanelOnFocusLoss"),
                  self.wantsPanelVisible, let panel = self.panel, panel.isVisible,
                  (!NSApp.isActive || !panel.isKeyWindow), self.settings?.isVisible != true,
                  panel.attachedSheet == nil else { return }
            if NSApp.isActive, let keyWindow = NSApp.keyWindow, keyWindow !== panel { return }
            self.closePanel(restoreFocus: false)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === workWindow { closeWork(); return false }
        if sender === welcomeWindow { finishWelcome(); return false }
        if sender === panel { closePanel(); return false }
        return true
    }

    func showWork() {
        if panel?.isVisible != true { toggle() }
        else { panel?.makeKeyAndOrderFront(nil) }
    }

    private func closeWork(restoreFocus: Bool = true) {
        let shouldRestore = restoreFocus && workWindow?.isVisible == true && settings?.isKeyWindow != true
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        workWindow?.contentView = nil
        workWindow?.orderOut(nil)
        workStore.visibleTargets.removeAll()
        if shouldRestore, let previousApp,
           previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
    }

    private func openWorkPane(_ target: String) async -> Bool {
        let api = store.connection
        let bundleID = UserDefaults.standard.string(forKey: "confirmationTerminalBundleID") ?? ""
        let terminal = bundleID.isEmpty ? previousApp : NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        guard let terminal, terminal.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        do {
            let data = try await api.request(["sessions"])
            let sessions = try JSONDecoder().decode([Session].self, from: data)
            guard sessions.flatMap(\.windows).flatMap(\.panes).contains(where: { $0.target == target }),
                  api.address == store.connection.address, api.port == store.connection.port,
                  api.token == store.connection.token else { return false }
            _ = try await api.request(["panes", target, "select"], method: "POST")
            let activated = terminal.activate(options: [])
            if activated {
                workStore.observations[target]?.unread = false
                closePanel(restoreFocus: false)
            }
            return activated
        } catch { return false }
    }

    private func showWelcome(restart: Bool = false) {
        if restart || !store.welcome.active {
            store.welcome.start(connected: store.hasConnected && store.error == nil)
            welcomeWindow?.orderOut(nil)
            welcomeWindow = nil
        }
        if welcomeWindow == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = String(localized: "A quick introduction")
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView: MacWelcomeView(practice: store.welcome, hotkey: hotkeyDisplay,
                connectionSettings: { [weak self] in self?.showSettings(connectionSetup: true) },
                finish: { [weak self] in self?.finishWelcome() }))
            window.center()
            welcomeWindow = window
        }
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    private func finishWelcome() {
        store.welcome.finish()
        UserDefaults.standard.set(true, forKey: "hasCompletedMacWelcome")
        welcomeWindow?.orderOut(nil)
        if !wantsPanelVisible { toggle() }
        else { panel?.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settings, store.welcome.active {
            welcomeWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let link = urls.lazy.compactMap({ SetupLink($0.absoluteString) }).first else { return }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = String(localized: "Connect to this server?")
        confirm.informativeText = "\(link.address):\(link.port)"
        confirm.addButton(withTitle: String(localized: "Connect"))
        confirm.addButton(withTitle: String(localized: "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            let result = NSAlert()
            do {
                let connection = try await Connection(address: link.address, port: link.port, token: "")
                    .registering(setupToken: link.token)
                try connection.saveAsCurrent()
                store.reloadConnection()
                await store.poll()
                result.messageText = String(localized: "Reattach for Mac is connected.")
            } catch {
                result.alertStyle = .warning
                result.messageText = String(localized: "Could not connect.")
                result.informativeText = error.localizedDescription
            }
            result.runModal()
        }
    }

    func showSettings(connectionSetup: Bool = false) {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = String(localized: "Reattach Settings")
            window.delegate = self
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(delegate: self, initialTab: connectionSetup ? "connection" : "general"))
            window.center()
            settings = window
        }
        if connectionSetup {
            settings?.contentView = NSHostingView(rootView: SettingsView(delegate: self, initialTab: "connection"))
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

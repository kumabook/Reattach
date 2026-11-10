//
//  SessionListView.swift
//  Reattach
//

import SwiftUI
import Observation

// MARK: - PaneIcon

enum PaneIcon {
    static func iconName(for windowName: String, path: String = "") -> String {
        let name = windowName.lowercased()
        let pathLower = path.lowercased()

        if name.contains("docker") || name.contains("container") {
            return "shippingbox.fill"
        }
        if name.contains("claude") || pathLower.contains("claude") {
            return "sparkles"
        }
        if name.contains("vim") || name.contains("nvim") || name.contains("neovim") {
            return "doc.text.fill"
        }
        if name.contains("git") {
            return "arrow.triangle.branch"
        }
        if name.contains("node") || name.contains("npm") || name.contains("yarn") || name.contains("pnpm") {
            return "cube.fill"
        }
        if name.contains("python") || name.contains("pip") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("cargo") || name.contains("rust") {
            return "gearshape.fill"
        }
        if name.contains("ssh") {
            return "network"
        }
        if name.contains("htop") || name.contains("top") || name.contains("btop") {
            return "chart.bar.fill"
        }
        if name.contains("man") {
            return "book.fill"
        }
        if name.contains("make") || name.contains("build") {
            return "hammer.fill"
        }
        if name.contains("test") {
            return "checkmark.circle.fill"
        }

        return "terminal"
    }

    static func iconColor(for windowName: String, isActive: Bool) -> Color {
        let name = windowName.lowercased()

        if !isActive {
            return .secondary
        }

        if name.contains("docker") {
            return .blue
        }
        if name.contains("claude") {
            return .orange
        }
        if name.contains("vim") || name.contains("nvim") {
            return .green
        }
        if name.contains("git") {
            return .orange
        }
        if name.contains("node") || name.contains("npm") {
            return .green
        }
        if name.contains("python") {
            return .yellow
        }
        if name.contains("cargo") || name.contains("rust") {
            return .orange
        }
        if name.contains("ssh") {
            return .purple
        }

        return .blue
    }
}

// MARK: - SessionListView

struct SessionListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionStatus = PermissionStatus.shared
    @State private var viewModel = SessionListViewModel()
    @State private var showingCreateSheet = false
    @State private var isCreatingWindow = false
    @State private var showingWindowDestinations = false
    @State private var selectedPane: PaneNavigationItem?
    @State private var detailIdentity = UUID()
    @State private var pendingNavigationID: UUID?
    private let paneSelectionStore = PaneSelectionStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var unreadPaneKeys: Set<String> = []

    private var unreadPanes: Set<String> {
        guard let deviceId = ServerConfigManager.shared.activeServer?.deviceId else {
            return []
        }
        let prefix = "\(deviceId):"
        return Set(unreadPaneKeys.compactMap { key in
            key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        })
    }
    @State private var showPermissionInbox = false
    @State private var showServerList = false
    @State private var showServerSettings = false
    @State private var configManager = ServerConfigManager.shared
    @State private var paneToDelete: Pane?

    var body: some View {
        adaptiveLayout
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button(String(localized: "New Session"), systemImage: "plus.rectangle.on.folder") {
                    showingCreateSheet = true
                }
                .disabled(ReattachAPI.shared.isDemoMode)
                Button(String(localized: "Next Pane"), systemImage: "arrow.right") {
                    cyclePane(backward: false)
                }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: .control)
                Button(String(localized: "Previous Pane"), systemImage: "arrow.left") {
                    cyclePane(backward: true)
                }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: [.control, .shift])
                Button(String(localized: "Toggle Sidebar"), systemImage: "sidebar.left") {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateSessionView { name, cwd in
                selectedPane = try await viewModel.createSession(name: name, cwd: cwd)
            }
        }
        .fullScreenCover(isPresented: $showPermissionInbox) {
            PermissionInboxView(sessions: viewModel.sessions) { target in
                showPermissionInbox = false
                Task {
                    let serverID = configManager.activeServer?.id
                    await viewModel.loadSessions()
                    guard configManager.activeServer?.id == serverID else { return }
                    navigateToPaneWithTarget(target)
                }
            }
        }
        .sheet(isPresented: $showServerList) {
            ServerListView()
        }
        .sheet(isPresented: $showServerSettings) {
            if let server = configManager.activeServer {
                NavigationStack {
                    ServerDetailView(server: server)
                }
            }
        }
        .alert(String(localized: "Error"), isPresented: $viewModel.showError) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .task {
            await loadAndRestorePane()
            unreadPaneKeys = AppDelegate.shared?.unreadPanes ?? []
        }
        .task(id: "\(configManager.activeServer?.id ?? "none")|\(scenePhase == .active)|\(configManager.isDemoMode)") {
            guard scenePhase == .active else { return }
            let serverID = configManager.activeServer?.id
            permissionStatus.reset(serverID: serverID)
            while !Task.isCancelled {
                if scenePhase == .active, !configManager.isDemoMode || PermissionStatus.usesUITestFixture {
                    do {
                        let entries = try await ReattachAPI.shared.permissionAttention()
                        guard !Task.isCancelled else { return }
                        permissionStatus.update(entries, serverID: serverID)
                    } catch {
                        guard !Task.isCancelled else { return }
                        permissionStatus.update([], serverID: serverID)
                    }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .task(id: "list|\(configManager.activeServer?.id ?? "none")|\(scenePhase == .active)|\(configManager.isDemoMode)") {
            guard scenePhase == .active, !configManager.isDemoMode else { return }
            await viewModel.observeSessionChanges()
        }
        .onChange(of: PaneNavigationItem.items(in: viewModel.sessions)) { _, _ in
            guard viewModel.loadedServerID == configManager.activeServer?.id,
                  let selected = selectedPane else { return }
            if let current = PaneNavigationItem.reconciling(target: selected.pane.target, in: viewModel.sessions) {
                if current != selected { selectedPane = current }
            } else {
                selectedPane = nil
                detailIdentity = UUID()
                if let serverID = configManager.activeServer?.id {
                    paneSelectionStore.save(nil, for: serverID)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPane)) { notification in
            guard let deviceId = notification.userInfo?["deviceId"] as? String,
                  let paneTarget = notification.userInfo?["paneTarget"] as? String else { return }
            navigateToPaneWithKey("\(deviceId):\(paneTarget)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .unreadPanesChanged)) { _ in
            unreadPaneKeys = AppDelegate.shared?.unreadPanes ?? []
        }
        .onReceive(NotificationCenter.default.publisher(for: .authenticationRestored)) { _ in
            Task {
                await loadAndRestorePane()
            }
        }
        .onChange(of: configManager.activeServer?.id) { _, _ in
            selectedPane = nil
            detailIdentity = UUID()
            Task { await loadAndRestorePane() }
        }
        .onChange(of: selectedPane?.pane.target) { _, target in
            guard let target, !configManager.isDemoMode,
                  let serverID = configManager.activeServer?.id,
                  viewModel.loadedServerID == serverID else { return }
            paneSelectionStore.save(target, for: serverID)
        }
    }

    private var permissionMenu: some View {
        Button {
            showPermissionInbox = true
        } label: {
            Label(String(localized: "Pending Requests"), systemImage: "checkmark")
        }
        .badge(permissionStatus.entries.count)
        .tint(permissionStatus.entries.isEmpty ? .secondary : .orange)
        .accessibilityLabel(String(localized: "\(permissionStatus.entries.count) pending requests"))
        .accessibilityIdentifier("permissionWaitingMenu")
    }

    // Keep one navigation hierarchy as the display opens, closes, or resizes.
    private var adaptiveLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            listContent
                .navigationTitle(currentServerName)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        serverListButton
                    }
                    ToolbarItem(placement: .primaryAction) {
                        settingsButton
                    }
                    ToolbarItem(placement: .topBarTrailing) { permissionMenu }
                }
        } detail: {
            if let selected = selectedPane {
                PaneDetailView(pane: selected.pane, windowName: selected.windowName, onSelectPane: { pane in
                    selectedPane = PaneNavigationItem(pane: pane, windowName: selected.windowName)
                }) { state in
                    guard state.target != selectedPane?.pane.target else { return }
                    let identity = detailIdentity
                    let previousSelection = selectedPane?.pane.target
                    Task {
                        await viewModel.loadSessions()
                        guard detailIdentity == identity,
                              selectedPane?.pane.target == previousSelection else { return }
                        for session in viewModel.sessions {
                            for window in session.windows {
                                if let pane = window.panes.first(where: { $0.target == state.target }) {
                                    selectedPane = PaneNavigationItem(pane: pane, windowName: window.name)
                                    return
                                }
                            }
                        }
                    }
                }
                    .id(detailIdentity)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { permissionMenu }
                    }
                    .onAppear {
                        if let deviceId = ServerConfigManager.shared.activeServer?.deviceId {
                            AppDelegate.shared?.markPaneAsRead(deviceId: deviceId, paneTarget: selected.pane.target)
                        }
                    }
            } else {
                ContentUnavailableView(
                    String(localized: "Select a Pane"),
                    systemImage: "terminal",
                    description: Text(String(localized: "Choose a pane from the sidebar"))
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { permissionMenu }
                }
            }
        }
    }

    private func cyclePane(backward: Bool) {
        selectedPane = PaneNavigationItem.adjacent(
            to: selectedPane,
            in: viewModel.sessions,
            backward: backward
        )
    }

    @ViewBuilder
    private var listContent: some View {
        if viewModel.isLoading && viewModel.sessions.isEmpty {
            ProgressView(String(localized: "Loading sessions..."))
        } else {
            List(selection: $selectedPane) {
                if viewModel.sessions.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Sessions"),
                        systemImage: "terminal",
                        description: Text(String(localized: "Create a new session to get started"))
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if !viewModel.sessions.isEmpty && ReattachAPI.shared.isDemoMode {
                    Section {
                        HStack {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Demo Mode"))
                                    .font(.headline)
                                Text(String(localized: "Showing sample data. Set up a server to connect."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                ForEach(viewModel.sessions) { session in
                    SessionSection(
                        session: session,
                        unreadPanes: unreadPanes,
                        onRequestDelete: { pane in
                            paneToDelete = pane
                        },
                        onDeletePane: { target in
                            await viewModel.deletePane(target: target)
                        }
                    )
                }
                Section {
                    if viewModel.sessions.isEmpty {
                        Button(String(localized: "New Session"), systemImage: "plus.circle") { showingCreateSheet = true }
                            .disabled(ReattachAPI.shared.isDemoMode)
                    } else {
                        Button {
                            if let selected = selectedPane {
                                createWindow(target: selected.pane.target)
                            } else {
                                showingWindowDestinations = true
                            }
                        } label: {
                            Label(String(localized: "New Window"), systemImage: "plus.circle")
                        }
                        .confirmationDialog(String(localized: "New Window"), isPresented: $showingWindowDestinations, titleVisibility: .visible) {
                            ForEach(viewModel.sessions) { session in
                                if let pane = session.windows.first(where: { $0.active })?.panes.first
                                    ?? session.windows.first?.panes.first {
                                    Button(session.name) { createWindow(target: pane.target) }
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("newWindow")
                        .disabled(isCreatingWindow || (ReattachAPI.shared.isDemoMode && !ReattachAPI.usesWindowCreationUITestFixture))
                    }
                }
            }
            .listStyle(.sidebar)
            .refreshable {
                await loadAndRestorePane()
            }
            .confirmationDialog(
                String(localized: "Delete Pane"),
                isPresented: Binding(
                    get: { paneToDelete != nil },
                    set: { if !$0 { paneToDelete = nil } }
                ),
                presenting: paneToDelete
            ) { pane in
                Button(String(localized: "Delete"), role: .destructive) {
                    Task {
                        await viewModel.deletePane(target: pane.target)
                        paneToDelete = nil
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    paneToDelete = nil
                }
            } message: { pane in
                Text(String(localized: "Are you sure you want to delete this pane?\n\(pane.shortPath)"))
            }
        }
    }

    private func createWindow(target: String) {
        guard !isCreatingWindow else { return }
        isCreatingWindow = true
        Task {
            defer { isCreatingWindow = false }
            do {
                selectedPane = try await viewModel.createWindow(target: target)
            } catch {
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
    }

    private func loadAndRestorePane() async {
        let serverID = configManager.activeServer?.id
        guard await viewModel.loadSessions(), !Task.isCancelled,
              configManager.activeServer?.id == serverID else { return }
        handlePendingNavigation()
        guard !configManager.isDemoMode, pendingNavigationID == nil,
              selectedPane == nil, let serverID,
              let target = paneSelectionStore.target(for: serverID) else { return }
        if let item = PaneNavigationItem.restoring(target: target, in: viewModel.sessions,
                                                   synchronize: configManager.synchronizesSelection) {
            selectedPane = item
        } else {
            // Only discard a missing target after a successful list response.
            paneSelectionStore.save(nil, for: serverID)
        }
    }

    private func handlePendingNavigation() {
        guard let key = AppDelegate.shared?.pendingNavigationTarget,
              !viewModel.sessions.isEmpty else { return }
        AppDelegate.shared?.pendingNavigationTarget = nil
        navigateToPaneWithKey(key)
    }

    private func navigateToPaneWithKey(_ key: String) {
        let components = key.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else { return }
        let deviceId = String(components[0])
        let paneTarget = String(components[1])

        let navigationID = UUID()
        pendingNavigationID = navigationID
        Task {
            defer {
                if pendingNavigationID == navigationID { pendingNavigationID = nil }
            }
            configManager.setActiveServer(deviceId)
            await viewModel.loadSessions()
            guard pendingNavigationID == navigationID,
                  configManager.activeServer?.id == deviceId,
                  viewModel.loadedServerID == deviceId else { return }
            navigateToPaneWithTarget(paneTarget)
        }
    }

    private func navigateToPaneWithTarget(_ paneTarget: String) {
        if let item = PaneNavigationItem.matching(target: paneTarget, in: viewModel.sessions) {
            selectedPane = item
        }
    }

    private var serverListButton: some View {
        Button {
            showServerList = true
        } label: {
            Image(systemName: "list.bullet")
        }
    }

    private var currentServerName: String {
        if configManager.isDemoMode {
            return String(localized: "Demo")
        } else if let server = configManager.activeServer {
            return server.serverName
        }
        return ""
    }

    @ViewBuilder
    private var settingsButton: some View {
        if !configManager.isDemoMode && configManager.activeServer != nil {
            Button {
                showServerSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }
}

// MARK: - PaneNavigationItem

struct PaneNavigationItem: Hashable {
    let pane: Pane
    let windowName: String

    static func matching(target: String, in sessions: [Session]) -> Self? {
        for session in sessions {
            for window in session.windows {
                if let pane = window.panes.first(where: { $0.target == target }) {
                    return Self(pane: pane, windowName: window.name)
                }
            }
        }
        return nil
    }

    // Keep an open window visible when its selected pane exits or is deleted.
    static func reconciling(target: String, in sessions: [Session]) -> Self? {
        if let current = matching(target: target, in: sessions) { return current }
        guard let separator = target.lastIndex(of: ".") else { return nil }
        let windowTarget = target[..<separator]
        for session in sessions {
            for window in session.windows {
                guard "\(session.name):\(window.index)" == windowTarget,
                      let pane = window.panes.first(where: \.active) ?? window.panes.first else { continue }
                return Self(pane: pane, windowName: window.name)
            }
        }
        return nil
    }

    static func restoring(target: String, in sessions: [Session], synchronize: Bool) -> Self? {
        guard synchronize else { return matching(target: target, in: sessions) }
        // Saved window/pane indexes can be stale. Reopening a synchronized
        // session should follow its current selection rather than change it.
        guard let sessionName = target.split(separator: ":", maxSplits: 1).first,
              let session = sessions.first(where: { $0.name == String(sessionName) }),
              let window = session.windows.first(where: \.active),
              let pane = window.panes.first(where: \.active) else { return nil }
        return Self(pane: pane, windowName: window.name)
    }

    static func items(in sessions: [Session]) -> [Self] {
        sessions.flatMap { session in
            session.windows.flatMap { window in
                window.panes.map { Self(pane: $0, windowName: window.name) }
            }
        }
    }

    static func adjacent(to selected: Self?, in sessions: [Session], backward: Bool) -> Self? {
        let items = items(in: sessions)
        guard !items.isEmpty else { return nil }
        guard let index = items.firstIndex(where: { $0.pane.target == selected?.pane.target }) else {
            return backward ? items.last : items.first
        }
        return items[(index + (backward ? -1 : 1) + items.count) % items.count]
    }
}

// MARK: - SessionSection

struct SessionSection: View {
    let session: Session
    let unreadPanes: Set<String>
    var onRequestDelete: (Pane) -> Void
    var onDeletePane: (String) async -> Void

    var body: some View {
        Section {
            ForEach(session.windows) { window in
                WindowRow(
                    window: window,
                    sessionName: session.name,
                    unreadPanes: unreadPanes,
                    onRequestDelete: onRequestDelete
                )
                .listRowSeparator(.visible)
            }
        } header: {
            HStack {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(session.attached ? .green : .secondary)
                Text(session.name)
                    .font(.headline)
                Spacer()
                if session.attached {
                    Text(String(localized: "attached"))
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
    }
}

// MARK: - WindowRow

struct WindowRow: View {
    let window: Window
    let sessionName: String
    let unreadPanes: Set<String>
    var onRequestDelete: (Pane) -> Void

    private var hasUnreadPane: Bool {
        window.panes.contains { unreadPanes.contains($0.target) }
    }

    var body: some View {
        Group {
            if window.panes.count == 1, let pane = window.panes.first {
                NavigationLink(value: PaneNavigationItem(pane: pane, windowName: window.name)) {
                    WindowLabel(window: window, isUnread: unreadPanes.contains(pane.target))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    deleteButton(for: pane)
                }
            } else {
                DisclosureGroup {
                    ForEach(window.panes) { pane in
                        NavigationLink(value: PaneNavigationItem(pane: pane, windowName: window.name)) {
                            PaneRow(pane: pane, windowName: window.name, isUnread: unreadPanes.contains(pane.target))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteButton(for: pane)
                        }
                        .listRowSeparator(.visible)
                    }
                } label: {
                    WindowLabel(window: window, isUnread: hasUnreadPane)
                }
            }
        }
    }

    private func deleteButton(for pane: Pane) -> some View {
        Button(role: .destructive) {
            onRequestDelete(pane)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }
}

// MARK: - WindowLabel

struct WindowLabel: View {
    @State private var permissionStatus = PermissionStatus.shared
    let window: Window
    var isUnread: Bool = false

    private var isWaiting: Bool {
        window.panes.contains { permissionStatus.isWaiting($0.target) }
    }

    var body: some View {
        HStack {
            Image(systemName: isWaiting ? "hand.raised.fill" : PaneIcon.iconName(for: window.name, path: window.panes.first?.currentPath ?? ""))
                .foregroundStyle(isWaiting ? .orange : PaneIcon.iconColor(for: window.name, isActive: window.active))
                .frame(width: 20)
                .accessibilityLabel(isWaiting ? String(localized: "Permission Required") : "")
            VStack(alignment: .leading) {
                Text(window.name)
                    .font(.body)
                HStack(spacing: 4) {
                    Text(String(localized: "Window \(window.index)"))
                    if let firstPane = window.panes.first {
                        Text(verbatim: "·")
                        Text(firstPane.shortPath)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if isUnread {
                Spacer()
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - PaneRow

struct PaneRow: View {
    @State private var permissionStatus = PermissionStatus.shared
    let pane: Pane
    var windowName: String = ""
    var isUnread: Bool = false

    private var isWaiting: Bool {
        permissionStatus.isWaiting(pane.target)
    }

    var body: some View {
        HStack {
            Image(systemName: isWaiting ? "hand.raised.fill" : PaneIcon.iconName(for: windowName, path: pane.currentPath))
                .foregroundStyle(isWaiting ? .orange : PaneIcon.iconColor(for: windowName, isActive: pane.active))
                .frame(width: 20)
                .accessibilityLabel(isWaiting ? String(localized: "Permission Required") : "")
            VStack(alignment: .leading) {
                Text(String(localized: "Pane \(pane.index)"))
                    .font(.body)
                Text(pane.shortPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isUnread {
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
            }
            if pane.active {
                Text(String(localized: "active"))
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - SessionListViewModel

@MainActor
@Observable
class SessionListViewModel {
    var sessions: [Session] = []
    private(set) var loadedServerID: String?
    var isLoading = false
    var showError = false
    var errorMessage = ""

    private let api = ReattachAPI.shared
    private var loadGeneration = 0
    private var reloadRequested = false

    func observeSessionChanges() async {
        var retryDelay = 1
        while !Task.isCancelled {
            do {
                let socket = try api.makeSessionListWebSocket()
                try await withTaskCancellationHandler {
                    socket.resume()
                    defer { socket.cancel(with: .goingAway, reason: nil) }
                    try Task.checkCancellation()
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        let event = try JSONDecoder().decode(SessionListEvent.self, from: data)
                        if event.type == "sessions_changed" {
                            retryDelay = 1
                            await loadSessions(silently: true)
                        }
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
            do { try await Task.sleep(for: .seconds(retryDelay)) } catch { return }
            retryDelay = min(retryDelay * 2, 30)
        }
    }

    private struct SessionListEvent: Decodable {
        let type: String
    }

    @discardableResult
    func loadSessions(silently: Bool = false) async -> Bool {
        if silently && isLoading {
            reloadRequested = true
            return false
        }
        loadGeneration += 1
        let generation = loadGeneration
        let serverID = ServerConfigManager.shared.activeServer?.id
        let isDemo = ServerConfigManager.shared.isDemoMode
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
                if reloadRequested {
                    reloadRequested = false
                    Task { await self.loadSessions(silently: true) }
                }
            }
        }

        do {
            let loaded = try await api.listSessions()
            guard generation == loadGeneration, !Task.isCancelled,
                  ServerConfigManager.shared.activeServer?.id == serverID,
                  ServerConfigManager.shared.isDemoMode == isDemo else { return false }
            sessions = loaded
            loadedServerID = serverID
            return true
        } catch let error as APIError {
            guard generation == loadGeneration, !Task.isCancelled, !silently else { return false }
            if case .unauthorized = error {
                return false
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !silently else { return false }
            errorMessage = error.localizedDescription
            showError = true
        }
        return false
    }

    func createSession(name: String, cwd: String) async throws -> PaneNavigationItem {
        let target = try await api.createSession(name: name, cwd: cwd)
        return try await createdPane(target: target)
    }

    func createWindow(target: String) async throws -> PaneNavigationItem {
        let createdTarget = try await api.createWindow(target: target)
        return try await createdPane(target: createdTarget)
    }

    private func createdPane(target: String) async throws -> PaneNavigationItem {
        sessions = try await api.listSessions()
        for session in sessions {
            for window in session.windows {
                if let pane = window.panes.first(where: { $0.target == target }) {
                    return PaneNavigationItem(pane: pane, windowName: window.name)
                }
            }
        }
        throw APIError.serverError(String(localized: "Created pane could not be found. Refresh the session list."))
    }

    func deletePane(target: String) async {
        do {
            try await api.deletePane(target: target)
            await loadSessions()
        } catch let error as APIError {
            if case .unauthorized = error {
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

#Preview {
    SessionListView()
}

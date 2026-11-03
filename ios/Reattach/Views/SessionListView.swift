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
    @State private var viewModel = SessionListViewModel()
    @State private var showingCreateSheet = false
    @State private var isCreatingWindow = false
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
    @State private var showServerList = false
    @State private var showServerSettings = false
    @State private var configManager = ServerConfigManager.shared
    @State private var paneToDelete: Pane?

    var body: some View {
        adaptiveLayout
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("New Session", systemImage: "plus.rectangle.on.folder") {
                    showingCreateSheet = true
                }
                .disabled(ReattachAPI.shared.isDemoMode)
                Button("次のペイン", systemImage: "arrow.right") {
                    cyclePane(backward: false)
                }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: .control)
                Button("前のペイン", systemImage: "arrow.left") {
                    cyclePane(backward: true)
                }
                .keyboardShortcut(KeyEquivalent("\t"), modifiers: [.control, .shift])
                Button("一覧の表示・非表示", systemImage: "sidebar.left") {
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
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .task {
            await loadAndRestorePane()
            unreadPaneKeys = AppDelegate.shared?.unreadPanes ?? []
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
                }
        } detail: {
            if let selected = selectedPane {
                PaneDetailView(pane: selected.pane, windowName: selected.windowName) { state in
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
                    .onAppear {
                        if let deviceId = ServerConfigManager.shared.activeServer?.deviceId {
                            AppDelegate.shared?.markPaneAsRead(deviceId: deviceId, paneTarget: selected.pane.target)
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Select a Pane",
                    systemImage: "terminal",
                    description: Text("Choose a pane from the sidebar")
                )
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
            ProgressView("Loading sessions...")
        } else {
            List(selection: $selectedPane) {
                if viewModel.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Create a new session to get started")
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
                                Text("Demo Mode")
                                    .font(.headline)
                                Text("Showing sample data. Set up a server to connect.")
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
                        Button("New Session", systemImage: "plus.circle") { showingCreateSheet = true }
                            .disabled(ReattachAPI.shared.isDemoMode)
                    } else {
                        Button {
                            guard let selected = selectedPane else { return }
                            isCreatingWindow = true
                            Task {
                                defer { isCreatingWindow = false }
                                do {
                                    selectedPane = try await viewModel.createWindow(target: selected.pane.target)
                                } catch {
                                    viewModel.errorMessage = error.localizedDescription
                                    viewModel.showError = true
                                }
                            }
                        } label: {
                            Label("New Window", systemImage: "plus.circle")
                        }
                        .disabled(selectedPane == nil || isCreatingWindow || ReattachAPI.shared.isDemoMode)
                    }
                }
            }
            .listStyle(.sidebar)
            .refreshable {
                await loadAndRestorePane()
            }
            .confirmationDialog(
                "Delete Pane",
                isPresented: Binding(
                    get: { paneToDelete != nil },
                    set: { if !$0 { paneToDelete = nil } }
                ),
                presenting: paneToDelete
            ) { pane in
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deletePane(target: pane.target)
                        paneToDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    paneToDelete = nil
                }
            } message: { pane in
                Text("Are you sure you want to delete this pane?\n\(pane.shortPath)")
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
        if let item = PaneNavigationItem.matching(target: target, in: viewModel.sessions) {
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
            return "Demo"
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

    static func adjacent(to selected: Self?, in sessions: [Session], backward: Bool) -> Self? {
        let items = sessions.flatMap { session in
            session.windows.flatMap { window in
                window.panes.map { Self(pane: $0, windowName: window.name) }
            }
        }
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
                    Text("attached")
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
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - WindowLabel

struct WindowLabel: View {
    let window: Window
    var isUnread: Bool = false

    var body: some View {
        HStack {
            Image(systemName: PaneIcon.iconName(for: window.name, path: window.panes.first?.currentPath ?? ""))
                .foregroundStyle(PaneIcon.iconColor(for: window.name, isActive: window.active))
            VStack(alignment: .leading) {
                Text(window.name)
                    .font(.body)
                HStack(spacing: 4) {
                    Text("Window \(window.index)")
                    if let firstPane = window.panes.first {
                        Text("·")
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
    let pane: Pane
    var windowName: String = ""
    var isUnread: Bool = false

    var body: some View {
        HStack {
            Image(systemName: PaneIcon.iconName(for: windowName, path: pane.currentPath))
                .foregroundStyle(PaneIcon.iconColor(for: windowName, isActive: pane.active))
            VStack(alignment: .leading) {
                Text("Pane \(pane.index)")
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
                Text("active")
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

    @discardableResult
    func loadSessions() async -> Bool {
        let serverID = ServerConfigManager.shared.activeServer?.id
        let isDemo = ServerConfigManager.shared.isDemoMode
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await api.listSessions()
            guard !Task.isCancelled,
                  ServerConfigManager.shared.activeServer?.id == serverID,
                  ServerConfigManager.shared.isDemoMode == isDemo else { return false }
            sessions = loaded
            loadedServerID = serverID
            return true
        } catch let error as APIError {
            if case .unauthorized = error {
                return false
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
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
        throw APIError.serverError("Created pane could not be found. Refresh the session list.")
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

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
    @State private var selectedPane: PaneNavigationItem?
    @State private var navigationPath = NavigationPath()
    @State private var unreadPanes: Set<String> = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateSessionView { name, cwd in
                await viewModel.createSession(name: name, cwd: cwd)
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .task {
            await viewModel.loadSessions()
            unreadPanes = AppDelegate.shared?.unreadPanes ?? []
            if let dirName = AppDelegate.shared?.pendingNavigationDirName {
                AppDelegate.shared?.pendingNavigationDirName = nil
                navigateToPaneWithDir(dirName)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPane)) { notification in
            guard let dirName = notification.userInfo?["dirName"] as? String else { return }
            navigateToPaneWithDir(dirName)
        }
        .onReceive(NotificationCenter.default.publisher(for: .unreadPanesChanged)) { _ in
            unreadPanes = AppDelegate.shared?.unreadPanes ?? []
        }
    }

    // MARK: - iPhone Layout (NavigationStack)
    private var compactLayout: some View {
        NavigationStack(path: $navigationPath) {
            listContent
                .navigationTitle("")
                .navigationDestination(for: PaneNavigationItem.self) { item in
                    PaneDetailView(pane: item.pane, windowName: item.windowName)
                        .onAppear {
                            AppDelegate.shared?.markPaneAsRead(item.pane.shortPath)
                        }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
        }
    }

    // MARK: - iPad Layout (NavigationSplitView)
    private var regularLayout: some View {
        NavigationSplitView {
            listContent
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
        } detail: {
            if let selected = selectedPane {
                PaneDetailView(pane: selected.pane, windowName: selected.windowName)
                    .id(selected.pane.target)
                    .onAppear {
                        AppDelegate.shared?.markPaneAsRead(selected.pane.shortPath)
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

    @ViewBuilder
    private var listContent: some View {
        if viewModel.isLoading && viewModel.sessions.isEmpty {
            ProgressView("Loading sessions...")
        } else if viewModel.sessions.isEmpty {
            ContentUnavailableView(
                "No Sessions",
                systemImage: "terminal",
                description: Text("Create a new session to get started")
            )
        } else {
            List(viewModel.sessions) { session in
                SessionSection(
                    session: session,
                    unreadPanes: unreadPanes,
                    isCompact: horizontalSizeClass == .compact,
                    selectedPane: $selectedPane,
                    navigationPath: $navigationPath
                ) { target in
                    await viewModel.deletePane(target: target)
                }
            }
            .listStyle(.sidebar)
            .refreshable {
                await viewModel.loadSessions()
            }
        }
    }

    private func navigateToPaneWithDir(_ dirName: String) {
        for session in viewModel.sessions {
            for window in session.windows {
                for pane in window.panes {
                    if pane.shortPath == dirName {
                        let item = PaneNavigationItem(pane: pane, windowName: window.name)
                        if horizontalSizeClass == .compact {
                            navigationPath.append(item)
                        } else {
                            selectedPane = item
                        }
                        return
                    }
                }
            }
        }
    }
}

// MARK: - PaneNavigationItem

struct PaneNavigationItem: Hashable {
    let pane: Pane
    let windowName: String
}

// MARK: - SessionSection

struct SessionSection: View {
    let session: Session
    let unreadPanes: Set<String>
    let isCompact: Bool
    @Binding var selectedPane: PaneNavigationItem?
    @Binding var navigationPath: NavigationPath
    let onDeletePane: (String) async -> Void

    var body: some View {
        Section {
            ForEach(session.windows) { window in
                WindowRow(
                    window: window,
                    sessionName: session.name,
                    unreadPanes: unreadPanes,
                    isCompact: isCompact,
                    selectedPane: $selectedPane,
                    navigationPath: $navigationPath,
                    onDelete: onDeletePane
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
    let isCompact: Bool
    @Binding var selectedPane: PaneNavigationItem?
    @Binding var navigationPath: NavigationPath
    let onDelete: (String) async -> Void

    @State private var paneToDelete: Pane?
    @State private var showDeleteConfirmation = false

    private var hasUnreadPane: Bool {
        window.panes.contains { unreadPanes.contains($0.shortPath) }
    }

    private func isSelected(_ pane: Pane) -> Bool {
        selectedPane?.pane.target == pane.target
    }

    private func selectPane(_ pane: Pane) {
        let item = PaneNavigationItem(pane: pane, windowName: window.name)
        if isCompact {
            navigationPath.append(item)
        } else {
            selectedPane = item
        }
    }

    var body: some View {
        Group {
            if window.panes.count == 1, let pane = window.panes.first {
                if isCompact {
                    NavigationLink(value: PaneNavigationItem(pane: pane, windowName: window.name)) {
                        WindowLabel(window: window, isUnread: unreadPanes.contains(pane.shortPath))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            paneToDelete = pane
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } else {
                    Button {
                        selectPane(pane)
                    } label: {
                        WindowLabel(window: window, isUnread: unreadPanes.contains(pane.shortPath))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isSelected(pane) ? Color.accentColor.opacity(0.2) : nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            paneToDelete = pane
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } else {
                DisclosureGroup {
                    ForEach(window.panes) { pane in
                        if isCompact {
                            NavigationLink(value: PaneNavigationItem(pane: pane, windowName: window.name)) {
                                PaneRow(pane: pane, windowName: window.name, isUnread: unreadPanes.contains(pane.shortPath))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    paneToDelete = pane
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowSeparator(.visible)
                        } else {
                            Button {
                                selectPane(pane)
                            } label: {
                                PaneRow(pane: pane, windowName: window.name, isUnread: unreadPanes.contains(pane.shortPath))
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(isSelected(pane) ? Color.accentColor.opacity(0.2) : nil)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    paneToDelete = pane
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowSeparator(.visible)
                        }
                    }
                } label: {
                    WindowLabel(window: window, isUnread: hasUnreadPane)
                }
            }
        }
        .confirmationDialog(
            "Delete Pane",
            isPresented: $showDeleteConfirmation,
            presenting: paneToDelete
        ) { pane in
            Button("Delete", role: .destructive) {
                Task { await onDelete(pane.target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pane in
            Text("Are you sure you want to delete this pane?\n\(pane.shortPath)")
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
    var isLoading = false
    var showError = false
    var errorMessage = ""

    private let api = ReattachAPI.shared

    func loadSessions() async {
        isLoading = true
        defer { isLoading = false }

        do {
            sessions = try await api.listSessions()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func createSession(name: String, cwd: String) async {
        do {
            try await api.createSession(name: name, cwd: cwd)
            await loadSessions()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func deletePane(target: String) async {
        do {
            try await api.deletePane(target: target)
            await loadSessions()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

#Preview {
    SessionListView()
}

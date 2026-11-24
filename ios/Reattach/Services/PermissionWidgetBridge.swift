import Foundation
import Observation

@MainActor
enum PermissionWidgetBridge {
    static func synchronize(_ manager: ServerConfigManager) {
        let connections = manager.isDemoMode ? [] : manager.servers.map(connection)
        PermissionWidgetStore.synchronize(connections)
        WatchServerSync.shared.update(connections)
    }

    static func connection(_ server: ServerConfig) -> PermissionWidgetConnection {
        .init(serverID: server.id, serverName: server.serverName, serverURL: server.serverURL,
              token: server.deviceToken, accessClientID: server.cfAccessClientId, accessClientSecret: server.cfAccessClientSecret)
    }

    static func publish(entries: [PermissionAttention], sessions: [Session], serverID: String?) {
        let manager = ServerConfigManager.shared
        guard !manager.isDemoMode, let server = manager.servers.first(where: { $0.id == serverID }) else { return }
        let titles = Dictionary(sessions.flatMap(\.windows).flatMap { window in
            window.panes.map { ($0.target, $0.shortPath.isEmpty ? window.name : $0.shortPath) }
        }, uniquingKeysWith: { first, _ in first })
        let previous = PermissionWidgetStore.read(for: connection(server))
        let snapshot = PermissionWidgetSnapshot(serverID: server.id, serverName: server.serverName,
            requests: entries.map { .init(target: $0.target, title: titles[$0.target] ?? $0.target, tool: $0.tool) },
            updatedAt: Date(), unavailable: false, updatedPanes: previous.updatedPanes, updatesUnavailable: previous.updatesUnavailable)
        PermissionWidgetStore.publish(snapshot, for: connection(server), reload: true)
    }

    static func failed(serverID: String?) {
        guard let server = ServerConfigManager.shared.servers.first(where: { $0.id == serverID }) else { return }
        let previous = PermissionWidgetStore.read(for: connection(server))
        guard previous.serverID == serverID else { return }
        PermissionWidgetStore.publish(previous.failed(), for: connection(server), reload: true)
    }
}

@MainActor @Observable
final class PermissionWidgetRoute {
    static let shared = PermissionWidgetRoute()
    private var requestedAt: Date?
    /// Expires so a stale widget or notification tap cannot open the inbox much later.
    var pending: Bool {
        get { requestedAt.map { Date().timeIntervalSince($0) < 10 } ?? false }
        set { requestedAt = newValue ? Date() : nil }
    }
    /// The request to show first, as `PermissionAttention.id`.
    var focus: String?

    @discardableResult func open(_ url: URL) -> Bool {
        guard let destination = PermissionWidgetDestination(url: url) else { return false }
        let manager = ServerConfigManager.shared
        if let serverID = destination.serverID {
            guard manager.servers.contains(where: { $0.id == serverID }) else { return false }
        }
        pending = true
        return true
    }
}

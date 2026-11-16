import Foundation
import Observation

@MainActor @Observable
final class PaneActivityStore {
    static let shared = PaneActivityStore()
    private(set) var byServer: [String: [PaneActivity]] = [:]
    private(set) var unavailable: Set<String> = []
    var viewingServer: String?
    var viewingTarget: String?
    private var viewingReady = false
    private var configurations: [ServerConfig] = []

    func unreadTargets(serverID: String?) -> Set<String> {
        Set(byServer[serverID ?? "", default: []].filter(\.unread).map(\.target))
    }

    func refresh(servers: [ServerConfig]) async {
        let unchanged = Set(servers.filter { configurations.contains($0) }.map(\.id))
        byServer = byServer.filter { unchanged.contains($0.key) }
        unavailable.formIntersection(unchanged)
        configurations = servers
        await withTaskGroup(of: (ServerConfig, [PaneActivity]?).self) { group in
            for server in servers {
                group.addTask { @MainActor in
                    (server, try? await ReattachAPI(server: server).paneActivity())
                }
            }
            for await (server, entries) in group {
                guard !Task.isCancelled, configurations.contains(server) else { continue }
                if let entries { byServer[server.id] = entries; unavailable.remove(server.id) }
                else { unavailable.insert(server.id) }
                await acknowledgeViewing(server: server)
                publish(server)
            }
        }
    }

    func beginViewing(server: ServerConfig, target: String) {
        viewingServer = server.id; viewingTarget = target; viewingReady = false
    }

    func endViewing(serverID: String, target: String) {
        if viewingServer == serverID, viewingTarget == target { viewingServer = nil; viewingTarget = nil; viewingReady = false }
    }

    func displayedOutput(server: ServerConfig, target: String, ready: Bool) {
        guard viewingServer == server.id, viewingTarget == target else { return }
        viewingReady = ready
        if ready { Task { await acknowledgeViewing(server: server); publish(server) } }
    }

    private func acknowledgeViewing(server: ServerConfig) async {
        guard viewingReady, configurations.contains(server), !unavailable.contains(server.id), viewingServer == server.id,
              let entry = byServer[server.id]?.first(where: { $0.target == viewingTarget && $0.unread }) else { return }
        do {
            try await ReattachAPI(server: server).markActivityRead(entry)
            guard configurations.contains(server),
                  let index = byServer[server.id]?.firstIndex(where: { $0.target == entry.target && $0.revision == entry.revision }) else { return }
            byServer[server.id]?[index].unread = false
        } catch { /* Keep unread; a newer revision or a connection error must not clear it. */ }
    }

    private func publish(_ server: ServerConfig) {
        guard configurations.contains(server) else { return }
        PermissionWidgetStore.publishActivity(targets: byServer[server.id]?.filter(\.unread).map(\.target),
            unavailable: unavailable.contains(server.id), for: PermissionWidgetBridge.connection(server))
    }
}

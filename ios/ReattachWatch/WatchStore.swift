import Foundation
import Observation

@MainActor
@Observable
final class WatchStore {
    static let shared = WatchStore()
    private static let connectionsKey = "connections"

    private(set) var connections: [WatchConnection] = []
    private(set) var requests: [PendingRequest] = []
    private(set) var unavailableServers: [String] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var focus: NotificationFocus?

    private init() {
        // Earlier builds kept the tokens in UserDefaults.
        if let legacy = UserDefaults.standard.data(forKey: Self.connectionsKey) {
            if WatchKeychain.data(for: Self.connectionsKey) != nil || WatchKeychain.set(legacy, for: Self.connectionsKey) {
                UserDefaults.standard.removeObject(forKey: Self.connectionsKey)
            }
        }
        if let data = WatchKeychain.data(for: Self.connectionsKey) ?? UserDefaults.standard.data(forKey: Self.connectionsKey),
           let saved = try? JSONDecoder().decode([WatchConnection].self, from: data) {
            connections = saved
        }
    }

    func replaceConnections(with data: Data) {
        guard let received = try? JSONDecoder().decode([WatchConnection].self, from: data),
              received != connections else { return }
        connections = received
        WatchKeychain.set(data, for: Self.connectionsKey)
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        var loaded: [PendingRequest] = []
        var failed: [String] = []
        await withTaskGroup(of: (WatchConnection, [PendingRequest]?).self) { group in
            for connection in connections {
                group.addTask { (connection, try? await WatchAPI(connection: connection).pending()) }
            }
            for await (connection, result) in group {
                if let result { loaded += result } else { failed.append(connection.serverName) }
            }
        }
        requests = loaded.sorted { $0.receivedAt < $1.receivedAt }
        unavailableServers = failed.sorted()
    }

    func request(for focus: NotificationFocus) -> PendingRequest? {
        requests.first {
            $0.connection.serverID == focus.serverID && $0.target == focus.target
                && (focus.receivedAt == nil || $0.receivedAt == focus.receivedAt)
        }
    }

    func respond(to request: PendingRequest, choice: String) async throws {
        guard let prompt = request.prompt else { return }
        try await WatchAPI(connection: request.connection).respond(to: request, digest: prompt.digest, choice: choice)
        requests.removeAll { $0.id == request.id }
    }

    /// Notification buttons carry the digest the notification showed.
    func respond(serverID: String, target: String, receivedAt: Int64, digest: String, choice: String) async throws {
        guard let connection = connections.first(where: { $0.serverID == serverID }) else { return }
        let request = PendingRequest(connection: connection, target: target, tool: "", receivedAt: receivedAt, prompt: nil)
        try await WatchAPI(connection: connection).respond(to: request, digest: digest, choice: choice)
        requests.removeAll { $0.id == request.id }
    }
}

import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class WatchStore {
    static let shared = WatchStore()
    private static let connectionsKey = WatchKeychain.connectionsAccount

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
        connections = WatchKeychain.connections()
        if connections.isEmpty, let legacy = UserDefaults.standard.data(forKey: Self.connectionsKey),
           let saved = try? JSONDecoder().decode([WatchConnection].self, from: legacy) {
            connections = saved
        }
    }

    func replaceConnections(with data: Data) {
        guard let received = try? JSONDecoder().decode([WatchConnection].self, from: data),
              received != connections else { return }
        connections = received
        WatchKeychain.set(data, for: Self.connectionsKey)
        WidgetCenter.shared.reloadAllTimelines()
        Task { await refresh() }
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-store-screenshot") {
            connections = [Self.storeConnection]
            requests = Self.storeRequests
            hasLoaded = true
            if ProcessInfo.processInfo.arguments.contains("-store-screenshot-detail"), let first = requests.first {
                focus = NotificationFocus(serverID: first.connection.serverID, target: first.target, receivedAt: first.receivedAt)
            }
            return
        }
        #endif
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
        WidgetCenter.shared.reloadAllTimelines()
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
        WidgetCenter.shared.reloadAllTimelines()
    }

    #if DEBUG
    // Sample requests for App Store screenshots.
    private static let storeConnection = WatchConnection(serverID: "store", serverName: "MacBook Pro", serverURL: "",
                                                         token: "", accessClientID: nil, accessClientSecret: nil)
    private static let storeRequests: [PendingRequest] = [
        PendingRequest(connection: storeConnection, target: "webapp:0.0", tool: "Bash", receivedAt: 1,
                       prompt: PermissionPrompt(context: "Bash command\nnpm test", choices: [
                           PromptChoice(number: "1", label: "Yes"),
                           PromptChoice(number: "2", label: "Yes, and don't ask again for npm test"),
                           PromptChoice(number: "3", label: "No, and tell Claude what to do differently"),
                       ], digest: "store")),
        PendingRequest(connection: storeConnection, target: "api:0.0", tool: "Edit", receivedAt: 2,
                       prompt: PermissionPrompt(context: "Edit file\nsrc/routes/users.ts", choices: [
                           PromptChoice(number: "1", label: "Yes"),
                           PromptChoice(number: "2", label: "No"),
                       ], digest: "store")),
    ]
    #endif
}

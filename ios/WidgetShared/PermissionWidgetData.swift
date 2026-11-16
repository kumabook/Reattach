import Foundation
import Security
import WidgetKit

nonisolated struct PermissionWidgetDestination {
    let serverID: String?
    init?(url: URL) {
        guard url.scheme == "reattach", url.host == "permissions", url.path.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.queryItems ?? []
        guard query.count <= 1, query.allSatisfy({ $0.name == "server" && $0.value?.isEmpty == false }) else { return nil }
        serverID = query.first?.value
    }
}

nonisolated struct PermissionWidgetRequest: Codable, Equatable, Identifiable, Sendable {
    let target: String
    let title: String
    let tool: String
    var serverID: String? = nil
    var serverName: String? = nil
    var id: String { serverID.map { $0 + "|" + target } ?? target }
}

nonisolated struct PermissionWidgetSnapshot: Codable, Equatable, Sendable {
    var serverID: String?
    var serverName: String
    var requests: [PermissionWidgetRequest]
    var updatedAt: Date?
    var unavailable: Bool
    var unavailableServers: [String]? = nil
    var updatedPanes: [String]? = nil
    var updatesUnavailable: Bool? = nil
    var runningPanes: [String]? = nil

    static let empty = Self(serverID: nil, serverName: "Reattach", requests: [], updatedAt: nil, unavailable: false)

    var url: URL {
        var components = URLComponents()
        components.scheme = "reattach"
        components.host = "permissions"
        if let serverID { components.queryItems = [URLQueryItem(name: "server", value: serverID)] }
        return components.url!
    }

    func failed() -> Self {
        var copy = self
        copy.unavailable = true
        return copy
    }
}

nonisolated struct PermissionWidgetConnection: Codable, Equatable, Sendable {
    let serverID: String
    let serverName: String
    let serverURL: String
    let token: String
    let accessClientID: String?
    let accessClientSecret: String?

    func request(path: String) throws -> URLRequest {
        guard let base = URL(string: serverURL), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              ["attention", "sessions", "activity"].contains(path) else { throw URLError(.badURL) }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let accessClientID, let accessClientSecret, !accessClientID.isEmpty, !accessClientSecret.isEmpty {
            request.setValue(accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return request
    }
}

nonisolated enum PermissionWidgetStore {
    static let group = "group.tokyo.kumabook.tmux.reattach"
    static let kind = "ReattachPendingRequests"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }
    private static let snapshotKey = "permissionWidgetSnapshot"
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ReattachPermissionWidget",
         kSecAttrAccount as String: "activeServer",
         kSecAttrAccessGroup as String: group]
    }

    static func connections() -> [PermissionWidgetConnection] {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return [] }
        if let connections = try? JSONDecoder().decode([PermissionWidgetConnection].self, from: data) { return connections }
        // Migrate build 47's single-server keychain record without exposing credentials.
        return (try? JSONDecoder().decode(PermissionWidgetConnection.self, from: data)).map { [$0] } ?? []
    }

    @discardableResult
    static func synchronize(_ connections: [PermissionWidgetConnection]) -> Bool {
        let previous = self.connections()
        if previous == connections { return true }
        let status: OSStatus
        if !connections.isEmpty, let data = try? JSONEncoder().encode(connections) {
            let values: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let updated = SecItemUpdate(keychainQuery as CFDictionary, values as CFDictionary)
            status = updated == errSecItemNotFound
                ? SecItemAdd(keychainQuery.merging(values) { _, new in new } as CFDictionary, nil) : updated
        } else { status = SecItemDelete(keychainQuery as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        for old in previous where !connections.contains(old) {
            defaults?.removeObject(forKey: snapshotKey + "." + old.serverID)
        }
        for connection in connections where !previous.contains(connection) {
            write(.init(serverID: connection.serverID, serverName: connection.serverName,
                        requests: [], updatedAt: nil, unavailable: true), serverID: connection.serverID)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        Task {
            for old in previous where !connections.contains(old) {
                await PermissionWidgetPush.synchronize(connection: old, enabled: false)
            }
            await PermissionWidgetPush.synchronize()
        }
        return true
    }

    static func read(for connection: PermissionWidgetConnection) -> PermissionWidgetSnapshot {
        if let data = defaults?.data(forKey: snapshotKey + "." + connection.serverID),
           let snapshot = try? JSONDecoder().decode(PermissionWidgetSnapshot.self, from: data) { return snapshot }
        if let data = defaults?.data(forKey: snapshotKey),
           let legacy = try? JSONDecoder().decode(PermissionWidgetSnapshot.self, from: data),
           legacy.serverID == connection.serverID { return legacy }
        return .init(serverID: connection.serverID, serverName: connection.serverName, requests: [], updatedAt: nil, unavailable: true)
    }

    static func aggregate(_ snapshots: [PermissionWidgetSnapshot]) -> PermissionWidgetSnapshot {
        guard !snapshots.isEmpty else { return .empty }
        let requests = snapshots.flatMap { snapshot in snapshot.requests.map { request in
            var copy = request
            copy.serverID = snapshot.serverID
            copy.serverName = snapshot.serverName
            return copy
        } }
        let unavailable = snapshots.filter { $0.unavailable || $0.updatedAt == nil }.map(\.serverName)
        return .init(serverID: nil, serverName: "", requests: requests,
                     updatedAt: snapshots.compactMap(\.updatedAt).min(), unavailable: !unavailable.isEmpty,
                     unavailableServers: unavailable,
                     updatedPanes: snapshots.contains { $0.updatedPanes != nil } ? snapshots.flatMap { snapshot in (snapshot.updatedPanes ?? []).map { (snapshot.serverID ?? "") + "|" + $0 } } : nil,
                     updatesUnavailable: snapshots.contains { $0.updatesUnavailable == true || $0.updatedPanes == nil },
                     runningPanes: snapshots.contains { $0.runningPanes != nil } ? snapshots.flatMap { snapshot in (snapshot.runningPanes ?? []).map { (snapshot.serverID ?? "") + "|" + $0 } } : nil)
    }

    static func read() -> PermissionWidgetSnapshot { aggregate(connections().map { read(for: $0) }) }

    private static func write(_ snapshot: PermissionWidgetSnapshot, serverID: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: snapshotKey + "." + serverID)
    }

    static func publishActivity(targets: [String]?, running: [String]? = nil,
                                unavailable: Bool, for connection: PermissionWidgetConnection) {
        guard connections().contains(connection) else { return }
        var snapshot = read(for: connection)
        if let targets {
            snapshot.updatedPanes = targets.sorted()
            snapshot.runningPanes = running?.sorted()
        }
        snapshot.updatesUnavailable = unavailable
        publish(snapshot, for: connection, reload: true)
    }

    static func publish(_ snapshot: PermissionWidgetSnapshot, for connection: PermissionWidgetConnection, reload: Bool) {
        guard connections().contains(connection), snapshot.serverID == connection.serverID else { return }
        let previous = read(for: connection)
        guard (previous.updatedAt ?? .distantPast) <= (snapshot.updatedAt ?? .distantPast) else { return }
        write(snapshot, serverID: connection.serverID)
        if reload {
            let now = Date().timeIntervalSince1970
            let lastReload = defaults?.double(forKey: "permissionWidgetReloadTime") ?? 0
            if previous.requests != snapshot.requests || previous.unavailable != snapshot.unavailable || previous.updatedPanes != snapshot.updatedPanes || previous.updatesUnavailable != snapshot.updatesUnavailable || previous.runningPanes != snapshot.runningPanes || now - lastReload >= 60 {
                defaults?.set(now, forKey: "permissionWidgetReloadTime")
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            }
        }
    }

}

// Never forward credentials through a redirect or share the app's browser cookies.
nonisolated final class PermissionWidgetRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated enum PermissionWidgetLoader {
    struct Attention: Decodable { let target: String; let tool: String }
    struct Session: Decodable { let windows: [Window] }
    struct Window: Decodable { let name: String; let panes: [Pane] }
    struct Pane: Decodable { let target: String; let current_path: String }

    static func fetch(_ connection: PermissionWidgetConnection, previous: PermissionWidgetSnapshot,
                      session: URLSession) async throws -> PermissionWidgetSnapshot {
        let (data, response) = try await session.data(for: connection.request(path: "attention"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let attention = try JSONDecoder().decode([Attention].self, from: data)
        var titles = previous.serverID == connection.serverID
            ? Dictionary(previous.requests.map { ($0.target, $0.title) }, uniquingKeysWith: { first, _ in first }) : [:]
        if !attention.isEmpty,
           let (sessionsData, sessionsResponse) = try? await session.data(for: connection.request(path: "sessions")),
           (sessionsResponse as? HTTPURLResponse)?.statusCode == 200,
           let sessions = try? JSONDecoder().decode([Session].self, from: sessionsData) {
            for window in sessions.flatMap(\.windows) {
                for pane in window.panes {
                    let folder = (pane.current_path as NSString).lastPathComponent
                    titles[pane.target] = folder.isEmpty ? window.name : folder
                }
            }
        }
        var seen = Set<String>()
        let requests = attention.filter { seen.insert($0.target).inserted }.map {
            PermissionWidgetRequest(target: $0.target, title: titles[$0.target] ?? $0.target, tool: $0.tool)
        }
        struct Agent: Decodable { let state: String }
        struct Activity: Decodable { let target: String; let unread: Bool; let agent: Agent? }
        var updated = previous.updatedPanes
        var running = previous.runningPanes
        var updatesUnavailable = true
        if let (activityData, activityResponse) = try? await session.data(for: connection.request(path: "activity")),
           (activityResponse as? HTTPURLResponse)?.statusCode == 200,
           let activity = try? JSONDecoder().decode([Activity].self, from: activityData) {
            updated = activity.filter { $0.unread && $0.agent?.state != "running" }.map(\.target).sorted()
            running = activity.filter { $0.agent?.state == "running" }.map(\.target).sorted()
            updatesUnavailable = false
        }
        return PermissionWidgetSnapshot(serverID: connection.serverID, serverName: connection.serverName,
                                        requests: requests, updatedAt: Date(), unavailable: false,
                                        updatedPanes: updated, updatesUnavailable: updatesUnavailable,
                                        runningPanes: running)
    }
}

nonisolated enum PermissionWidgetPush {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: PermissionWidgetStore.group) }

    static func store(token: Data, enabled: Bool, sandbox: Bool) {
        defaults?.set(token.map { String(format: "%02x", $0) }.joined(), forKey: "widgetPushToken")
        defaults?.set(enabled, forKey: "widgetPushEnabled")
        defaults?.set(sandbox, forKey: "widgetPushSandbox")
    }

    static func registrationRequest(connection: PermissionWidgetConnection, token: String, sandbox: Bool, enabled: Bool) throws -> URLRequest {
        var request = try connection.request(path: "attention")
        request.url = request.url?.deletingLastPathComponent().appendingPathComponent("widget-devices")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "sandbox": sandbox, "enabled": enabled])
        return request
    }

    static func synchronize() async {
        let connections = PermissionWidgetStore.connections()
        await withTaskGroup(of: Void.self) { group in
            for connection in connections { group.addTask { await synchronize(connection: connection) } }
        }
    }

    static func synchronize(connection: PermissionWidgetConnection, enabled: Bool? = nil) async {
        guard let token = defaults?.string(forKey: "widgetPushToken") else { return }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: PermissionWidgetRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let request = try registrationRequest(connection: connection, token: token,
                sandbox: defaults?.bool(forKey: "widgetPushSandbox") ?? false,
                enabled: enabled ?? defaults?.bool(forKey: "widgetPushEnabled") ?? false)
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 204 else { return }
        } catch {
            // Retry during the next timeline refresh; periodic updates still work.
        }
    }
}

nonisolated enum PushNotificationEnvironment {
    static var currentSandbox: Bool {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return isSandbox(profile: profile)
    }
    // Release builds installed directly from Xcode can also use development APNs.
    // Read the signed provisioning profile instead of inferring this from DEBUG.
    static func isSandbox(profile: Data?) -> Bool {
        guard let profile,
              let start = profile.range(of: Data("<plist".utf8)),
              let end = profile.range(of: Data("</plist>".utf8)), start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return false }
        return entitlements["aps-environment"] as? String == "development"
    }

}

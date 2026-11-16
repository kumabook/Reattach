import Foundation
import Observation

struct PermissionAttention: Decodable, Equatable, Identifiable {
    let target: String
    let tool: String
    let receivedAt: Int64
    var serverID: String? = nil
    var serverName: String? = nil
    var title: String? = nil
    var id: String { serverID.map { $0 + "|" + target } ?? target }
    func isSameRequest(as other: Self) -> Bool {
        target == other.target && tool == other.tool && receivedAt == other.receivedAt
    }
    enum CodingKeys: String, CodingKey {
        case target, tool
        case receivedAt = "received_at"
    }
}

#if os(iOS)
@MainActor
@Observable
class PermissionStatus {
    static let shared = PermissionStatus()

    static var usesUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-permission-ui-fixture")
        #else
        false
        #endif
    }

    static var uiTestEntries: [PermissionAttention] {
        guard usesUITestFixture else { return [] }
        return [
            PermissionAttention(target: "myproject:0.0", tool: "Bash", receivedAt: 1),
            PermissionAttention(target: "claude-demo:0.0",
                                tool: ProcessInfo.processInfo.arguments.contains("-permission-store-fixture") ? "Bash" : "Edit",
                                receivedAt: 2)
        ]
    }
    private(set) var entries: [PermissionAttention] = []
    private var serverID: String?
    private var configuredServers: [ServerConfig] = []
    private var byServer: [String: [PermissionAttention]] = [:]
    private(set) var unavailableServers: [String: String] = [:]

    func configure(servers: [ServerConfig]) {
        let unchanged = servers.filter { configuredServers.contains($0) }.map(\.id)
        byServer = byServer.filter { unchanged.contains($0.key) }
        unavailableServers = unavailableServers.filter { unchanged.contains($0.key) }
        configuredServers = servers
        rebuild()
    }

    private func rebuild() {
        entries = configuredServers.flatMap { byServer[$0.id] ?? [] }
            .sorted { $0.receivedAt == $1.receivedAt ? $0.id < $1.id : $0.receivedAt < $1.receivedAt }
    }

    func apply(_ requests: [PermissionAttention]?, server: ServerConfig, sessions: [Session] = []) {
        guard configuredServers.contains(server) else { return }
        if let requests {
            let titles = Dictionary(sessions.flatMap(\.windows).flatMap { window in
                window.panes.map { ($0.target, $0.shortPath.isEmpty ? window.name : $0.shortPath) }
            }, uniquingKeysWith: { first, _ in first })
            byServer[server.id] = requests.map {
                var request = $0
                request.serverID = server.id
                request.serverName = server.serverName
                request.title = titles[request.target] ?? byServer[server.id]?.first(where: { $0.target == request.target })?.title
                return request
            }
            unavailableServers.removeValue(forKey: server.id)
        } else { unavailableServers[server.id] = server.serverName }
        rebuild()
    }

    func refreshAll(servers: [ServerConfig]) async {
        async let activity: () = PaneActivityStore.shared.refresh(servers: servers)
        await withTaskGroup(of: (ServerConfig, [PermissionAttention]?, [Session]).self) { group in
            for server in servers {
                group.addTask { @MainActor in
                    let api = ReattachAPI(server: server)
                    do {
                        let requests = try await api.permissionAttention()
                        let sessions = requests.isEmpty ? [] : (try? await api.listSessions()) ?? []
                        return (server, requests, sessions)
                    } catch { return (server, nil, []) }
                }
            }
            for await (server, requests, sessions) in group {
                guard !Task.isCancelled, configuredServers.contains(server) else { continue }
                apply(requests, server: server, sessions: sessions)
                if let requests { PermissionWidgetBridge.publish(entries: requests, sessions: sessions, serverID: server.id) }
                else { PermissionWidgetBridge.failed(serverID: server.id) }
            }
        }
        await activity
    }

    func reset(serverID: String?) {
        self.serverID = serverID
        entries = []
        byServer = [:]
        unavailableServers = [:]
    }

    func update(_ entries: [PermissionAttention], serverID: String?) {
        guard self.serverID == serverID else { return }
        self.entries = entries
    }

    func isWaiting(_ target: String) -> Bool {
        entries.contains { $0.target == target && ($0.serverID == nil || $0.serverID == ServerConfigManager.shared.activeServer?.id) }
    }
}

#endif

/// Only offer numbered choices actually shown by a terminal selection menu.
struct PermissionChoice: Equatable, Identifiable {
    let number: String
    let label: String
    let selected: Bool
    var id: String { number }

    static func parse(_ output: String) -> [Self] {
        let text = TerminalTextRenderer.render(output).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^\s*([❯›>▶▸])?\s*([1-9][0-9]*)[.)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var groups: [[Self]] = []
        var current: [Self] = []
        for line in text.components(separatedBy: .newlines).suffix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Press enter to confirm or esc to cancel" || trimmed == "enter to submit | esc to cancel" {
                break
            }
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let numberRange = Range(match.range(at: 2), in: line),
               let labelRange = Range(match.range(at: 3), in: line) {
                let number = String(line[numberRange])
                if number == "1", !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                current.append(Self(number: number,
                                    label: String(line[labelRange]).trimmingCharacters(in: .whitespaces),
                                    selected: match.range(at: 1).location != NSNotFound))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !current.isEmpty {
                if line.hasPrefix("  "), let previous = current.popLast() {
                    current.append(Self(number: previous.number,
                                        label: previous.label + " " + line.trimmingCharacters(in: .whitespaces),
                                        selected: previous.selected))
                } else {
                    groups.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty { groups.append(current) }
        guard let choices = groups.last, choices.count >= 2,
              choices.filter(\.selected).count == 1,
              choices.enumerated().allSatisfy({ $0.element.number == String($0.offset + 1) }) else {
            return []
        }
        return choices
    }
}

/// Preserve the current request on inserts; advance to its neighbor on removal.
enum PermissionPaging {
    static func swipeStep(translation: CGFloat, predicted: CGFloat, height: CGFloat) -> Int {
        guard height > 0, abs(translation) >= 20 else { return 0 }
        let committed = abs(translation) > min(height * 0.14, 90)
            || (abs(predicted) > height * 0.35 && translation * predicted > 0)
        guard committed else { return 0 }
        return translation < 0 ? 1 : -1
    }

    static func selection(current: String?, old: [String], new: [String]) -> String? {
        guard !new.isEmpty else { return nil }
        if let current, new.contains(current) { return current }
        let index = current.flatMap { old.firstIndex(of: $0) } ?? 0
        return new[min(index, new.count - 1)]
    }
}


/// Only successful foreground polls update this state. Blocked presentations
/// remain pending; requests seen while the inbox is open are already handled.
struct PermissionInboxAutoPresentation {
    private var observed: [String: [PermissionAttention]] = [:]

    mutating func update(entries: [PermissionAttention], serverID: String?, enabled: Bool,
                         visible: Bool, blocked: Bool) -> Bool {
        let key = serverID ?? "demo"
        guard !blocked || visible || !enabled else { return false }
        let previous = observed[key] ?? []
        let hasNewRequest = entries.contains { entry in
            !previous.contains { $0.id == entry.id && $0.isSameRequest(as: entry) }
        }
        observed[key] = entries
        return enabled && !visible && hasNewRequest
    }
}

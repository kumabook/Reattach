import Foundation
import Observation

struct PermissionAttention: Decodable, Equatable, Identifiable {
    let target: String
    let tool: String
    let receivedAt: Int64
    var id: String { target }
    enum CodingKeys: String, CodingKey {
        case target, tool
        case receivedAt = "received_at"
    }
}

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
            PermissionAttention(target: "claude-demo:0.0", tool: "Edit", receivedAt: 2)
        ]
    }
    private(set) var entries: [PermissionAttention] = []
    private var serverID: String?

    func reset(serverID: String?) {
        self.serverID = serverID
        entries = []
    }

    func update(_ entries: [PermissionAttention], serverID: String?) {
        guard self.serverID == serverID else { return }
        self.entries = entries
    }

    func isWaiting(_ target: String) -> Bool {
        entries.contains { $0.target == target }
    }
}

import Foundation

struct WatchConnection: Codable, Equatable {
    let serverID: String
    let serverName: String
    let serverURL: String
    let token: String
    let accessClientID: String?
    let accessClientSecret: String?
}

struct PromptChoice: Codable, Hashable {
    let number: String
    let label: String
}

struct PermissionPrompt: Codable, Equatable {
    let context: String
    let choices: [PromptChoice]
    let digest: String
}

struct PendingRequest: Identifiable, Equatable {
    let connection: WatchConnection
    let target: String
    let tool: String
    let receivedAt: Int64
    let prompt: PermissionPrompt?

    var id: String { "\(connection.serverID)|\(target)|\(receivedAt)" }
}

/// The request a notification refers to, kept until the list has loaded it.
struct NotificationFocus: Equatable {
    let serverID: String
    let target: String
    let receivedAt: Int64?
}

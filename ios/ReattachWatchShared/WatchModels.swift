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

extension NotificationFocus {
    private static let scheme = "reattach-watch"

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let serverID = items.first(where: { $0.name == "server" })?.value,
              let target = items.first(where: { $0.name == "target" })?.value else { return nil }
        self.init(serverID: serverID, target: target,
                  receivedAt: items.first(where: { $0.name == "receivedAt" })?.value.flatMap { Int64($0) })
    }

    static func url(for request: PendingRequest) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "request"
        components.queryItems = [
            URLQueryItem(name: "server", value: request.connection.serverID),
            URLQueryItem(name: "target", value: request.target),
            URLQueryItem(name: "receivedAt", value: String(request.receivedAt)),
        ]
        return components.url
    }
}

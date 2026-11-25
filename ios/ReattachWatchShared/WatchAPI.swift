import Foundation

enum WatchAPIError: LocalizedError {
    case rejected(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .rejected("changed"):
            return String(localized: "The request changed. Check it again.")
        case .rejected("no_longer_pending"):
            return String(localized: "This request is no longer pending.")
        case .rejected(let reason):
            return reason
        case .http(401), .http(403):
            return String(localized: "Sign-in expired. Open Reattach on iPhone.")
        case .http(let status):
            return String(localized: "Server error (\(status))")
        }
    }
}

struct WatchAPI {
    let connection: WatchConnection

    private struct Entry: Decodable {
        let target: String
        let tool: String
        let received_at: Int64
        let prompt: PermissionPrompt?
    }

    private struct Reply: Encodable {
        let target: String
        let received_at: Int64
        let digest: String
        let choice: String
    }

    private struct Failure: Decodable {
        let error: String
    }

    func pending() async throws -> [PendingRequest] {
        let data = try await send(path: "/attention/prompts", method: "GET", body: nil)
        return try JSONDecoder().decode([Entry].self, from: data).map {
            PendingRequest(connection: connection, target: $0.target, tool: $0.tool,
                           receivedAt: $0.received_at, prompt: $0.prompt)
        }
    }

    func respond(to request: PendingRequest, digest: String, choice: String) async throws {
        let body = try JSONEncoder().encode(Reply(target: request.target, received_at: request.receivedAt,
                                                  digest: digest, choice: choice))
        _ = try await send(path: "/attention/respond", method: "POST", body: body)
    }

    func registerWidget(token: String, sandbox: Bool, enabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "token": token, "sandbox": sandbox, "enabled": enabled, "platform": "watchos",
        ])
        _ = try await send(path: "/widget-devices", method: "POST", body: body)
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: connection.serverURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let id = connection.accessClientID, let secret = connection.accessClientSecret,
           !id.isEmpty, !secret.isEmpty {
            request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw WatchAPIError.rejected(failure.error)
            }
            throw WatchAPIError.http(status)
        }
        return data
    }
}

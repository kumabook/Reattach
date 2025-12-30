//
//  ReattachAPI.swift
//  Reattach
//

import Foundation
import Observation

enum APIError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case serverError(String)
    case decodingError(Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .unauthorized:
            return "Unauthorized - please login again"
        }
    }
}

@MainActor
@Observable
class ReattachAPI {
    static let shared = ReattachAPI()

    var isAuthenticated: Bool = false

    var baseURL: String {
        ServerConfigManager.shared.activeServer?.serverURL ?? ""
    }

    var deviceToken: String? {
        ServerConfigManager.shared.activeServer?.deviceToken
    }

    var isConfigured: Bool {
        ServerConfigManager.shared.isConfigured
    }

    var isDemoMode: Bool {
        !isConfigured
    }

    private let session: URLSession
    private var demoInputHistory: [String: [String]] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = .shared
        self.session = URLSession(configuration: config)
    }

    func listSessions() async throws -> [Session] {
        if isDemoMode {
            return Self.demoSessions
        }
        let data = try await request(path: "/sessions", method: "GET")
        return try JSONDecoder().decode([Session].self, from: data)
    }

    func createSession(name: String, cwd: String) async throws {
        if isDemoMode { return }
        let body = CreateSessionRequest(name: name, cwd: cwd)
        _ = try await request(path: "/sessions", method: "POST", body: body)
    }

    func sendInput(target: String, text: String) async throws {
        if isDemoMode {
            var history = demoInputHistory[target] ?? []
            history.append(text)
            demoInputHistory[target] = history
            return
        }
        let body = SendInputRequest(text: text)
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)/input", method: "POST", body: body)
    }

    func sendEscape(target: String) async throws {
        if isDemoMode { return }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)/escape", method: "POST")
    }

    func getOutput(target: String, lines: Int = 200) async throws -> String {
        if isDemoMode {
            let baseOutput = Self.demoOutput(for: target)
            let history = demoInputHistory[target] ?? []
            if history.isEmpty {
                return baseOutput
            }
            return baseOutput + Self.demoResponse(for: history)
        }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        let data = try await request(path: "/panes/\(encodedTarget)/output?lines=\(lines)", method: "GET")
        let response = try JSONDecoder().decode(OutputResponse.self, from: data)
        return response.output
    }

    func deletePane(target: String) async throws {
        if isDemoMode { return }
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)", method: "DELETE")
    }

    func registerDevice(token: String, sandbox: Bool) async throws {
        let body = RegisterDeviceRequest(token: token, sandbox: sandbox)
        _ = try await request(path: "/devices", method: "POST", body: body)
    }

    func registerAPNsDevice(token: String) async throws {
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        try await registerDevice(token: token, sandbox: sandbox)
    }

    private func request<T: Encodable>(path: String, method: String, body: T? = nil) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = deviceToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.networkError(NSError(domain: "Invalid response", code: 0))
            }

            switch httpResponse.statusCode {
            case 200...299:
                if data.isEmpty {
                    isAuthenticated = true
                    return data
                }
                if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                   contentType.contains("application/json") {
                    isAuthenticated = true
                    return data
                } else if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                          contentType.contains("text/html") {
                    isAuthenticated = false
                    throw APIError.unauthorized
                } else {
                    isAuthenticated = true
                    return data
                }
            case 302, 303, 307, 308:
                isAuthenticated = false
                throw APIError.unauthorized
            case 401, 403:
                isAuthenticated = false
                throw APIError.unauthorized
            default:
                if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                    throw APIError.serverError(errorResponse.error)
                }
                throw APIError.serverError("HTTP \(httpResponse.statusCode)")
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func request(path: String, method: String) async throws -> Data {
        let empty: String? = nil
        return try await request(path: path, method: method, body: empty)
    }
}

// MARK: - Demo Mode Data
extension ReattachAPI {
    static let demoSessions: [Session] = [
        Session(
            name: "myproject",
            attached: true,
            windows: [
                Window(
                    index: 0,
                    name: "main",
                    active: true,
                    panes: [
                        Pane(index: 0, active: true, target: "myproject:0.0", currentPath: "/Users/demo/projects/myproject")
                    ]
                )
            ]
        ),
        Session(
            name: "claude-demo",
            attached: false,
            windows: [
                Window(
                    index: 0,
                    name: "claude",
                    active: true,
                    panes: [
                        Pane(index: 0, active: true, target: "claude-demo:0.0", currentPath: "/Users/demo/projects/webapp")
                    ]
                )
            ]
        )
    ]

    static func demoOutput(for target: String) -> String {
        if target.contains("claude") {
            return """
╭────────────────────────────────────────────────────────────────────╮
│ ● Claude Code                                                      │
╰────────────────────────────────────────────────────────────────────╯

> Help me refactor the authentication module

I'll help you refactor the authentication module. Let me first examine the
current implementation.

⏺ Read src/auth/mod.rs
⏺ Read src/auth/jwt.rs
⏺ Read src/auth/session.rs

I've analyzed the authentication module. Here's my refactoring plan:

1. Extract common validation logic into a shared trait
2. Implement proper error handling with custom error types
3. Add refresh token support

Would you like me to proceed with these changes?

"""
        } else {
            return """
$ ls -la
total 24
drwxr-xr-x   8 demo  staff   256 Dec 30 10:00 .
drwxr-xr-x  12 demo  staff   384 Dec 30 09:00 ..
-rw-r--r--   1 demo  staff   220 Dec 30 10:00 Cargo.toml
drwxr-xr-x   4 demo  staff   128 Dec 30 10:00 src
-rw-r--r--   1 demo  staff  1024 Dec 30 10:00 README.md

$ _
"""
        }
    }

    static func demoResponse(for inputs: [String]) -> String {
        var response = "\n"
        for input in inputs {
            response += "> \(input)\n\n"
            response += demoReply(for: input)
            response += "\n"
        }
        return response
    }

    private static func demoReply(for input: String) -> String {
        let lowercased = input.lowercased()

        if lowercased.contains("hello") || lowercased.contains("hi") {
            return "Hello! How can I help you today?\n"
        }
        if lowercased.contains("help") {
            return """
Available commands:
  - help: Show this message
  - status: Check system status
  - list: List files in current directory

"""
        }
        if lowercased.contains("status") {
            return """
System Status: OK
  CPU: 12%
  Memory: 4.2GB / 16GB
  Uptime: 3 days, 14 hours

"""
        }
        if lowercased.contains("list") || lowercased.contains("ls") {
            return """
Cargo.toml  README.md  src/  tests/

"""
        }
        if lowercased.contains("yes") || lowercased.contains("y") {
            return "Great! Proceeding with the changes...\n"
        }
        if lowercased.contains("no") || lowercased.contains("n") {
            return "Okay, let me know if you need anything else.\n"
        }

        return "I received your input: \"\(input)\"\n"
    }
}

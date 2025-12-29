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

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = .shared
        self.session = URLSession(configuration: config)
    }

    func listSessions() async throws -> [Session] {
        let data = try await request(path: "/sessions", method: "GET")
        return try JSONDecoder().decode([Session].self, from: data)
    }

    func createSession(name: String, cwd: String) async throws {
        let body = CreateSessionRequest(name: name, cwd: cwd)
        _ = try await request(path: "/sessions", method: "POST", body: body)
    }

    func sendInput(target: String, text: String) async throws {
        let body = SendInputRequest(text: text)
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)/input", method: "POST", body: body)
    }

    func sendEscape(target: String) async throws {
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)/escape", method: "POST")
    }

    func getOutput(target: String, lines: Int = 200) async throws -> String {
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        let data = try await request(path: "/panes/\(encodedTarget)/output?lines=\(lines)", method: "GET")
        let response = try JSONDecoder().decode(OutputResponse.self, from: data)
        return response.output
    }

    func deletePane(target: String) async throws {
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        _ = try await request(path: "/panes/\(encodedTarget)", method: "DELETE")
    }

    func registerDevice(token: String) async throws {
        let body = ["token": token]
        _ = try await request(path: "/devices", method: "POST", body: body)
    }

    func registerAPNsDevice(token: String) async throws {
        try await registerDevice(token: token)
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

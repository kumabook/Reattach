import Foundation
import Security

struct Connection {
    var address: String
    var port: Int
    var token: String
    var accessClientID = ""
    var accessClientSecret = ""
    var session: URLSession = .shared

    static let accessClientIDSuffix = "#cf-access-client-id"
    static let accessClientSecretSuffix = "#cf-access-client-secret"

    mutating func loadCredentials() throws {
        let account = try baseURL.absoluteString
        token = try CredentialStore.read(account)
        accessClientID = try CredentialStore.read(account + Self.accessClientIDSuffix)
        accessClientSecret = try CredentialStore.read(account + Self.accessClientSecretSuffix)
    }

    func saveCredentials() throws {
        let account = try baseURL.absoluteString
        try CredentialStore.save(token, account: account)
        try CredentialStore.save(accessClientID, account: account + Self.accessClientIDSuffix)
        try CredentialStore.save(accessClientSecret, account: account + Self.accessClientSecretSuffix)
    }

    var baseURL: URL {
        get throws {
            guard var parts = URLComponents(string: address),
                  ["http", "https"].contains(parts.scheme),
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/", (1...65535).contains(port) else {
                throw ClientError.message(String(localized: "Enter an address such as http://127.0.0.1 and a port from 1 to 65535."))
            }
            parts.port = port
            parts.path = ""
            guard let url = parts.url else { throw ClientError.message(String(localized: "Invalid server address.")) }
            return url
        }
    }

    func request(_ path: [String], method: String = "GET", body: [String: String]? = nil) async throws -> Data {
        var url = try baseURL
        for component in path { url.appendPathComponent(component) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !accessClientID.isEmpty, !accessClientSecret.isEmpty {
            request.setValue(accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.message(String(localized: "Invalid server response.")) }
        // Without valid service credentials, Access redirects to its sign-in page or answers 403.
        if http.url?.host?.hasSuffix("cloudflareaccess.com") == true
            || (http.statusCode == 403 && http.value(forHTTPHeaderField: "CF-RAY") != nil) {
            throw ClientError.message(String(localized: "Cloudflare Access blocked the request. Check the Client ID and Client Secret."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.message(http.statusCode == 401
                ? String(localized: "Authentication failed. Register with a setup token in Settings.")
                : String(localized: "Server error (\(http.statusCode))"))
        }
        return data
    }

    func entries() async throws -> [PermissionAttention] {
        try JSONDecoder().decode([PermissionAttention].self, from: await request(["attention"]))
    }

    func output(_ target: String) async throws -> String {
        struct Output: Decodable { let output: String }
        return try JSONDecoder().decode(Output.self, from: await request(["panes", target, "output"])).output
    }
}

/// A pairing link from `reattachd init` / `reattachd setup`: either the printed
/// `https://host:port?setup_token=…` URL or `reattach-mac://pair?server=…&setup_token=…`.
struct SetupLink: Equatable {
    static let scheme = "reattach-mac"

    let address: String
    let port: Int
    let token: String

    init?(_ text: String) {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let token = components.queryItems?.first(where: { $0.name == "setup_token" })?.value,
              !token.isEmpty else { return nil }
        let server: URLComponents?
        if components.scheme == Self.scheme {
            server = components.queryItems?.first(where: { $0.name == "server" })?.value.flatMap(URLComponents.init(string:))
        } else {
            server = components
        }
        guard let server, let scheme = server.scheme, ["http", "https"].contains(scheme),
              let host = server.host, !host.isEmpty else { return nil }
        address = "\(scheme)://\(host)"
        port = server.port ?? (scheme == "https" ? 443 : 80)
        self.token = token
    }
}

extension Connection {
    /// Registers this Mac with a setup token and returns the connection holding its device token.
    func registering(setupToken: String) async throws -> Connection {
        struct Registration: Decodable { let device_token: String }
        var registered = self
        registered.token = ""
        let data = try await registered.request(["register"], method: "POST",
                                                body: ["setup_token": setupToken, "device_name": "Reattach Mac"])
        registered.token = try JSONDecoder().decode(Registration.self, from: data).device_token
        return registered
    }

    func saveAsCurrent() throws {
        try saveCredentials()
        UserDefaults.standard.set(address, forKey: "serverAddress")
        UserDefaults.standard.set(port, forKey: "serverPort")
    }
}

enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum CredentialStore {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tokyo.kumabook.reattach.mac.connection",
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw ClientError.message(String(localized: "Could not read Keychain (\(status))."))
        }
        return value
    }

    static func save(_ token: String, account: String) throws {
        let query = query(account)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ClientError.message(String(localized: "Could not save to Keychain (\(status))."))
            }
            return
        }
        let values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientError.message(String(localized: "Could not save to Keychain (\(status)).")) }
    }
}

// The shared permission parser only needs plain terminal text on macOS.
enum TerminalTextRenderer {
    static func render(_ text: String) -> NSAttributedString {
        let pattern = "\u{1B}\\][^\u{7}\u{1B}]*(?:\u{7}|\u{1B}\\\\)|\u{1B}\\[[0-?]*[ -/]*[@-~]"
        return NSAttributedString(string: text.replacingOccurrences(of: pattern, with: "", options: .regularExpression))
    }
}

import Foundation
import Testing
@testable import Reattach

@MainActor @Suite(.serialized)
struct PermissionWidgetTests {
    private let connection = PermissionWidgetConnection(serverID: "server-A", serverName: "Work",
        serverURL: "https://example.invalid/api", token: "test-token", accessClientID: nil, accessClientSecret: nil)

    @Test func linksRoundTripAndRejectOtherActions() throws {
        let snapshot = PermissionWidgetSnapshot(serverID: "a:b / c", serverName: "Work", requests: [], updatedAt: nil, unavailable: false)
        #expect(PermissionWidgetDestination(url: snapshot.url)?.serverID == snapshot.serverID)
        for raw in ["https://permissions", "reattach://permissions/send", "reattach://permissions?token=secret",
                    "reattach://permissions?server=a&server=b", "reattach://permissions?server="] {
            #expect(PermissionWidgetDestination(url: try #require(URL(string: raw))) == nil)
        }
    }

    @Test func refreshFailurePreservesLastKnownRequestsAndTime() {
        let original = PermissionWidgetSnapshot(serverID: "A", serverName: "Work",
            requests: [.init(target: "work:0.0", title: "Project", tool: "Codex")], updatedAt: Date(timeIntervalSince1970: 100), unavailable: false)
        let failed = original.failed()
        #expect(failed.unavailable)
        #expect(failed.requests == original.requests)
        #expect(failed.updatedAt == original.updatedAt)
    }

    @Test func widgetRequestsAreReadOnlyAndKeepBasePath() throws {
        let request = try connection.request(path: "attention")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://example.invalid/api/attention")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(throws: URLError.self) { try connection.request(path: "input") }
        let invalid = PermissionWidgetConnection(serverID: "a", serverName: "a", serverURL: "https://user:pass@example.invalid", token: "x", accessClientID: nil, accessClientSecret: nil)
        #expect(throws: URLError.self) { try invalid.request(path: "attention") }
    }

    @Test func fetchUsesFolderNamesAndDeduplicatesRequests() async throws {
        WidgetURLProtocol.response = { request in
            if request.url!.lastPathComponent == "attention" {
                return (200, #"[{"target":"work:0.0","tool":"Codex"},{"target":"work:0.0","tool":"Codex"}]"#)
            }
            return (200, #"[{"windows":[{"name":"editor","panes":[{"target":"work:0.0","current_path":"/projects/Example"}]}]}]"#)
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let snapshot = try await PermissionWidgetLoader.fetch(connection, previous: .empty, session: session)
        #expect(snapshot.requests.count == 1)
        #expect(snapshot.requests.first?.title == "Example")
        #expect(snapshot.serverID == "server-A")
        #expect(snapshot.updatedAt != nil)
    }

    @Test func unauthorizedDoesNotBecomeAnEmptySuccess() async {
        WidgetURLProtocol.response = { _ in (401, "[]") }
        let session = session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: URLError.self) {
            try await PermissionWidgetLoader.fetch(connection, previous: .empty, session: session)
        }
    }

    @Test func widgetPushRegistrationIsAuthenticatedAndSeparateFromAlerts() throws {
        let request = try PermissionWidgetPush.registrationRequest(connection: connection, token: "abc", sandbox: true, enabled: true)
        #expect(request.url?.absoluteString == "https://example.invalid/api/widget-devices")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["sandbox"] as? Bool == true)
        #expect(body["enabled"] as? Bool == true)
        #expect(body["device_id"] == nil)
    }

    @Test func pushEnvironmentUsesSigningProfileIncludingReleaseDevelopmentBuilds() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["aps-environment": "development"]], format: .xml, options: 0)
        #expect(PushNotificationEnvironment.isSandbox(profile: Data([0, 1, 2]) + xml + Data([0, 1])))
        let production = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["aps-environment": "production"]], format: .xml, options: 0)
        #expect(!PushNotificationEnvironment.isSandbox(profile: production))
        #expect(!PushNotificationEnvironment.isSandbox(profile: nil))
    }

    @Test func unreadCountsAreIndependentOfPermissionRequestsAndPreservedOnFailure() async throws {
        WidgetURLProtocol.response = { request in
            if request.url?.lastPathComponent == "activity" {
                return (200, "[{\"target\":\"s:0.0\",\"unread\":true},{\"target\":\"s:1.0\",\"unread\":false}]")
            }
            return (200, "[]")
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let loaded = try await PermissionWidgetLoader.fetch(connection, previous: .empty, session: session)
        #expect(loaded.requests.isEmpty)
        #expect(loaded.updatedPanes == ["s:0.0"])
        #expect(loaded.updatesUnavailable == false)
        WidgetURLProtocol.response = { request in (request.url?.lastPathComponent == "activity" ? 503 : 200, "[]") }
        let failed = try await PermissionWidgetLoader.fetch(connection, previous: loaded, session: session)
        #expect(failed.updatedPanes == loaded.updatedPanes)
        #expect(failed.updatesUnavailable == true)
        var other = loaded
        other.serverID = "server-B"
        let combined = PermissionWidgetStore.aggregate([loaded, other])
        #expect(combined.updatedPanes?.count == 2)
        #expect(Set(combined.updatedPanes ?? []).count == 2)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WidgetURLProtocol.self]
        return URLSession(configuration: config)
    }
}

nonisolated private final class WidgetURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.response!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

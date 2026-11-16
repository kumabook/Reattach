import Foundation
import Testing
@testable import Reattach

@MainActor @Suite(.serialized)
struct GlobalPermissionTests {
    private func server(_ id: String) -> ServerConfig {
        .init(serverURL: "https://\(id).invalid", deviceToken: "token-\(id)", deviceId: id,
              deviceName: "Phone", serverName: id, registeredAt: Date(timeIntervalSince1970: 0))
    }
    private var request: PermissionAttention { .init(target: "work:0.0", tool: "Codex", receivedAt: 1) }

    @Test func sameTargetOnDifferentServersStaysSeparateAndFailurePreservesRequests() {
        let status = PermissionStatus()
        let a = server("a"), b = server("b")
        status.configure(servers: [a, b])
        status.apply([request], server: a)
        status.apply([request], server: b)
        #expect(status.entries.count == 2)
        #expect(Set(status.entries.map(\.id)).count == 2)
        status.apply(nil, server: a)
        #expect(status.entries.count == 2)
        #expect(status.unavailableServers == ["a": "a"])
        status.apply([], server: b)
        #expect(status.entries.map(\.serverID) == ["a"])
        status.apply([], server: a)
        #expect(status.entries.isEmpty)
        #expect(status.unavailableServers.isEmpty)
    }

    @Test func removedOrReconfiguredServersCannotPublishLateResults() {
        let status = PermissionStatus()
        let a = server("a"), b = server("b")
        status.configure(servers: [a, b])
        status.apply([request], server: a)
        status.apply([request], server: b)
        var updated = b
        updated.deviceToken = "rotated"
        status.configure(servers: [updated])
        status.apply([request], server: a)
        status.apply([request], server: b)
        #expect(status.entries.isEmpty)
        status.apply([request], server: updated)
        #expect(status.entries.map(\.serverID) == ["b"])
    }

    @Test func titleChangesDoNotReopenDismissedRequestButOtherServersDo() {
        var policy = PermissionInboxAutoPresentation()
        var a = request
        a.serverID = "a"
        let first = policy.update(entries: [a], serverID: "all", enabled: true, visible: false, blocked: false)
        #expect(first)
        a.title = "Loaded folder name"
        let renamed = policy.update(entries: [a], serverID: "all", enabled: true, visible: false, blocked: false)
        #expect(!renamed)
        var b = a
        b.serverID = "b"
        let otherServer = policy.update(entries: [a, b], serverID: "all", enabled: true, visible: false, blocked: false)
        #expect(otherServer)
    }

    @Test func widgetAggregationIncludesSourceAndDoesNotTurnFailureIntoZero() {
        let a = PermissionWidgetSnapshot(serverID: "a", serverName: "A", requests: [.init(target: "0:0.0", title: "Project", tool: "Codex")], updatedAt: Date(), unavailable: false)
        var b = a
        b.serverID = "b"
        b.serverName = "B"
        b.unavailable = true
        let aggregate = PermissionWidgetStore.aggregate([a, b])
        #expect(aggregate.requests.count == 2)
        #expect(Set(aggregate.requests.map(\.id)).count == 2)
        #expect(aggregate.unavailableServers == ["B"])
        #expect(aggregate.unavailable)
        #expect(aggregate.url.absoluteString == "reattach://permissions")
    }

    @Test func normalPushRegistrationUsesSigningEnvironmentAndExplicitServer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PermissionRoutingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        PermissionRoutingProtocol.clear()
        try await ReattachAPI(server: server("b"), session: session).registerAPNsDevice(token: "test-push-token")
        let request = try #require(PermissionRoutingProtocol.requests().first)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.url?.absoluteString == "https://b.invalid/devices")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-b")
        #expect(body["notification_mode"] as? String == PushNotificationPreference.current.rawValue)
        #expect(body["sandbox"] as? Bool == PushNotificationEnvironment.currentSandbox)
        #expect(body["device_id"] as? String == "b")
        #expect(body["token"] as? String == "test-push-token")
    }

    @Test func replyClientsUseTheirOwnServerAndCredentials() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PermissionRoutingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        PermissionRoutingProtocol.clear()
        let a = ReattachAPI(server: server("a"), session: session)
        let b = ReattachAPI(server: server("b"), session: session)
        let selected = ServerConfigManager.shared.activeServerId
        try await a.sendInput(target: "work:0.0", text: "1")
        try await b.sendInput(target: "work:0.0", text: "2")
        let requests = PermissionRoutingProtocol.requests()
        #expect(requests.count == 2)
        #expect(requests[0].url?.host == "a.invalid")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer token-a")
        #expect(requests[1].url?.host == "b.invalid")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token-b")
        #expect(ServerConfigManager.shared.activeServerId == selected)
    }
}

nonisolated private final class PermissionRoutingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static func clear() { lock.lock(); defer { lock.unlock() }; recorded = [] }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.lock.lock(); Self.recorded.append(captured); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        let body = captured.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let response = request.url?.path == "/devices" ? ["notification_mode": body?["notification_mode"] as? String ?? "all"] : [:]
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

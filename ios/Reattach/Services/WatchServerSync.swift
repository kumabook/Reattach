import Foundation
import WatchConnectivity

/// Gives the companion watch app the server connections so it can answer
/// permission requests directly instead of relaying through this app.
final class WatchServerSync: NSObject, WCSessionDelegate {
    static let shared = WatchServerSync()
    static let contextKey = "connections"

    private var latest: [PermissionWidgetConnection] = []

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func update(_ connections: [PermissionWidgetConnection]) {
        latest = connections
        send()
    }

    private func send() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(latest) else { return }
        try? session.updateApplicationContext([Self.contextKey: data])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.send() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.send() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

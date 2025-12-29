//
//  ServerConfig.swift
//  Reattach
//

import Foundation
import Observation

struct ServerConfig: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    var serverURL: String
    var deviceToken: String
    var deviceId: String
    var deviceName: String
    var serverName: String  // User-friendly name for the server
    var registeredAt: Date
}

@MainActor
@Observable
class ServerConfigManager {
    static let shared = ServerConfigManager()

    var servers: [ServerConfig] = []
    var activeServerId: String?
    var isDemoMode: Bool = false

    var activeServer: ServerConfig? {
        guard let id = activeServerId else { return servers.first }
        return servers.first { $0.id == id }
    }

    var isConfigured: Bool {
        isDemoMode || !servers.isEmpty
    }

    func enableDemoMode() {
        isDemoMode = true
        userDefaults.set(true, forKey: demoModeKey)
    }

    func disableDemoMode() {
        isDemoMode = false
        userDefaults.removeObject(forKey: demoModeKey)
    }

    private let userDefaults = UserDefaults.standard
    private let serversKey = "servers_config"
    private let activeServerKey = "active_server_id"
    private let demoModeKey = "demo_mode"

    private init() {
        loadConfig()
    }

    func loadConfig() {
        if let data = userDefaults.data(forKey: serversKey),
           let servers = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            self.servers = servers
        }
        self.activeServerId = userDefaults.string(forKey: activeServerKey)
        self.isDemoMode = userDefaults.bool(forKey: demoModeKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            userDefaults.set(data, forKey: serversKey)
        }
        userDefaults.set(activeServerId, forKey: activeServerKey)
    }

    func addServer(_ config: ServerConfig) {
        // Remove existing config with same deviceId if exists
        servers.removeAll { $0.deviceId == config.deviceId }
        servers.append(config)

        // Set as active if it's the first server
        if activeServerId == nil {
            activeServerId = config.deviceId
        }
        save()
    }

    func removeServer(_ serverId: String) {
        servers.removeAll { $0.id == serverId }
        if activeServerId == serverId {
            activeServerId = servers.first?.id
        }
        save()
    }

    func setActiveServer(_ serverId: String) {
        guard servers.contains(where: { $0.id == serverId }) else { return }
        activeServerId = serverId
        save()
    }

    func clearAll() {
        servers = []
        activeServerId = nil
        userDefaults.removeObject(forKey: serversKey)
        userDefaults.removeObject(forKey: activeServerKey)
    }
}

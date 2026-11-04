//
//  ServerListView.swift
//  Reattach
//

import SwiftUI

struct ServerListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configManager = ServerConfigManager.shared
    @State private var purchaseManager = PurchaseManager.shared
    @State private var showQRScanner = false
    @State private var showUpgrade = false
    @State private var serverCountOnOpen = 0

    var body: some View {
        NavigationStack {
            List {
                if configManager.isDemoMode {
                    demoModeSection
                }
                serversSection
                addServerSection
                #if DEBUG
                debugSection
                #endif
                versionSection
            }
            .navigationTitle(String(localized: "Servers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView()
                    .onDisappear {
                        if configManager.servers.count > serverCountOnOpen {
                            dismiss()
                        }
                    }
            }
            .sheet(isPresented: $showUpgrade) {
                UpgradeView()
            }
        }
    }

    private var demoModeSection: some View {
        Section {
            HStack {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.orange)
                Text(String(localized: "Demo Mode"))
                Spacer()
                Button(String(localized: "Exit")) {
                    configManager.disableDemoMode()
                    if configManager.servers.isEmpty {
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
            }
            Button {
                showUpgrade = true
            } label: {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(String(localized: "View Pro Features"))
                        .foregroundStyle(.primary)
                }
            }
        } footer: {
            Text(String(localized: "You're viewing demo data. Exit to connect to a real server."))
        }
    }

    @ViewBuilder
    private var serversSection: some View {
        if !configManager.servers.isEmpty {
            Section {
                ForEach(configManager.servers) { server in
                    serverRow(server)
                }
            } header: {
                Text(String(localized: "Servers"))
            }
        }
    }

    private func serverRow(_ server: ServerConfig) -> some View {
        let isSelected = server.id == configManager.activeServerId
        return HStack {
            VStack(alignment: .leading) {
                Text(server.serverName)
                    .font(.body)
                Text(server.serverURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
                    .fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            configManager.setActiveServer(server.id)
            dismiss()
        }
        .swipeActions(edge: .trailing) {
            NavigationLink {
                ServerDetailView(server: server)
            } label: {
                Label(String(localized: "Settings"), systemImage: "gearshape")
            }
            .tint(.gray)
        }
        .contextMenu {
            NavigationLink {
                ServerDetailView(server: server)
            } label: {
                Label(String(localized: "Settings"), systemImage: "gearshape")
            }
        }
    }

    private var addServerSection: some View {
        Section {
            Button {
                if configManager.canAddServer {
                    serverCountOnOpen = configManager.servers.count
                    showQRScanner = true
                } else {
                    showUpgrade = true
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                    Text(String(localized: "Add Server"))
                        .foregroundStyle(.blue)
                    if !configManager.canAddServer {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            if !purchaseManager.isPro {
                Text(String(localized: "Free: \(configManager.servers.count)/\(PurchaseManager.freeServerLimit) servers"))
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Toggle(String(localized: "Simulate Free Mode"), isOn: $purchaseManager.debugSimulateFreeMode)
        } header: {
            Text(String(localized: "Debug"))
        }
    }
    #endif

    private var versionSection: some View {
        Section {
        } footer: {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? String(localized: "Unknown")
            Text(String(localized: "Version \(version) (\(build))"))
                .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    ServerListView()
}

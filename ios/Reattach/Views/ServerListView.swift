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
    @State private var serverToDelete: ServerConfig?

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
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView()
            }
            .sheet(isPresented: $showUpgrade) {
                UpgradeView()
            }
            .confirmationDialog(
                "Delete Server",
                isPresented: Binding(
                    get: { serverToDelete != nil },
                    set: { if !$0 { serverToDelete = nil } }
                ),
                presenting: serverToDelete
            ) { server in
                Button("Delete", role: .destructive) {
                    configManager.removeServer(server.id)
                    serverToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    serverToDelete = nil
                }
            } message: { server in
                Text("Remove \(server.serverName)?")
            }
        }
    }

    private var demoModeSection: some View {
        Section {
            HStack {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.orange)
                Text("Demo Mode")
                Spacer()
                Button("Exit") {
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
                    Text("View Pro Features")
                        .foregroundStyle(.primary)
                }
            }
        } footer: {
            Text("You're viewing demo data. Exit to connect to a real server.")
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
                Text("Servers")
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                serverToDelete = server
            } label: {
                Label("Delete", systemImage: "trash")
            }
            NavigationLink {
                ServerDetailView(server: server)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .tint(.gray)
        }
    }

    private var addServerSection: some View {
        Section {
            Button {
                if configManager.canAddServer {
                    showQRScanner = true
                } else {
                    showUpgrade = true
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                    Text("Add Server")
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
                Text("Free: \(configManager.servers.count)/\(PurchaseManager.freeServerLimit) servers")
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Toggle("Simulate Free Mode", isOn: $purchaseManager.debugSimulateFreeMode)
        } header: {
            Text("Debug")
        }
    }
    #endif
}

#Preview {
    ServerListView()
}

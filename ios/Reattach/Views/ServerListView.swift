//
//  ServerListView.swift
//  Reattach
//

import SwiftUI

struct ServerListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configManager = ServerConfigManager.shared
    @State private var showQRScanner = false
    @State private var serverToDelete: ServerConfig?

    var body: some View {
        NavigationStack {
            List {
                serversSection
                addServerSection
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
        Button {
            configManager.setActiveServer(server.id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(server.serverName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(server.serverURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if server.id == configManager.activeServerId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                serverToDelete = server
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var addServerSection: some View {
        Section {
            Button {
                showQRScanner = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                    Text("Add Server")
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

#Preview {
    ServerListView()
}

//
//  ServerDetailView.swift
//  Reattach
//

import SwiftUI

struct ServerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configManager = ServerConfigManager.shared

    let server: ServerConfig

    @State private var serverName: String = ""
    @State private var cfAccessClientId: String = ""
    @State private var cfAccessClientSecret: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                LabeledContent("URL", value: server.serverURL)
                TextField("Server Name", text: $serverName)
            } header: {
                Text("Server")
            }

            Section {
                TextField("Client ID", text: $cfAccessClientId)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $cfAccessClientSecret)
                    .textContentType(.password)
            } header: {
                Text("Cloudflare Access (Optional)")
            } footer: {
                Text("Enter your Service Token credentials if using Cloudflare Access.")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete Server")
                        Spacer()
                    }
                }
            }
        }
        .confirmationDialog("Delete Server", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                configManager.removeServer(server.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \(server.serverName)?")
        }
        .navigationTitle("Server Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveChanges()
                    dismiss()
                }
            }
        }
        .onAppear {
            serverName = server.serverName
            cfAccessClientId = server.cfAccessClientId ?? ""
            cfAccessClientSecret = server.cfAccessClientSecret ?? ""
        }
    }

    private func saveChanges() {
        var updatedServer = server
        updatedServer.serverName = serverName
        updatedServer.cfAccessClientId = cfAccessClientId.isEmpty ? nil : cfAccessClientId
        updatedServer.cfAccessClientSecret = cfAccessClientSecret.isEmpty ? nil : cfAccessClientSecret
        configManager.updateServer(updatedServer)
    }
}

#Preview {
    NavigationStack {
        ServerDetailView(server: ServerConfig(
            serverURL: "https://example.com",
            deviceToken: "token",
            deviceId: "device-id",
            deviceName: "My Mac",
            serverName: "Home Server",
            registeredAt: Date()
        ))
    }
}

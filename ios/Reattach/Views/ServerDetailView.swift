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
                LabeledContent(String(localized: "Name")) {
                    TextField(String(localized: "Server Name"), text: $serverName)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(String(localized: "URL"), value: server.serverURL)
            } header: {
                Text(String(localized: "Server"))
            }

            Section {
                TextField(String(localized: "Client ID"), text: $cfAccessClientId)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                SecureField(String(localized: "Client Secret"), text: $cfAccessClientSecret)
                    .textContentType(.password)
            } header: {
                Text(String(localized: "Cloudflare Access (Optional)"))
            } footer: {
                Text(String(localized: "Enter your Service Token credentials if using Cloudflare Access."))
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text(String(localized: "Delete Server"))
                        Spacer()
                    }
                }
            }
        }
        .confirmationDialog(String(localized: "Delete Server"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) {
                configManager.removeServer(server.id)
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Are you sure you want to delete \(server.serverName)?"))
        }
        .navigationTitle(String(localized: "Server Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) {
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

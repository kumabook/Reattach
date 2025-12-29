//
//  ContentView.swift
//  Reattach
//

import SwiftUI

struct ContentView: View {
    var api = ReattachAPI.shared
    @State private var configManager = ServerConfigManager.shared
    @State private var isCheckingAuth = true

    var body: some View {
        Group {
            if !configManager.isConfigured {
                SetupView()
            } else if isCheckingAuth {
                ProgressView("Connecting...")
            } else {
                SessionListView()
            }
        }
        .task {
            if configManager.isConfigured {
                await checkAuthentication()
            }
        }
        .onChange(of: configManager.isConfigured) { _, isConfigured in
            if isConfigured {
                Task {
                    await checkAuthentication()
                }
            }
        }
    }

    private func checkAuthentication() async {
        do {
            try await withTimeout(seconds: 5) {
                _ = try await api.listSessions()
            }
            AppDelegate.shared?.registerDeviceTokenWithServer()
        } catch {
            print("Auth check failed: \(error)")
        }
        isCheckingAuth = false
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

struct SetupView: View {
    @State private var showQRScanner = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "terminal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("Reattach")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Resume your local Claude Code sessions from anywhere")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                showQRScanner = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Scan QR Code to Connect")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Text("Scan the QR code from reattachd setup")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView()
        }
    }
}

#Preview {
    ContentView()
}

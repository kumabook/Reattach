//
//  ContentView.swift
//  Reattach
//

import SwiftUI

struct ContentView: View {
    var api = ReattachAPI.shared
    @State private var configManager = ServerConfigManager.shared
    @State private var isCheckingAuth = true
    @State private var showCloudflareAuth = false
    @State private var showQRScanner = false
    @State private var showServiceTokenError = false

    var body: some View {
        Group {
            if !configManager.isConfigured {
                SetupView(onTryDemo: { configManager.enableDemoMode() })
            } else if isCheckingAuth && !configManager.isDemoMode {
                ProgressView(String(localized: "Connecting..."))
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
        .onChange(of: api.authErrorType) { _, errorType in
            guard let errorType else { return }
            switch errorType {
            case .cloudflareExpired:
                // Service Tokenが設定されている場合は自動で認証されるのでWebViewは不要
                if let server = configManager.activeServer,
                   let clientId = server.cfAccessClientId,
                   let clientSecret = server.cfAccessClientSecret,
                   !clientId.isEmpty, !clientSecret.isEmpty {
                    api.clearAuthError()
                } else {
                    showCloudflareAuth = true
                }
            case .cloudflareServiceTokenInvalid:
                showServiceTokenError = true
            case .deviceTokenInvalid:
                showQRScanner = true
            }
        }
        .fullScreenCover(isPresented: $showCloudflareAuth) {
            CloudflareAuthWebView(api: api, isPresented: $showCloudflareAuth)
                .onDisappear {
                    api.clearAuthError()
                    NotificationCenter.default.post(name: .authenticationRestored, object: nil)
                }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView()
                .onDisappear {
                    api.clearAuthError()
                    NotificationCenter.default.post(name: .authenticationRestored, object: nil)
                }
        }
        .alert(String(localized: "Service Token Error"), isPresented: $showServiceTokenError) {
            Button(String(localized: "OK")) {
                api.clearAuthError()
            }
        } message: {
            Text(String(localized: "Cloudflare Access denied. Please check your Service Token credentials in server settings."))
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
    @State private var platform = SetupPlatform.macOS
    @State private var copied = false
    var onTryDemo: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text(verbatim: "Reattach")
                        .font(.largeTitle.bold())
                    Text(String(localized: "Your tmux, from your phone."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 12) {
                    stepTitle(1, String(localized: "Run this on the computer running tmux"))
                    Picker(String(localized: "Platform"), selection: $platform) {
                        ForEach(SetupPlatform.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    commandBlock
                    Text(String(localized: "reattachd init uses Tailscale when it is installed. For Cloudflare Tunnel, add --url https://your-host."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(String(localized: "Setup guide"),
                         destination: URL(string: "https://reattach.tmux.kumabook.tokyo/setup.html")!)
                        .font(.footnote)
                }

                VStack(alignment: .leading, spacing: 12) {
                    stepTitle(2, String(localized: "Scan the QR code it shows"))
                    Button {
                        showQRScanner = true
                    } label: {
                        Label(String(localized: "Scan QR Code to Connect"), systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(String(localized: "Try Demo Mode"), action: onTryDemo)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView()
        }
    }

    private func stepTitle(_ number: Int, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number, format: .number)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.tint, in: Circle())
            Text(title).font(.headline)
        }
    }

    private var commandBlock: some View {
        HStack(alignment: .top) {
            Text(verbatim: platform.commands)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = platform.commands
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy"))
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum SetupPlatform: String, CaseIterable, Identifiable {
    case macOS, linux

    var id: Self { self }

    var title: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        }
    }

    var commands: String {
        switch self {
        case .macOS:
            "brew install kumabook/reattach/reattachd\nreattachd init"
        case .linux:
            "curl -fsSL https://raw.githubusercontent.com/kumabook/Reattach/main/install.sh | sh\nreattachd init"
        }
    }
}

#Preview("Content") {
    ContentView()
}

#Preview("Setup") {
    SetupView(onTryDemo: {})
}

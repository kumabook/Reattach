//
//  LoginView.swift
//  Reattach
//

import SwiftUI
import WebKit

struct LoginView: View {
    var api: ReattachAPI
    @State private var showWebView = false

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
                showWebView = true
            } label: {
                HStack {
                    Image(systemName: "person.badge.key.fill")
                    Text("Sign in with GitHub")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Text("Authentication is handled by Cloudflare Access")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .sheet(isPresented: $showWebView) {
            CloudflareAuthWebView(api: api, isPresented: $showWebView)
        }
    }
}

struct CloudflareAuthWebView: View {
    var api: ReattachAPI
    @Binding var isPresented: Bool
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                WebView(
                    url: URL(string: api.baseURL)!,
                    isLoading: $isLoading,
                    onAuthenticated: {
                        Task {
                            await syncCookiesAndCheck()
                        }
                    }
                )

                if isLoading {
                    ProgressView()
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }

    private func syncCookiesAndCheck() async {
        let dataStore = WKWebsiteDataStore.default()
        let cookies = await dataStore.httpCookieStore.allCookies()

        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        do {
            _ = try await api.listSessions()
            AppDelegate.shared?.registerDeviceTokenWithServer()
            isPresented = false
        } catch {
            // Not authenticated yet
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onAuthenticated: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView
        private var hasCheckedAuth = false

        init(_ parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false

            if let url = webView.url,
               url.host == URL(string: parent.url.absoluteString)?.host {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let hasCFAuth = cookies.contains { $0.name == "CF_Authorization" }
                    if hasCFAuth && !self.hasCheckedAuth {
                        self.hasCheckedAuth = true
                        self.parent.onAuthenticated()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

#Preview {
    LoginView(api: ReattachAPI.shared)
}

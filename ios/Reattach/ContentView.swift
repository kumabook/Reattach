//
//  ContentView.swift
//  Reattach
//

import SwiftUI

struct ContentView: View {
    var api = ReattachAPI.shared
    @State private var isCheckingAuth = true

    var body: some View {
        Group {
            if isCheckingAuth {
                ProgressView("Connecting...")
            } else if api.isAuthenticated {
                SessionListView()
            } else {
                LoginView(api: api)
            }
        }
        .task {
            await checkAuthentication()
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

#Preview {
    ContentView()
}

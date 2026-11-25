import SwiftUI

struct RequestListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WatchStore.shared
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Requests")
                .navigationDestination(for: String.self) { id in
                    RequestDetailView(requestID: id)
                }
        }
        .task { await store.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        .onOpenURL { url in
            if let focus = NotificationFocus(url: url) {
                store.focus = focus
                Task { await store.refresh() }
            }
        }
        .onChange(of: store.focus) { openFocus() }
        .onChange(of: store.requests) { openFocus() }
    }

    @ViewBuilder
    private var content: some View {
        if store.connections.isEmpty {
            ContentUnavailableView("No servers", systemImage: "iphone",
                                   description: Text("Open Reattach on iPhone to share its servers."))
        } else if store.requests.isEmpty && store.hasLoaded {
            ScrollView {
                ContentUnavailableView("No pending requests", systemImage: "checkmark.circle",
                                       description: unavailableText)
                Button("Refresh") { Task { await store.refresh() } }
            }
        } else {
            List {
                ForEach(store.requests) { request in
                    NavigationLink(value: request.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.target).font(.headline)
                            Text(summary(of: request))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                if !store.unavailableServers.isEmpty {
                    unavailableText.font(.footnote).foregroundStyle(.secondary)
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private var unavailableText: Text {
        store.unavailableServers.isEmpty
            ? Text("")
            : Text("Unavailable: \(store.unavailableServers.joined(separator: ", "))")
    }

    private func summary(of request: PendingRequest) -> String {
        guard let context = request.prompt?.context, !context.isEmpty else { return request.tool }
        return context.split(separator: "\n").prefix(2).joined(separator: " · ")
    }

    private func openFocus() {
        guard let focus = store.focus, let request = store.request(for: focus) else { return }
        store.focus = nil
        path = [request.id]
    }
}

import SwiftUI
import WidgetKit

struct PendingEntry: TimelineEntry {
    enum State { case noServers, loaded, unavailable }

    let date: Date
    let state: State
    let requests: [PendingRequest]

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: requests.isEmpty ? 0 : 100)
    }
}

struct PendingProvider: TimelineProvider {
    func placeholder(in context: Context) -> PendingEntry {
        let connection = WatchConnection(serverID: "", serverName: "Mac", serverURL: "", token: "",
                                         accessClientID: nil, accessClientSecret: nil)
        let prompt = PermissionPrompt(context: "Bash command\nnpm test", choices: [], digest: "")
        return PendingEntry(date: Date(), state: .loaded, requests: [
            PendingRequest(connection: connection, target: "project:0.0", tool: "Bash", receivedAt: 0, prompt: prompt),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (PendingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            Task { completion(await load()) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PendingEntry>) -> Void) {
        Task {
            // A timeline request means the widget is on a face or in the Smart Stack,
            // even if the push handler's widget list said otherwise.
            await WidgetPush.synchronize(enabled: true)
            let entry = await load()
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(15 * 60))))
        }
    }

    private func load() async -> PendingEntry {
        let connections = WatchKeychain.connections()
        guard !connections.isEmpty else { return PendingEntry(date: Date(), state: .noServers, requests: []) }
        var requests: [PendingRequest] = []
        var failed = false
        await withTaskGroup(of: [PendingRequest]?.self) { group in
            for connection in connections {
                group.addTask { try? await WatchAPI(connection: connection).pending() }
            }
            for await result in group {
                if let result { requests += result } else { failed = true }
            }
        }
        let state: PendingEntry.State = failed && requests.isEmpty ? .unavailable : .loaded
        return PendingEntry(date: Date(), state: state, requests: requests.sorted { $0.receivedAt > $1.receivedAt })
    }
}

struct PendingWidgetView: View {
    let entry: PendingEntry
    @Environment(\.widgetFamily) private var family

    private var latest: PendingRequest? { entry.requests.first }
    private var count: Int { entry.requests.count }

    var body: some View {
        content
            .widgetURL(latest.flatMap(NotificationFocus.url(for:)))
            .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: count > 0 ? "hand.raised.fill" : "terminal")
                        .font(.system(size: 13))
                    Text(countText).font(.system(.title3, design: .rounded).bold())
                }
            }
            .widgetAccentable()
        case .accessoryCorner:
            Image(systemName: count > 0 ? "hand.raised.fill" : "terminal")
                .font(.title2)
                .widgetLabel { Text(statusText) }
        case .accessoryInline:
            Label { Text(statusText) } icon: { Image(systemName: "terminal") }
        default:
            rectangular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: count > 0 ? "hand.raised.fill" : "terminal")
                Text("Reattach")
                Spacer(minLength: 0)
                if count > 0 { Text(count, format: .number).monospacedDigit() }
            }
            .font(.headline)
            .widgetAccentable()
            if let latest {
                Text(latest.target).font(.body.bold()).lineLimit(1)
                Text(summary(of: latest)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(statusText).font(.body).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countText: String {
        entry.state == .loaded ? String(count) : "–"
    }

    private var statusText: String {
        switch entry.state {
        case .noServers: return String(localized: "Open Reattach on iPhone")
        case .unavailable: return String(localized: "Server unavailable")
        case .loaded:
            return count == 0 ? String(localized: "No pending requests") : String(localized: "\(count) pending")
        }
    }

    private func summary(of request: PendingRequest) -> String {
        guard let context = request.prompt?.context, !context.isEmpty else { return request.tool }
        return context.split(separator: "\n").prefix(2).joined(separator: " · ")
    }
}

@main
struct ReattachWatchWidgets: WidgetBundle {
    var body: some Widget { compatibleWidget() }

    private func compatibleWidget() -> some Widget {
        if #available(watchOS 26.0, *) {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(PushPendingWidget()))
        } else {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(PendingWidget()))
        }
    }
}

@available(watchOS 26.0, *)
struct PushPendingWidget: Widget {
    var body: some WidgetConfiguration {
        PendingWidget().body.pushHandler(PendingPushHandler.self)
    }
}

struct PendingWidget: Widget {
    static let kind = "PendingRequests"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PendingProvider()) { entry in
            PendingWidgetView(entry: entry)
        }
        .configurationDisplayName("Pending Requests")
        .description("Permission requests waiting on your Mac.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

@available(watchOS 26.0, *)
struct PendingPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        WidgetPush.store(token: pushInfo.token, enabled: widgets.contains { $0.kind == PendingWidget.kind })
        Task { await WidgetPush.synchronize() }
    }
}

/// Lets the server refresh this widget the moment a request arrives.
enum WidgetPush {
    private static let tokenKey = "widgetPushToken"
    private static let enabledKey = "widgetPushEnabled"

    static func store(token: Data, enabled: Bool) {
        UserDefaults.standard.set(token.map { String(format: "%02x", $0) }.joined(), forKey: tokenKey)
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    static func synchronize(enabled newValue: Bool? = nil) async {
        if let newValue { UserDefaults.standard.set(newValue, forKey: enabledKey) }
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        let enabled = UserDefaults.standard.bool(forKey: enabledKey)
        await withTaskGroup(of: Void.self) { group in
            for connection in WatchKeychain.connections() {
                group.addTask {
                    // A failure is retried on the next timeline refresh.
                    try? await WatchAPI(connection: connection)
                        .registerWidget(token: token, sandbox: sandbox, enabled: enabled)
                }
            }
        }
    }

    // TestFlight and App Store builds use production APNs; Xcode installs use the sandbox.
    private static var sandbox: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url),
              let start = profile.range(of: Data("<plist".utf8)),
              let end = profile.range(of: Data("</plist>".utf8)), start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return false }
        return entitlements["aps-environment"] as? String == "development"
    }
}

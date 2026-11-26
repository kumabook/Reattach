import SwiftUI
import WidgetKit

struct PermissionEntry: TimelineEntry {
    let date: Date
    let snapshot: PermissionWidgetSnapshot
}

struct PermissionProvider: TimelineProvider {
    func placeholder(in context: Context) -> PermissionEntry {
        PermissionEntry(date: Date(), snapshot: .init(serverID: nil, serverName: "Reattach",
            requests: [.init(target: "project:0.0", title: "Project", tool: "Codex")], updatedAt: Date(), unavailable: false))
    }

    func getSnapshot(in context: Context, completion: @escaping (PermissionEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : PermissionEntry(date: Date(), snapshot: PermissionWidgetStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PermissionEntry>) -> Void) {
        Task {
            await PermissionWidgetPush.synchronize()
            let connections = PermissionWidgetStore.connections()
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.timeoutIntervalForResource = 20
            let session = URLSession(configuration: config, delegate: PermissionWidgetRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            await withTaskGroup(of: Void.self) { group in
                for connection in connections {
                    group.addTask {
                        let previous = PermissionWidgetStore.read(for: connection)
                        let snapshot: PermissionWidgetSnapshot
                        do { snapshot = try await PermissionWidgetLoader.fetch(connection, previous: previous, session: session) }
                        catch { snapshot = previous.failed() }
                        PermissionWidgetStore.publish(snapshot, for: connection, reload: false)
                    }
                }
            }
            let snapshot = PermissionWidgetStore.read()
            let now = Date()
            completion(Timeline(entries: [PermissionEntry(date: now, snapshot: snapshot)],
                                policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
}

struct PermissionWidgetView: View {
    let entry: PermissionEntry
    @Environment(\.widgetFamily) private var family
    private var snapshot: PermissionWidgetSnapshot { entry.snapshot }
    private var running: Int { snapshot.runningPanes?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Pending Requests").font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            if snapshot.updatedAt == nil {
                Spacer(minLength: 0)
                Text("No data yet").font(.headline)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Text(snapshot.requests.count, format: .number)
                        .font(.system(size: family == .systemSmall ? 36 : 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if family == .systemMedium {
                        VStack(alignment: .leading, spacing: 6) {
                            requestRows(limit: 3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if family == .systemSmall { requestRows(limit: 1) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
                if let panes = snapshot.updatedPanes {
                    Text("\(panes.count) unread panes").font(.caption.weight(.medium))
                } else {
                    Text("Unread panes: —").font(.caption).foregroundStyle(.secondary)
                }
            }
            if running > 0 {
                Label("\(running) running", systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .imageScale(.small)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
            }
            Group {
                if snapshot.updatedAt == nil {
                    Text("Open the app to connect")
                } else if snapshot.unavailable || snapshot.updatesUnavailable == true {
                    Text("Could not update")
                } else if let date = snapshot.updatedAt {
                    Text("Updated \(Text(date, style: .relative)) ago")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(snapshot.url)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Open permission requests in Reattach"))
    }

    @ViewBuilder private func requestRows(limit: Int) -> some View {
        if snapshot.requests.isEmpty {
            Text("No pending requests at last update").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.requests.prefix(limit)) { request in
                HStack(spacing: 4) {
                    Text(request.title).font(.caption.weight(.medium)).lineLimit(1)
                    if family == .systemMedium {
                        Text(request.serverName ?? request.tool).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.privacySensitive()
            }
        }
    }
}

@main
struct ReattachWidgets: WidgetBundle {
    var body: some Widget { compatibleWidget() }

    // Both branches use WidgetKit's availability wrapper so they retain one
    // stable widget kind without requiring a newer deployment target.
    private func compatibleWidget() -> some Widget {
        if #available(iOS 26.0, *) {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(PushPermissionWidget()))
        } else {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(PermissionWidget()))
        }
    }
}

@available(iOS 26.0, *)
struct PushPermissionWidget: Widget {
    var body: some WidgetConfiguration {
        PermissionWidget().body.pushHandler(PermissionPushHandler.self)
    }
}

struct PermissionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PermissionWidgetStore.kind, provider: PermissionProvider()) { entry in
            PermissionWidgetView(entry: entry)
        }
        .configurationDisplayName("Pending Requests")
        .description("See requests from all your servers. Tap to review them in Reattach.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(iOS 26.0, *)
struct PermissionPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        PermissionWidgetPush.store(token: pushInfo.token,
            enabled: widgets.contains { $0.kind == PermissionWidgetStore.kind })
        Task { await PermissionWidgetPush.synchronize() }
    }
}

import SwiftUI
import AppKit

@MainActor @Observable
final class InboxStore {
    let welcome = MacWelcomeState()
    var hasConnected = false
    var showingUnifiedRequest = false
    var entries: [PermissionAttention] = []
    var selected: String?
    private(set) var workTitles: [String: String] = [:]
    private var titleRefresh: Task<Void, Never>?
    private var titleTargets: Set<String> = []
    private var lastTitleRefresh: TimeInterval = 0
    var outputs: [String: String] = [:] {
        didSet {
            parsedChoices = outputs.mapValues(PermissionChoice.parse)
            previews = outputs.mapValues {
                TerminalTextRenderer.render($0).string.components(separatedBy: .newlines).suffix(40).joined(separator: "\n")
            }
        }
    }
    private(set) var parsedChoices: [String: [PermissionChoice]] = [:]
    private(set) var previews: [String: String] = [:]
    var drafts: [String: String] = [:]
    var sent: Set<String> = []
    var requiresReload: Set<String> = []
    var swipeOffset: CGFloat = 0
    var isSwiping = false
    var pageWidth: CGFloat = 600
    var busy = false
    var error: String?
    var responseMessage: String?
    var replyReceipt: UUID?
    var replyFeedbackDeadline: TimeInterval = 0
    var isShowingReplyFeedback: Bool { replyFeedbackRemaining() > 0 }
    func replyFeedbackRemaining(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, replyFeedbackDeadline - uptime)
    }
    var connection = Connection(address: "http://127.0.0.1", port: 8787, token: "")
    private var generation = UUID()
    private var outputReadGeneration = UUID()

    var entry: PermissionAttention? { entries.first { $0.target == selected } }
    var output: String? { selected.flatMap { outputs[$0] } }
    var choices: [PermissionChoice] { parsedChoices[selected ?? ""] ?? [] }
    var canReply: Bool { entry != nil && output != nil && !busy && !sent.contains(selected ?? "") && !requiresReload.contains(selected ?? "") && !isSwiping }

    init() { reloadConnection() }

    func reloadConnection() {
        let defaults = UserDefaults.standard
        let address = defaults.string(forKey: "serverAddress") ?? "http://127.0.0.1"
        let port = defaults.object(forKey: "serverPort") as? Int ?? 8787
        var next = Connection(address: address, port: port, token: "")
        do { next.token = try CredentialStore.read(try next.baseURL.absoluteString); error = nil }
        catch { self.error = error.localizedDescription }
        titleRefresh?.cancel()
        titleRefresh = nil; workTitles = [:]; titleTargets = []; lastTitleRefresh = 0
        hasConnected = false
        replyReceipt = nil; replyFeedbackDeadline = 0
        connection = next
        generation = UUID()
        cancelSwipe()
        entries = []; selected = nil; outputs = [:]; drafts = [:]; sent = []; busy = false; responseMessage = nil; requiresReload = []
    }

    func poll() async {
        let version = generation
        let api = connection
        do {
            let next = try await api.entries()
            guard version == generation else { return }
            if next != entries { cancelSwipe() }
            selected = PermissionPaging.selection(current: selected, old: entries.map(\.target), new: next.map(\.target))
            for old in entries where !next.contains(old) {
                outputs[old.target] = nil; drafts[old.target] = nil; sent.remove(old.target); requiresReload.remove(old.target)
            }
            entries = next
            hasConnected = true
            error = nil
        } catch {
            guard version == generation else { return }
            self.error = error.localizedDescription
            outputs = [:]
        }
    }

    func refreshWorkTitlesIfNeeded() {
        let targets = Set(entries.map(\.target))
        workTitles = workTitles.filter { targets.contains($0.key) }
        guard !targets.isEmpty, titleRefresh == nil,
              targets != titleTargets || ProcessInfo.processInfo.systemUptime - lastTitleRefresh >= 10 else { return }
        titleTargets = targets
        lastTitleRefresh = ProcessInfo.processInfo.systemUptime
        let version = generation
        let api = connection
        titleRefresh = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == version { self.titleRefresh = nil } }
            do {
                let data = try await api.request(["sessions"])
                let sessions = try JSONDecoder().decode([Session].self, from: data)
                guard !Task.isCancelled, self.generation == version else { return }
                var titles: [String: String] = [:]
                let currentTargets = Set(self.entries.map(\.target))
                for window in sessions.flatMap(\.windows) {
                    for pane in window.panes where currentTargets.contains(pane.target) {
                        let folder = pane.shortPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = window.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !folder.isEmpty && folder != "/" { titles[pane.target] = folder }
                        else if !name.isEmpty { titles[pane.target] = name }
                    }
                }
                self.workTitles = titles
            } catch {
                // Names are supplementary; never block reviewing or replying.
            }
        }
    }

    func refresh(background: Bool = false) async {
        guard let entry, !busy, !isSwiping else { return }
        if background, sent.contains(entry.target) || requiresReload.contains(entry.target) { return }
        let readVersion = UUID()
        outputReadGeneration = readVersion
        let version = generation
        let api = connection
        if !background { busy = true }
        defer { if !background, version == generation { busy = false } }
        do {
            let output = try await api.output(entry.target)
            guard !Task.isCancelled, version == generation, outputReadGeneration == readVersion, entries.contains(entry), selected == entry.target else { return }
            outputs[entry.target] = output
            // Hooks can arrive before the terminal finishes drawing its menu.
            // Retry reads briefly; never retry an input request.
            if !background, PermissionChoice.parse(output).isEmpty {
                for delay in [150, 300, 600] {
                    try await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled, version == generation, outputReadGeneration == readVersion, entries.contains(entry), selected == entry.target else { return }
                    let updated = try await api.output(entry.target)
                    guard !Task.isCancelled, version == generation, outputReadGeneration == readVersion, entries.contains(entry), selected == entry.target else { return }
                    outputs[entry.target] = updated
                    if !PermissionChoice.parse(updated).isEmpty { break }
                }
            }
            sent.remove(entry.target)
            requiresReload.remove(entry.target)
            error = nil
            if !background { responseMessage = nil }
        } catch {
            guard !Task.isCancelled, version == generation, outputReadGeneration == readVersion, entries.contains(entry), selected == entry.target else { return }
            outputs[entry.target] = nil
            self.error = error.localizedDescription
        }
    }

    private var preparedEntry: PermissionAttention?
    private var preparedOutput: String?
    var readyForAutomaticPresentation: Bool {
        entry != nil && preparedEntry == entry && preparedOutput == output && !choices.isEmpty
    }

    func prepareAutomaticPresentation() async {
        preparedEntry = nil
        preparedOutput = nil
        guard let request = entry, !sent.contains(request.target), !requiresReload.contains(request.target) else { return }
        await refresh()
        guard entry == request, !choices.isEmpty else { return }
        let previousChoices = choices
        let version = generation
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        await refresh(background: true)
        guard !Task.isCancelled, entry == request, choices == previousChoices,
              !choices.isEmpty, !busy, !sent.contains(request.target), !requiresReload.contains(request.target) else { return }
        let reviewedOutput = output
        // The user may have answered in tmux while the menu was stabilizing.
        // Recheck the canonical request list before allowing automatic display.
        await poll()
        guard !Task.isCancelled, generation == version, entry == request else { return }
        await refresh(background: true)
        guard !Task.isCancelled, generation == version, error == nil,
              entry == request, output == reviewedOutput, !choices.isEmpty else { return }
        preparedEntry = request
        preparedOutput = reviewedOutput
    }

    func move(_ step: Int) {
        guard !isSwiping else { return }
        guard let index = entries.firstIndex(where: { $0.target == selected }), entries.indices.contains(index + step) else { return }
        selected = entries[index + step].target
    }

    func updateSwipe(_ translation: CGFloat) {
        guard entries.count > 1 else {
            cancelSwipe()
            return
        }
        isSwiping = true
        let index = entries.firstIndex { $0.target == selected } ?? 0
        let atEdge = (index == 0 && translation > 0) || (index == entries.count - 1 && translation < 0)
        swipeOffset = atEdge ? translation * 0.18 : min(pageWidth, max(-pageWidth, translation))
    }

    func finishSwipe(_ translation: CGFloat, cancelled: Bool) {
        guard isSwiping else { return }
        let step = cancelled ? 0 : TrackpadPaging.step(translation: translation, width: pageWidth)
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88)) {
            isSwiping = false
            move(step)
            swipeOffset = 0
        }
    }

    func cancelSwipe() {
        isSwiping = false
        swipeOffset = 0
    }

    func prefetchNeighbors() async {
        guard let index = entries.firstIndex(where: { $0.target == selected }) else { return }
        let version = generation
        let api = connection
        for neighbor in [index - 1, index + 1] where entries.indices.contains(neighbor) {
            let entry = entries[neighbor]
            guard outputs[entry.target] == nil, !requiresReload.contains(entry.target), !sent.contains(entry.target) else { continue }
            do {
                let output = try await api.output(entry.target)
                guard !Task.isCancelled, version == generation else { return }
                if entries.contains(entry), outputs[entry.target] == nil { outputs[entry.target] = output }
            } catch { /* The selected card reports errors when it loads. */ }
        }
    }

    func selectPane() async -> Bool {
        guard !busy, !isSwiping, let entry else { return false }
        let version = generation
        let api = connection
        busy = true
        defer { if version == generation { busy = false } }
        do {
            _ = try await api.request(["panes", entry.target, "select"], method: "POST")
            guard version == generation else { return false }
            responseMessage = nil
            return true
        } catch {
            guard version == generation else { return false }
            responseMessage = String(localized: "Could not switch panes: \(error.localizedDescription)")
            return false
        }
    }

    func respond(_ text: String, escape: Bool = false) async {
        guard canReply, let entry, let reviewed = output else { return }
        outputReadGeneration = UUID()
        let version = generation
        let api = connection
        busy = true
        defer { if version == generation { busy = false } }
        do {
            let current = try await api.entries()
            guard version == generation else { return }
            guard current.contains(entry) else {
                outputs[entry.target] = nil
                throw ClientError.message(String(localized: "This request is no longer pending."))
            }
            let latest = try await api.output(entry.target)
            guard version == generation else { return }
            guard latest == reviewed else {
                outputs[entry.target] = latest
                responseMessage = String(localized: "The request changed. Review it before replying.")
                return
            }
            _ = try await api.request(["panes", entry.target, escape ? "escape" : "input"], method: "POST", body: escape ? nil : ["text": text])
            guard version == generation else { return }
            sent.insert(entry.target); drafts[entry.target] = nil
            replyFeedbackDeadline = ProcessInfo.processInfo.systemUptime + 0.9
            replyReceipt = UUID()
            error = nil
            responseMessage = nil
        } catch {
            guard version == generation else { return }
            // Never automatically retry a reply: the terminal may already have received it.
            outputs[entry.target] = nil
            requiresReload.insert(entry.target)
            self.responseMessage = error.localizedDescription
        }
    }
}

/// Keep scrolling vertical once its axis is known. Horizontal tracking does not
/// commit until fingers lift; momentum never starts another page transition.
struct TrackpadPaging {
    private var horizontal: Bool?
    private var x: CGFloat = 0
    private var y: CGFloat = 0

    mutating func update(dx: CGFloat, dy: CGFloat, began: Bool, momentum: Bool) -> (handled: Bool, translation: CGFloat) {
        if began { self = Self() }
        if momentum { return (horizontal == true, x) }
        x += dx
        y += dy
        if horizontal == nil, max(abs(x), abs(y)) >= 6 {
            horizontal = abs(x) > abs(y) * 1.3
        }
        return (horizontal == true, x)
    }

    static func step(translation: CGFloat, width: CGFloat) -> Int {
        guard width > 0, abs(translation) >= min(120, width * 0.18) else { return 0 }
        return translation < 0 ? 1 : -1
    }
}

struct InboxPresentationPolicy {
    enum Action { case none, show, close }
    private var previous: [PermissionAttention] = []
    private var server: String?

    mutating func update(entries: [PermissionAttention], server: String, succeeded: Bool,
                         visible: Bool, blocked: Bool, autoShow: Bool, autoClose: Bool) -> Action {
        guard succeeded, !blocked else { return .none }
        if self.server != server {
            previous = []
            self.server = server
        }
        let hasNewRequest = entries.contains { !previous.contains($0) }
        let becameEmpty = !previous.isEmpty && entries.isEmpty
        previous = entries
        if autoClose && visible && becameEmpty { return .close }
        if autoShow && !visible && hasNewRequest { return .show }
        return .none
    }
}

// Preserve the existing automatic-panel preference on first use.
enum RequestPresentation: String {
    case none, notification, panel

    static func current(_ defaults: UserDefaults = .standard) -> Self {
        if let value = defaults.string(forKey: "requestPresentation"), let mode = Self(rawValue: value) { return mode }
        return defaults.bool(forKey: "autoShowPermissionPanel") ? .panel : .none
    }
}

struct InboxNotificationPolicy {
    private struct Request: Codable, Equatable {
        let target: String
        let tool: String
        let receivedAt: Int64
        init(_ entry: PermissionAttention) {
            target = entry.target; tool = entry.tool; receivedAt = entry.receivedAt
        }
    }
    private var observed: [String: [Request]] = [:]
    private let defaults: UserDefaults?
    private static let storageKey = "observedNotificationRequests"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: [Request]].self, from: data) { observed = saved }
    }

    mutating func update(entries: [PermissionAttention], server: String, succeeded: Bool) -> [PermissionAttention] {
        guard succeeded else { return [] }
        let previous = observed[server] ?? []
        let current = entries.map(Request.init)
        let fresh = entries.filter { !previous.contains(Request($0)) }
        if observed[server] != current {
            observed[server] = current
            if let data = try? JSONEncoder().encode(observed) { defaults?.set(data, forKey: Self.storageKey) }
        }
        return fresh
    }
}


@MainActor @Observable
final class MacWelcomeState {
    var active = false
    var step = 0
    var panelHidden = false
    private(set) var waitingForHotkey = false

    func start(connected: Bool) {
        active = true
        step = connected ? 1 : 0
        panelHidden = false
        waitingForHotkey = false
    }

    func connectionSucceeded() {
        if active && step == 0 { step = 1 }
    }

    func panelWillToggle(visible: Bool, fromHotkey: Bool) {
        guard active else { return }
        panelHidden = visible
        if step == 1 {
            if visible { waitingForHotkey = fromHotkey }
            else {
                if fromHotkey && waitingForHotkey { step = 2 }
                waitingForHotkey = false
            }
        }
    }

    func finish() { active = false; waitingForHotkey = false }
}

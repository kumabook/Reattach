import Foundation
import CoreGraphics

final class StubProtocol: URLProtocol {
    static var respond: (URLRequest) -> (Int, String) = { _ in (500, "") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct RegressionTests {
    @MainActor static func main() async throws {
        let toolPrompt = """
        Field 1/1
        Allow Vercel to run tool "vercel.update_project"?
        requestBody: {"nodeVersion":"22.x"}
        › 1. Allow                     Run the tool and continue
          2. Allow for this session    Run the tool and remember this choice for this session
          3. Always allow              Run the tool and remember this choice for future tool calls
          4. Cancel                    Cancel this tool call
          enter to submit | esc to cancel
        """
        let toolChoices = PermissionChoice.parse(toolPrompt)
        precondition(toolChoices.count == 4 && toolChoices.first?.selected == true)
        precondition(toolChoices.last?.label == "Cancel                    Cancel this tool call")
        let welcome = MacWelcomeState()
        welcome.start(connected: false)
        precondition(welcome.step == 0)
        welcome.connectionSucceeded()
        precondition(welcome.step == 1)
        welcome.panelWillToggle(visible: true, fromHotkey: true)
        precondition(welcome.waitingForHotkey && welcome.panelHidden)
        welcome.panelWillToggle(visible: false, fromHotkey: false)
        precondition(welcome.step == 1, "Menu reopening must not complete hotkey practice")
        welcome.panelWillToggle(visible: true, fromHotkey: true)
        welcome.panelWillToggle(visible: false, fromHotkey: true)
        precondition(welcome.step == 2 && !welcome.panelHidden)
        welcome.finish()
        precondition(!welcome.active)
        welcome.start(connected: true)
        precondition(welcome.step == 1, "Existing connections skip setup")
        var placement = PanelLayout()
        placement.width = 0.6; placement.height = 0.8
        placement.horizontal = 0.5; placement.vertical = 0.5
        let screen = CGRect(x: -2000, y: 100, width: 1600, height: 1000)
        let centered = placement.frame(in: screen)
        precondition(centered.width == 960 && centered.height == 800)
        precondition(centered.midX == screen.midX && centered.midY == screen.midY)
        placement.horizontal = 1; placement.vertical = 1
        let bottomRight = placement.frame(in: screen)
        precondition(bottomRight.maxX == screen.maxX && bottomRight.minY == screen.minY)
        placement.horizontal = 0; placement.vertical = 0
        let topLeft = placement.frame(in: screen)
        precondition(topLeft.minX == screen.minX && topLeft.maxY == screen.maxY)
        placement.width = 2; placement.height = 2
        precondition(placement.frame(in: screen) == screen)
        precondition(placement.frame(in: CGRect(x: 0, y: 0, width: 400, height: 400)).size == CGSize(width: 400, height: 400))
        let suite = "Reattach-layout-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let manuallyPlaced = CGRect(x: -1740, y: 220, width: 800, height: 650)
        PanelLayout(frame: manuallyPlaced, in: screen, defaults: preferences).save(to: preferences)
        let restored = PanelLayout(defaults: preferences).frame(in: screen)
        precondition(abs(restored.minX - manuallyPlaced.minX) < 0.001)
        precondition(abs(restored.minY - manuallyPlaced.minY) < 0.001)
        precondition(restored.size == manuallyPlaced.size)
        let smallerScreen = CGRect(x: 0, y: 0, width: 1024, height: 768)
        precondition(smallerScreen.contains(PanelLayout(defaults: preferences).frame(in: smallerScreen)))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let api = Connection(address: "http://127.0.0.1", port: 8787, token: "test-only", session: URLSession(configuration: config))
        let base = try api.baseURL.absoluteString
        precondition(base == "http://127.0.0.1:8787")
        for address in ["file:///tmp", "http://user:password@localhost", "http://localhost?token=secret"] {
            do { _ = try Connection(address: address, port: 8787, token: "").baseURL; fatalError("Invalid address accepted") }
            catch {}
        }
        var paging = TrackpadPaging()
        precondition(paging.update(dx: -20, dy: 1, began: true, momentum: false).translation == -20)
        precondition(paging.update(dx: -45, dy: 0, began: false, momentum: false).translation == -65)
        precondition(paging.update(dx: -100, dy: 0, began: false, momentum: true).translation == -65)
        precondition(TrackpadPaging.step(translation: -65, width: 600) == 0)
        precondition(TrackpadPaging.step(translation: -160, width: 600) == 1)
        precondition(TrackpadPaging.step(translation: 160, width: 600) == -1)
        precondition(!paging.update(dx: 2, dy: 30, began: true, momentum: false).handled)
        precondition(!paging.update(dx: 100, dy: 0, began: false, momentum: false).handled)
        let menu = "› 1. Yes\n  2. No"
        precondition(PermissionChoice.parse("\u{1B}[31m" + menu + "\u{1B}[0m").count == 2)
        precondition(PermissionPaging.selection(current: "b", old: ["a", "b"], new: ["z", "a", "b"]) == "b")
        let longMenu = (1...12).map { number in
            "\(number == 1 ? "›" : " ") \(number). " + String(repeating: "long option ", count: 20) + "\n    continued text"
        }.joined(separator: "\n")
        let longChoices = PermissionChoice.parse(longMenu)
        precondition(longChoices.count == 12 && longChoices.last?.number == "12")
        precondition(longChoices.allSatisfy { $0.label.hasSuffix("continued text") })
        let entry = PermissionAttention(target: "session:0.0", tool: "Bash", receivedAt: 1)
        var policy = InboxPresentationPolicy()
        func presentation(_ entries: [PermissionAttention], visible: Bool = false,
                          succeeded: Bool = true, blocked: Bool = false) -> InboxPresentationPolicy.Action {
            policy.update(entries: entries, server: "local", succeeded: succeeded,
                          visible: visible, blocked: blocked, autoShow: true, autoClose: true)
        }
        precondition(presentation([entry]) == .show)
        precondition(presentation([entry]) == .none, "Manual dismissal must not reopen the same request")
        precondition(presentation([], visible: true, succeeded: false) == .none)
        precondition(presentation([], visible: true, blocked: true) == .none)
        precondition(presentation([], visible: true) == .close)
        precondition(presentation([], visible: true) == .none, "Manually opened empty panels stay open")
        precondition(presentation([entry]) == .show)
        let replacement = PermissionAttention(target: entry.target, tool: entry.tool, receivedAt: 2)
        precondition(RequestPresentation.current(preferences) == .none)
        preferences.set(true, forKey: "autoShowPermissionPanel")
        precondition(RequestPresentation.current(preferences) == .panel)
        preferences.set("notification", forKey: "requestPresentation")
        precondition(RequestPresentation.current(preferences) == .notification)
        var notifications = InboxNotificationPolicy(defaults: preferences)
        precondition(notifications.update(entries: [entry], server: "A", succeeded: true) == [entry])
        precondition(notifications.update(entries: [entry], server: "A", succeeded: true).isEmpty)
        precondition(notifications.update(entries: [], server: "A", succeeded: false).isEmpty)
        precondition(notifications.update(entries: [entry], server: "A", succeeded: true).isEmpty)
        precondition(notifications.update(entries: [replacement], server: "A", succeeded: true) == [replacement])
        precondition(notifications.update(entries: [entry], server: "B", succeeded: true) == [entry])
        precondition(notifications.update(entries: [replacement], server: "A", succeeded: true).isEmpty)

        var restartedNotifications = InboxNotificationPolicy(defaults: preferences)
        precondition(restartedNotifications.update(entries: [replacement], server: "A", succeeded: true).isEmpty)
        precondition(presentation([replacement]) == .show, "Same pane with a new request should reopen")
        let store = InboxStore()
        store.entries = [entry, PermissionAttention(target: "other:0.0", tool: "Edit", receivedAt: 2)]
        store.selected = entry.target
        store.updateSwipe(-160)
        precondition(store.selected == entry.target && store.swipeOffset == -160)
        store.finishSwipe(-160, cancelled: true)
        precondition(store.selected == entry.target && store.swipeOffset == 0)
        store.updateSwipe(-160)
        store.finishSwipe(-160, cancelled: false)
        precondition(store.selected == "other:0.0" && store.swipeOffset == 0)
        store.updateSwipe(-160)
        precondition(abs(store.swipeOffset) < 160, "Edges must resist dragging")
        store.finishSwipe(-160, cancelled: false)
        precondition(store.selected == "other:0.0")
        store.connection = api
        store.entries = [entry]; store.selected = entry.target; store.outputs[entry.target] = menu
        for translation: CGFloat in [-180, 180] {
            store.updateSwipe(translation)
            precondition(store.swipeOffset == 0 && !store.isSwiping, "Single cards must remain stationary and interactive")
            store.finishSwipe(translation, cancelled: false)
            precondition(store.selected == entry.target && store.swipeOffset == 0)
        }
        var posts = 0
        var latest = menu
        var pending = true
        StubProtocol.respond = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
            if request.httpMethod == "POST" { posts += 1; return (200, "") }
            if request.url!.path == "/attention" {
                return (200, pending ? "[{\"target\":\"session:0.0\",\"tool\":\"Bash\",\"received_at\":1}]" : "[]")
            }
            let data = try! JSONEncoder().encode(["output": latest])
            return (200, String(data: data, encoding: .utf8)!)
        }
        latest = menu + "\nUpdated context"
        store.drafts[entry.target] = "keep draft"
        await store.refresh(background: true)
        precondition(store.output == latest && !store.busy && store.drafts[entry.target] == "keep draft", "Background reads must update cached menus without losing drafts")
        store.sent.insert(entry.target)
        latest = "must not reopen sent request"
        await store.refresh(background: true)
        precondition(store.sent.contains(entry.target) && store.output != latest, "Background reads must never reset a sent request")
        store.sent.remove(entry.target)
        store.outputs[entry.target] = menu
        latest = "changed"
        await store.respond("1")
        precondition(store.replyReceipt == nil, "Changed output must not show success feedback")
        precondition(posts == 0 && store.output == "changed" && store.responseMessage != nil, "Changed output must block sending")
        latest = menu; store.outputs[entry.target] = menu; pending = false
        await store.respond("1")
        precondition(posts == 0, "Removed requests must block sending")
        pending = true; await store.refresh()
        await store.respond("1")
        await store.respond("1")
        precondition(store.replyReceipt != nil && store.isShowingReplyFeedback)
        let successfulReceipt = store.replyReceipt
        precondition(posts == 1 && store.sent.contains(entry.target), "Duplicate responses must be blocked")
        await store.refresh()
        StubProtocol.respond = { request in
            if request.httpMethod == "POST" { posts += 1; return (500, "") }
            if request.url!.path == "/attention" { return (200, "[{\"target\":\"session:0.0\",\"tool\":\"Bash\",\"received_at\":1}]") }
            return (200, String(data: try! JSONEncoder().encode(["output": menu]), encoding: .utf8)!)
        }
        await store.respond("1")
        await store.respond("1")
        precondition(store.replyReceipt == successfulReceipt, "Failed sends must not trigger success feedback")
        precondition(posts == 2 && store.requiresReload.contains(entry.target) && !store.canReply, "Ambiguous failures require explicit reload")
        StubProtocol.respond = { _ in (401, "") }
        do { _ = try await api.entries(); fatalError("Unauthorized accepted") } catch {}
        var accessAPI = api
        accessAPI.accessClientID = "id.access"; accessAPI.accessClientSecret = "secret"
        StubProtocol.respond = { request in
            request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access"
                && request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret" ? (200, "[]") : (403, "")
        }
        let accessEntries = try await accessAPI.entries()
        precondition(accessEntries.isEmpty, "Cloudflare Access credentials must be sent")
        do { _ = try await api.entries(); fatalError("Missing Access credentials accepted") } catch {}
        StubProtocol.respond = { _ in (401, "") }
        await store.poll()
        precondition(store.output == nil && store.error != nil, "Connection errors must invalidate reviewed output")
        var selectedPath: String?
        StubProtocol.respond = { request in
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
            selectedPath = request.url!.path
            return (204, "")
        }
        let didSelect = await store.selectPane()
        precondition(didSelect && selectedPath == "/panes/session:0.0/select")
        precondition(store.drafts.isEmpty && posts == 2, "Selecting a pane must not send terminal input")
        StubProtocol.respond = { _ in (500, "") }
        let failedSelect = await store.selectPane()
        precondition(!failedSelect && store.responseMessage != nil && !store.busy)
        let neighbor = PermissionAttention(target: "neighbor:1.0", tool: "Edit", receivedAt: 3)
        store.entries = [entry, neighbor]
        store.selected = entry.target
        store.outputs[entry.target] = menu
        store.drafts[entry.target] = "draft"
        store.updateSwipe(-90)
        StubProtocol.respond = { _ in (200, "[{\"target\":\"neighbor:1.0\",\"tool\":\"Edit\",\"received_at\":3}]") }
        await store.poll()
        precondition(!store.isSwiping && store.swipeOffset == 0)
        precondition(store.selected == neighbor.target && store.drafts[entry.target] == nil)
        store.drafts[neighbor.target] = "keep"
        StubProtocol.respond = { _ in (200, "[{\"target\":\"session:0.0\",\"tool\":\"Bash\",\"received_at\":1},{\"target\":\"neighbor:1.0\",\"tool\":\"Edit\",\"received_at\":3}]") }
        await store.poll()
        precondition(store.selected == neighbor.target && store.drafts[neighbor.target] == "keep")

        let left = Pane(index: 0, active: true, target: "demo:0.0", currentPath: "/work/app", geometry: PaneGeometry(left: 0, top: 0, width: 40, height: 30))
        let right = Pane(index: 1, active: false, target: "demo:0.1", currentPath: "/work/server", geometry: PaneGeometry(left: 41, top: 0, width: 39, height: 30))
        let workWindow = Window(index: 0, name: "coding", active: true, panes: [left, right], width: 80, height: 30)
        let frames = WorkPaneLayout.frames(workWindow, size: CGSize(width: 800, height: 300))
        precondition(abs((frames[left.target]?.width ?? 0) - 400) < 0.001 && abs((frames[right.target]?.minX ?? 0) - 410) < 0.001)

        let focusedFrames = WorkFocusLayout.panes(workWindow, selected: left.target, size: CGSize(width: 800, height: 300))
        precondition(focusedFrames[left.target]!.width > frames[left.target]!.width)
        precondition(!focusedFrames[left.target]!.intersects(focusedFrames[right.target]!))
        precondition(focusedFrames[right.target]!.maxX <= 800.001)
        let focusedCards = WorkFocusLayout.windows([workWindow, workWindow], selected: left.target, size: CGSize(width: 1500, height: 600))
        precondition(focusedCards.count == 2)
        precondition(focusedCards[0].width > focusedCards[1].width)
        precondition(abs(focusedCards[1].maxX - 1500) < 0.001)
        precondition(!focusedCards[0].intersects(focusedCards[1]))
        var zoomed = workWindow; zoomed.zoomed = true
        precondition(WorkPaneLayout.frames(zoomed, size: CGSize(width: 800, height: 300)).count == 2)
        var invalid = workWindow; invalid.width = 2
        let fallback = WorkPaneLayout.frames(invalid, size: CGSize(width: 800, height: 300))
        precondition(fallback[left.target]?.width == 400)
        for count in [1, 2, 5, 9, 30] {
            for size in [CGSize(width: 740, height: 400), CGSize(width: 1800, height: 900)] {
                let layout = WorkOverviewLayout(count: count, size: size)
                precondition(layout.rowCounts.reduce(0, +) == count)
                precondition(layout.rowCounts.allSatisfy { $0 > 0 })
                precondition((layout.rowCounts.max()! - layout.rowCounts.min()!) <= 1)
                precondition(layout.cardHeight >= 180)
            }
        }
        let solo = WorkOverviewLayout(count: 1, size: CGSize(width: 1400, height: 800))
        precondition(solo.rowCounts == [1] && solo.cardHeight == 800)

        let navigationFrames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 100),
            "b": CGRect(x: 120, y: 0, width: 100, height: 100),
            "c": CGRect(x: 0, y: 120, width: 100, height: 100),
            "d": CGRect(x: 120, y: 120, width: 100, height: 100)
        ]
        precondition(WorkSpatialNavigation.next(from: "d", direction: .up, frames: navigationFrames) == "b")
        precondition(WorkSpatialNavigation.next(from: "d", direction: .left, frames: navigationFrames) == "c")
        precondition(WorkSpatialNavigation.next(from: "a", direction: .down, frames: navigationFrames) == "c")
        precondition(WorkSpatialNavigation.next(from: "a", direction: .right, frames: navigationFrames) == "b")
        precondition(WorkSpatialNavigation.next(from: "a", direction: .up, frames: navigationFrames) == nil)

        let firstSeen = Date(timeIntervalSince1970: 100)
        var observation = WorkPaneObservation(firstSeen: firstSeen)
        observation.observe(previous: nil, output: "a", at: Date(timeIntervalSince1970: 110))
        precondition(observation.lastChangeDetected == nil)
        observation.observe(previous: "a", output: "a", at: Date(timeIntervalSince1970: 120))
        precondition(observation.lastChangeDetected == nil)
        observation.observe(previous: "a", output: "b", at: Date(timeIntervalSince1970: 130))
        precondition(observation.lastChangeDetected == Date(timeIntervalSince1970: 130))
        observation.observe(previous: nil, output: "c", at: Date(timeIntervalSince1970: 140))
        precondition(observation.lastChangeDetected == Date(timeIntervalSince1970: 130))
        precondition(observation.firstSeen == firstSeen)
        var unreadObservation = WorkPaneObservation(firstSeen: Date())
        unreadObservation.observe(previous: nil, output: "first", at: Date())
        precondition(!unreadObservation.unread)
        unreadObservation.observe(previous: "first", output: "new", at: Date())
        precondition(unreadObservation.unread)
        unreadObservation.observe(previous: "new", output: "new", at: Date())
        precondition(unreadObservation.unread, "Polling unchanged output must preserve unread state")
        unreadObservation.observe(previous: "new", output: "new", at: Date(), viewing: true)
        precondition(!unreadObservation.unread)
        unreadObservation.observe(previous: "new", output: "live", at: Date(), viewing: true)
        precondition(!unreadObservation.unread, "Output in the open preview is already seen")

        let inactivePane = Pane(index: 0, active: false, target: "live:2.0", currentPath: "/tmp")
        let activePane = Pane(index: 1, active: true, target: "live:2.1", currentPath: "/tmp")
        let activeWindow = Window(index: 2, name: "live", active: true, panes: [inactivePane, activePane])
        let inactiveWindow = Window(index: 1, name: "old", active: false, panes: [inactivePane])
        let detached = Session(name: "old", attached: false, windows: [activeWindow])
        let attached = Session(name: "live", attached: true, windows: [inactiveWindow, activeWindow])
        precondition(WorkInitialSelection.target(in: [detached, attached]) == activePane.target)
        precondition(WorkInitialSelection.target(in: []) == nil)
        precondition(WorkInitialSelection.target(in: [detached]) == activePane.target)

        for size in [CGSize(width: 2048, height: 1000), CGSize(width: 2560, height: 1300)] {
            let five = WorkGridLayout(count: 5, size: size)
            precondition(five.columns == 3, "Five panes on a wide screen should form two landscape rows")
            precondition(five.cardWidth > five.cardHeight)
            precondition(five.cardWidth * 3 + 32 <= size.width - 31.99)
            precondition(five.cardHeight * 2 + 16 <= size.height - 31.99)
        }
        for count in [0, 1, 2, 5, 20, 100] {
            let grid = WorkGridLayout(count: count, size: CGSize(width: 800, height: 500))
            precondition(grid.columns >= 1 && grid.columns <= max(1, count))
            precondition(grid.cardWidth > 0 && grid.cardHeight >= 180)
        }

        precondition(WorkSummary.excerpt("\n+ Show details\nFinished the update\n\n? for shortcuts") == "Finished the update")
        precondition(WorkSummary.excerpt("one\ntwo\nthree\nfour") == "two\nthree\nfour")
        precondition(WorkSummary.excerpt("\n  \n›") == "")

        precondition(LocalSummaryInput("  hello\n").text == "hello")
        precondition(LocalSummaryInput(String(repeating: "あ", count: 2000)).text.count == 1200)
        precondition(LocalSummaryInput(String(repeating: "x", count: 2000) + "latest").text.hasSuffix("latest"))
        precondition(LocalSummaryPrompt.effective(" \n ") == LocalSummaryPrompt.defaultText)
        precondition(LocalSummaryPrompt.effective(" 日本語で一文 ") == "日本語で一文")
        precondition(LocalSummaryPrompt.effective(String(repeating: "あ", count: 1400)).count == 1200)
        let summaries = LocalWorkSummaries()
        summaries.prepare(context: "server", enabled: true)
        summaries.records["pane"] = .init(input: LocalSummaryInput("output"), text: "summary")
        summaries.prepare(context: "server", enabled: true)
        precondition(summaries.records["pane"] != nil, "Reopening retains summaries with the same prompt")
        summaries.prepare(context: "server", enabled: true, prompt: "日本語で一文")
        precondition(summaries.records.isEmpty, "Changing the prompt invalidates cached summaries")
        let feedback = InboxStore()
        feedback.replyReceipt = UUID()
        feedback.replyFeedbackDeadline = 100
        precondition(feedback.replyFeedbackRemaining(at: 99.5) == 0.5)
        precondition(feedback.replyFeedbackRemaining(at: 100) == 0)
        precondition(feedback.replyFeedbackRemaining(at: 110) == 0, "An old receipt must not replay success when reopening the view")

        precondition(WorkCycleSelection.target(in: ["a", "b", "c"], selected: "c", backwards: false) == "a")
        precondition(WorkCycleSelection.target(in: ["a", "b", "c"], selected: "a", backwards: true) == "c")
        precondition(WorkCycleSelection.target(in: ["a", "b", "c"], selected: "b", backwards: false) == "c")
        precondition(WorkCycleSelection.target(in: ["a"], selected: "a", backwards: true) == "a")
        precondition(WorkCycleSelection.target(in: [], selected: nil, backwards: false) == nil)
        precondition(WorkCycleSelection.target(in: ["a", "b"], selected: nil, backwards: true) == "b")
        let work = WorkOverviewStore()
        let workSession = Session(name: "demo", attached: true, windows: [workWindow])
        var captureTargets: [String] = []
        StubProtocol.respond = { request in
            precondition(request.httpMethod == "GET", "Browsing must never change tmux selection or send input")
            if request.url!.path == "/sessions" { return (200, String(data: try! JSONEncoder().encode([workSession]), encoding: .utf8)!) }
            if request.url!.path == "/activity" { return (200, "[]") }
            captureTargets.append(request.url!.path)
            return (200, "{\"output\":\"preview\"}")
        }
        work.visibleTargets = [left.target]
        await work.refresh(connection: api)
        precondition(captureTargets == ["/panes/demo:0.0/output"])
        precondition(work.sessions.count == 1 && work.outputs[left.target] == "preview")
        work.prepareToOpen(connection: api)
        precondition(work.outputs[left.target] == "preview" && work.previewLines[left.target] == ["preview"], "Reopening must retain cached previews without waiting for a request")
        work.query = "SERVER"
        precondition(work.filteredSessions.count == 1)
        work.query = "missing"
        precondition(work.filteredSessions.isEmpty)
        work.query = ""
        work.move(1); precondition(work.selected == left.target)
        work.move(1); precondition(work.selected == right.target)
        StubProtocol.respond = { _ in (401, "") }
        await work.refresh(connection: api)
        precondition(work.error != nil && work.outputs.isEmpty)
        work.outputs[left.target] = "cached"
        work.prepareToOpen(connection: Connection(address: "http://another.example", port: 8787, token: "test-only"))
        precondition(work.outputs.isEmpty && work.previewLines.isEmpty && work.sessions.isEmpty, "A different connection must never show the old preview")

        // An early permission hook can precede the rendered menu.
        let delayed = InboxStore()
        delayed.connection = api; delayed.entries = [entry]; delayed.selected = entry.target
        var reads = 0
        StubProtocol.respond = { request in
            precondition(request.httpMethod == "GET")
            reads += 1
            return (200, String(data: try! JSONEncoder().encode(["output": reads == 1 ? "Drawing…" : menu]), encoding: .utf8)!)
        }
        await delayed.refresh()
        precondition(reads == 2 && !delayed.choices.isEmpty, "Read again when the initial menu has not rendered")
        StubProtocol.respond = { request in
            if request.url!.path == "/attention" {
                return (200, "[{\"target\":\"session:0.0\",\"tool\":\"Bash\",\"received_at\":1}]")
            }
            return (200, String(data: try! JSONEncoder().encode(["output": menu]), encoding: .utf8)!)
        }
        await delayed.prepareAutomaticPresentation()
        precondition(delayed.readyForAutomaticPresentation, "Auto-show waits for stable parsed choices")
        delayed.outputs[entry.target] = "Still drawing"
        precondition(!delayed.readyForAutomaticPresentation, "Changed or incomplete output invalidates readiness")
        StubProtocol.respond = { _ in
            (200, String(data: try! JSONEncoder().encode(["output": "Still drawing"]), encoding: .utf8)!)
        }
        await delayed.prepareAutomaticPresentation()
        precondition(!delayed.readyForAutomaticPresentation, "A prompt without choices must not auto-open")
        delayed.entries = [entry]; delayed.selected = entry.target
        StubProtocol.respond = { request in
            if request.url!.path == "/attention" { return (200, "[]") }
            return (200, String(data: try! JSONEncoder().encode(["output": menu]), encoding: .utf8)!)
        }
        await delayed.prepareAutomaticPresentation()
        precondition(!delayed.readyForAutomaticPresentation && delayed.entries.isEmpty && delayed.outputs.isEmpty,
                     "Answering directly in tmux during preparation must cancel auto-show and clear the old menu")
        delayed.entries = [entry]; delayed.selected = entry.target
        var terminalReads = 0
        StubProtocol.respond = { request in
            if request.url!.path == "/attention" {
                return (200, "[{\"target\":\"session:0.0\",\"tool\":\"Bash\",\"received_at\":1}]")
            }
            terminalReads += 1
            return (200, String(data: try! JSONEncoder().encode(["output": terminalReads >= 3 ? "Running tool..." : menu]), encoding: .utf8)!)
        }
        await delayed.prepareAutomaticPresentation()
        precondition(!delayed.readyForAutomaticPresentation,
                     "Do not auto-show if tmux has already left the menu even when attention briefly lags")
        print("PASS: manual layout persistence, long menus, list changes during swipe; pane selection and failure handling; URL validation, authorization, shared parsing/paging, stale requests, duplicate sends, connection errors")
    }
}

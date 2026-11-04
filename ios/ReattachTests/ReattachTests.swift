//
//  ReattachTests.swift
//  ReattachTests
//

import Foundation
import Testing
import UIKit
import SwiftUI
@testable import Reattach

@MainActor
struct ReattachTests {

    @Test func terminalStylesAndLinksSurviveRendering() throws {
        let text = "\u{1B}[7mselected\u{1B}[27m normal \u{1B}[48;5;21mblue\u{1B}[m https://example.com/path\n\u{1B}]8;;https://example.org\u{1B}\\日本語リンク\u{1B}]8;;\u{1B}\\"
        let rendered = TerminalTextRenderer.render(text)
        #expect(!rendered.string.contains("\u{1B}"))
        #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(rendered.attribute(.backgroundColor, at: 9, effectiveRange: nil) == nil)
        let plain = (rendered.string as NSString).range(of: "https://example.com/path")
        #expect((rendered.attribute(.link, at: plain.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/path")
        let named = (rendered.string as NSString).range(of: "日本語リンク")
        #expect((rendered.attribute(.link, at: named.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.org")
        let blue = (rendered.string as NSString).range(of: "blue")
        #expect(rendered.attribute(.backgroundColor, at: blue.location, effectiveRange: nil) as? UIColor == UIColor(red: 0, green: 0, blue: 1, alpha: 1))
    }

    @Test func copyModeSelectionAndCursorUseTheVisibleGrid() throws {
        let cursor = try JSONDecoder().decode(PaneCursorState.self, from: Data(#"{"x":3,"row_from_bottom":1,"pane_width":80,"visible":true,"copy_mode":true,"selection":[{"row_from_bottom":1,"start_x":1,"end_x":5}]}"#.utf8))
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        textView.attributedText = TerminalTextRenderer.render("a日本b\nnext\n")
        let coordinator = ZoomableTextView.Coordinator()
        let caret = UIView()
        textView.addSubview(caret)
        coordinator.cursorView = caret
        coordinator.updateCursor(cursor, in: textView, force: true)
        #expect(!caret.isHidden)
        let highlights = textView.subviews.filter { $0.backgroundColor == UIColor.systemBlue.withAlphaComponent(0.3) }
        #expect(highlights.count == 1)
        #expect(try #require(highlights.first).frame.width > 0)
        coordinator.updateCursor(PaneCursorState(x: 0, rowFromBottom: 0, paneWidth: 80, visible: true), in: textView, force: false)
        #expect(textView.subviews.filter { $0.backgroundColor == UIColor.systemBlue.withAlphaComponent(0.3) }.isEmpty)
    }

    @Test func permissionStatusTracksOtherPanesAndRejectsOldServerResponses() throws {
        let state = PermissionStatus()
        state.reset(serverID: "one")
        let data = Data(#"[{"target":"work:0.0","tool":"Bash","received_at":123},{"target":"work:1.0","tool":"Edit","received_at":124}]"#.utf8)
        let entries = try JSONDecoder().decode([PermissionAttention].self, from: data)
        state.update(entries, serverID: "one")
        #expect(state.isWaiting("work:0.0"))
        #expect(state.isWaiting("work:1.0"))
        #expect(!state.isWaiting("work:2.0"))
        state.reset(serverID: "two")
        state.update(entries, serverID: "one")
        #expect(state.entries.isEmpty)
        state.update(entries, serverID: "two")
        state.update([], serverID: "two")
        #expect(state.entries.isEmpty)
    }

    @Test func lastPanePersistsSeparatelyForEachServer() throws {
        let suite = "ReattachTests.lastPane.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PaneSelectionStore(defaults: defaults)
        #expect(store.target(for: "one") == nil)
        store.save("work:1.0", for: "one")
        store.save("work:2.1", for: "two")
        let reopened = PaneSelectionStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.target(for: "one") == "work:1.0")
        #expect(reopened.target(for: "two") == "work:2.1")
        reopened.save(nil, for: "one")
        #expect(reopened.target(for: "one") == nil)
        #expect(reopened.target(for: "two") == "work:2.1")
    }

    @Test func paneRestorationRequiresAnExistingExactTarget() {
        let pane = Pane(index: 0, active: false, target: "work:1.0", currentPath: "/tmp")
        let sessions = [Session(name: "work", attached: true, windows: [
            Window(index: 1, name: "editor", active: false, panes: [pane])
        ])]
        let restored = PaneNavigationItem.matching(target: "work:1.0", in: sessions)
        #expect(restored?.pane == pane)
        #expect(restored?.windowName == "editor")
        #expect(PaneNavigationItem.matching(target: "deleted:1.0", in: sessions) == nil)
        #expect(PaneNavigationItem.matching(target: "work:1.0", in: []) == nil)
    }

    @Test func synchronizedRestorationFollowsCurrentSessionSelection() {
        let previous = Pane(index: 0, active: true, target: "work:1.0", currentPath: "/tmp")
        let current = Pane(index: 1, active: true, target: "work:2.1", currentPath: "/tmp")
        let sessions = [Session(name: "work", attached: true, windows: [
            Window(index: 1, name: "previous", active: false, panes: [previous]),
            Window(index: 2, name: "current", active: true, panes: [current])
        ])]
        #expect(PaneNavigationItem.restoring(target: previous.target, in: sessions, synchronize: true)?.pane == current)
        #expect(PaneNavigationItem.restoring(target: previous.target, in: sessions, synchronize: false)?.pane == previous)
        // A removed or renumbered saved window must not redirect the host.
        #expect(PaneNavigationItem.restoring(target: "work:9.0", in: sessions, synchronize: true)?.pane == current)
        #expect(PaneNavigationItem.restoring(target: "work:9.0", in: sessions, synchronize: false) == nil)
        #expect(PaneNavigationItem.restoring(target: "missing:1.0", in: sessions, synchronize: true) == nil)
    }

    @Test func selectionPreferenceDecodesOlderConfigurationAndPersistsIndependently() throws {
        let legacy = Data(#"{"serverURL":"http://localhost:8080","deviceToken":"test","deviceId":"test","deviceName":"phone","serverName":"server","registeredAt":0}"#.utf8)
        var config = try JSONDecoder().decode(ServerConfig.self, from: legacy)
        #expect(config.synchronizeSelection == nil)
        #expect((config.synchronizeSelection ?? true) == true)
        config.synchronizeSelection = false
        let restored = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.synchronizeSelection == false)
        #expect(try JSONDecoder().decode(ServerConfig.self, from: legacy).synchronizeSelection == nil)
    }

    @Test func independentSelectionCapabilityAndWindowRequest() throws {
        let legacy = try JSONDecoder().decode(PaneStreamResponse.self, from: Data(#"{"type":"ready","tmux_keys":true}"#.utf8))
        #expect(legacy.independentSelection == nil)
        let ready = try JSONDecoder().decode(PaneStreamResponse.self, from: Data(#"{"type":"ready","tmux_keys":true,"independent_selection":true}"#.utf8))
        #expect(ready.independentSelection == true)
        let request = CreateWindowRequest(target: "work:1.0", independent: true)
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["independent"] as? Bool == true)
        #expect(object["target"] as? String == "work:1.0")
    }

    @Test func liveOutputDoesNotInterruptScrollingOrHistoryReading() {
        let coordinator = ZoomableTextView.Coordinator()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentSize = CGSize(width: 600, height: 1000)
        scroll.contentOffset = CGPoint(x: 40, y: 800)
        coordinator.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 400
        coordinator.scrollToLatest(in: scroll, force: true)
        #expect(scroll.contentOffset.y == 400)
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: true)
        coordinator.scrollToLatest(in: scroll)
        #expect(scroll.contentOffset.y == 400)
        coordinator.scrollViewDidEndDecelerating(scroll)
        scroll.contentSize.height = 1200
        coordinator.scrollToLatest(in: scroll)
        #expect(scroll.contentOffset.y == 400)
        coordinator.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 1000
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        scroll.contentSize.height = 1300
        coordinator.scrollToLatest(in: scroll)
        #expect(scroll.contentOffset.y == 1100)
        #expect(scroll.contentOffset.x == 40)
    }

    @Test func compositionOverlayStaysNearCursorAndInsideViewport() {
        let viewport = CGSize(width: 600, height: 400)
        let normal = CompositionPlacement.frame(cursor: CGRect(x: 100, y: 100, width: 8, height: 16), viewport: viewport)
        #expect(normal.minX == 100)
        #expect(normal.maxY == 84)
        let top = CompositionPlacement.frame(cursor: CGRect(x: 100, y: 8, width: 8, height: 16), viewport: viewport)
        #expect(top.minY == 40)
        let edge = CompositionPlacement.frame(cursor: CGRect(x: 590, y: 380, width: 8, height: 16), viewport: viewport)
        #expect(edge.maxX <= 592)
        #expect(edge.maxY < 380)
        let fallback = CompositionPlacement.frame(cursor: nil, viewport: viewport)
        #expect(fallback.minY >= 0 && fallback.maxY <= 400)
    }

    @Test func tmuxNavigationDecodingAndModeEncoding() throws {
        let data = Data(#"{"type":"navigation","state":{"pane_id":"%12","key_table":"prefix","prefix":"C-j","target":"work:2.1","window_name":"editor"}}"#.utf8)
        let response = try JSONDecoder().decode(PaneStreamResponse.self, from: data)
        #expect(response.state?.paneId == "%12")
        #expect(response.state?.target == "work:2.1")
        #expect(response.state?.keyTable == "prefix")
        let encoded = try JSONEncoder().encode(PaneStreamRequest.directMode(true))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["type"] as? String == "direct_mode")
        #expect(object["enabled"] as? Bool == true)
    }

    @Test func keyboardZoomPreservesVisibleCursorAndReadingPosition() {
        let coordinator = ZoomableTextView.Coordinator()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.delegate = coordinator
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        scroll.addSubview(text)
        scroll.contentSize = text.bounds.size
        let cursor = UIView(frame: CGRect(x: 200, y: 300, width: 5, height: 10))
        text.addSubview(cursor)
        coordinator.cursorView = cursor
        scroll.contentOffset = CGPoint(x: 100, y: 200)
        let anchor = CGPoint(x: cursor.frame.midX, y: cursor.frame.midY)
        func screenPosition(_ point: CGPoint) -> CGPoint {
            let converted = text.convert(point, to: scroll)
            return CGPoint(x: converted.x - scroll.contentOffset.x, y: converted.y - scroll.contentOffset.y)
        }
        let before = screenPosition(anchor)
        coordinator.applyZoom(TerminalZoomRequest(multiplier: 1.25), in: scroll)
        #expect(abs(screenPosition(anchor).x - before.x) < 0.1)
        #expect(abs(screenPosition(anchor).y - before.y) < 0.1)
        coordinator.applyZoom(TerminalZoomRequest(multiplier: 1 / 1.25), in: scroll)
        #expect(abs(scroll.contentOffset.x - 100) < 0.1)
        #expect(abs(scroll.contentOffset.y - 200) < 0.1)

        cursor.isHidden = true
        let readingAnchor = text.convert(scroll.bounds.origin, from: scroll)
        coordinator.applyZoom(TerminalZoomRequest(multiplier: 1.25), in: scroll)
        #expect(abs(screenPosition(readingAnchor).x) < 0.1)
        #expect(abs(screenPosition(readingAnchor).y) < 0.1)
        coordinator.applyZoom(TerminalZoomRequest(multiplier: nil), in: scroll)
        #expect(scroll.zoomScale == 1)
    }

    @Test func cursorTracksActualGlyphsForEnglishAndJapanese() throws {
        for (line, column, offset) in [
            ("abcdefghijklmnopqrstuvwxyz", 26, 26),
            ("abc日本語def", 9, 6),
            ("日本語日本語日本語", 18, 9),
            ("e\u{301}あ", 3, 3),
            ("ｱｲｳ", 3, 3),
        ] {
            let view = UITextView(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
            view.isEditable = false
            view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            view.attributedText = NSAttributedString(string: line + "\n", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 8, weight: .regular)
            ])
            view.layoutManager.ensureLayout(for: view.textContainer)
            let position = try #require(view.position(from: view.beginningOfDocument, offset: offset))
            let expected = view.caretRect(for: position)
            let cursor = PaneCursorState(x: column, rowFromBottom: 0, paneWidth: 80, visible: true)
            let actual = try #require(ZoomableTextView.Coordinator().cursorFrame(cursor, in: view))
            #expect(abs(actual.minX - expected.minX) < 0.1)
            #expect(abs(actual.minY - expected.minY) < 0.1)
        }
    }

    @Test func terminalColumnsMapWideCharactersAndTrailingSpaces() {
        #expect(TerminalColumns.location(in: "a日本b", column: 5).utf16Offset == 3)
        #expect(TerminalColumns.location(in: "a日", column: 2).extraColumns == 1)
        #expect(TerminalColumns.location(in: "日本", column: 8).extraColumns == 4)
        #expect(TerminalColumns.width(of: "か\u{3099}") == 2)
        #expect(TerminalColumns.width(of: "👩‍💻") == 2)
    }

    @Test func paneShortcutsFollowListOrderAndWrap() throws {
        let sessions = MockData.sessions
        let first = try #require(PaneNavigationItem.adjacent(to: nil, in: sessions, backward: false))
        let last = try #require(PaneNavigationItem.adjacent(to: nil, in: sessions, backward: true))
        #expect(first.pane.target == "dev:0.0")
        #expect(last.pane.target == "tools:1.0")
        #expect(PaneNavigationItem.adjacent(to: first, in: sessions, backward: true) == last)
        #expect(PaneNavigationItem.adjacent(to: last, in: sessions, backward: false) == first)
        let next = PaneNavigationItem.adjacent(to: first, in: sessions, backward: false)
        #expect(next?.pane.target == "dev:1.0")
        #expect(PaneNavigationItem.adjacent(to: next, in: sessions, backward: true) == first)
        #expect(PaneNavigationItem.adjacent(to: first, in: [], backward: false) == nil)
    }

    @Test func commandReturnSubmitsOnlyCommittedDraft() {
        var sent: [String] = []
        let view = DirectInputDraftTextView()
        view.onSendAndEnter = { sent.append($0); return true }
        view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0))
        view.sendDraft()
        #expect(sent.isEmpty)
        #expect(view.text == "日本語")
        view.unmarkText()
        view.sendDraft()
        #expect(sent == ["日本語"])
        #expect(view.text.isEmpty)

        view.text = "接続待ち"
        view.onSendAndEnter = { _ in false }
        view.sendDraft()
        #expect(view.text == "接続待ち")
    }

    @Test func compositionEditorRetainsConfirmedJapaneseAndReturn() {
        var draft = ""
        let coordinator = DirectInputDraftEditor.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 })
        )
        let view = UITextView()
        view.delegate = coordinator
        view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0))
        coordinator.textViewDidChange(view)
        view.unmarkText()
        coordinator.textViewDidChange(view)
        #expect(draft == "日本語")
        #expect(view.text == "日本語")

        view.insertText("\n")
        coordinator.textViewDidChange(view)
        #expect(draft == "日本語\n")
        #expect(view.text == "日本語\n")
    }

    @Test func directInputKeepsCompositionLocalUntilCommitted() async throws {
        var sentText: [String] = []
        var sentKeys: [String] = []
        let coordinator = DirectInputTextViewRepresentable.Coordinator(
            onText: { sentText.append($0) },
            onKey: { key, _ in sentKeys.append(key) },
            onCompositionChanged: { _ in }
        )
        let textView = TerminalInputTextView()
        textView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
        #expect(textView.markedTextRange != nil)
        coordinator.textViewDidChange(textView)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sentText.isEmpty)
        #expect(coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 4, length: 0),
            replacementText: "\n"
        ))
        #expect(sentKeys.isEmpty)

        textView.onCompositionEnded = { coordinator.textViewDidChange(textView) }
        textView.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0))
        textView.unmarkText()
        try await Task.sleep(for: .milliseconds(20))
        #expect(sentText == ["日本語"])
        #expect(textView.text.isEmpty)

        #expect(!coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementText: "\n"
        ))
        #expect(sentKeys == ["enter"])
    }

    @Test func directTextMessageEncoding() throws {
        let data = try JSONEncoder().encode(PaneStreamRequest.directText("hello"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "text")
        #expect(object["text"] as? String == "hello")
        #expect(object["key"] == nil)
    }

    @Test func directInputWaitsForMarkedTextAndKeepsTextBeforeEnter() async throws {
        var events: [String] = []
        let coordinator = DirectInputTextViewRepresentable.Coordinator(
            onText: { events.append($0) },
            onKey: { key, _ in events.append(key) },
            onCompositionChanged: { _ in }
        )
        let textView = TerminalInputTextView()
        textView.text = "に"
        coordinator.textViewDidChange(textView)
        textView.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        #expect(events.isEmpty)
        #expect(!textView.text.isEmpty)

        textView.unmarkText()
        textView.text = "日本語"
        coordinator.textViewDidChange(textView)
        coordinator.sendKey("enter", modifiers: [], from: textView)
        try await Task.sleep(for: .milliseconds(20))
        #expect(events == ["日本語", "enter"])
    }

    @Test func modifiedKeyMessageEncoding() throws {
        let request = PaneStreamRequest.key("left", modifiers: ["control", "shift"])
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "key")
        #expect(object["key"] as? String == "left")
        #expect(object["modifiers"] as? [String] == ["control", "shift"])
    }

    @Test func controlCharacterMapsToTerminalKey() throws {
        let mapped = try #require(DirectInputKeyMapper.modifiedCharacter(
            keyCode: .keyboardC,
            charactersIgnoringModifiers: "\u{3}",
            modifiers: .control
        ))

        #expect(mapped.key == "c")
        #expect(mapped.modifiers == ["control"])
    }

    @Test func inputSourceShortcutsAreNotSentToTerminal() {
        for characters in [" ", "\u{0}", ""] {
            for modifiers: UIKeyModifierFlags in [.control, [.control, .shift]] {
                #expect(DirectInputKeyMapper.modifiedCharacter(
                    keyCode: .keyboardSpacebar,
                    charactersIgnoringModifiers: characters,
                    modifiers: modifiers
                ) == nil)
            }
        }
    }

    @Test func altSpaceStillMapsToTerminal() throws {
        let mapped = try #require(DirectInputKeyMapper.modifiedCharacter(
            keyCode: .keyboardSpacebar,
            charactersIgnoringModifiers: " ",
            modifiers: .alternate
        ))
        #expect(mapped.key == "space")
        #expect(mapped.modifiers == ["alt"])
    }

    @Test func controlLetterFallsBackToHIDUsage() throws {
        let mapped = try #require(DirectInputKeyMapper.modifiedCharacter(
            keyCode: .keyboardD,
            charactersIgnoringModifiers: "",
            modifiers: .control
        ))

        #expect(mapped.key == "d")
        #expect(mapped.modifiers == ["control"])
    }

    @Test func cursorMessageDecoding() throws {
        let data = Data(
            #"{"type":"cursor","cursor":{"x":12,"row_from_bottom":2,"pane_width":80,"visible":true}}"#
                .utf8
        )
        let response = try JSONDecoder().decode(PaneStreamResponse.self, from: data)

        #expect(response.type == "cursor")
        #expect(response.cursor == PaneCursorState(
            x: 12,
            rowFromBottom: 2,
            paneWidth: 80,
            visible: true
        ))
    }

    @Test func directInputActivityLabelsTerminalKeys() {
        #expect(
            DirectInputView.activityLabel(for: "c", modifiers: ["control"])
                == "Ctrl-C"
        )
        #expect(
            DirectInputView.activityLabel(for: "left", modifiers: [])
                == "←"
        )
    }

}

@MainActor
private final class RecoverySocket: PaneStreamSocket {
    var incoming: [URLSessionWebSocketTask.Message] = []
    var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var blockedSend: CheckedContinuation<Void, Error>?
    var sent: [String] = []
    var cancelled = false
    var respondsToPing = true
    var blockNextSend = false

    init(ready: Bool = true) {
        if ready { incoming = [.string(#"{"type":"ready","tmux_keys":true,"independent_selection":true}"#)] }
    }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        receiver?.resume(throwing: URLError(.cancelled))
        receiver = nil
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if cancelled { throw URLError(.cancelled) }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if cancelled { throw URLError(.cancelled) }
        if case .string(let text) = message { sent.append(text) }
        if blockNextSend {
            blockNextSend = false
            try await withCheckedThrowingContinuation { blockedSend = $0 }
        }
    }
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        if respondsToPing { pongReceiveHandler(nil) }
    }
}

@MainActor
struct StreamRecoveryTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for stream state")
    }

    @Test func silentHandshakeIsReplaced() async throws {
        let first = RecoverySocket(ready: false)
        let second = RecoverySocket()
        var attempts = 0
        let model = PaneDetailViewModel(target: "probe", heartbeatInterval: .milliseconds(40), retryInterval: .milliseconds(5)) { _, _ in
            attempts += 1
            return attempts == 1 ? first : second
        }
        defer { model.stopStreaming() }
        await model.startStreaming()
        try await waitUntil { attempts == 2 && model.isStreamConnected }
        #expect(first.cancelled)
        #expect(!second.cancelled)
    }

    @Test func lostPongReconnectsWithoutReplayingQueuedInputOrAcceptingOldFailure() async throws {
        let first = RecoverySocket()
        first.respondsToPing = false
        let second = RecoverySocket()
        var attempts = 0
        let model = PaneDetailViewModel(target: "probe", heartbeatInterval: .milliseconds(80), retryInterval: .milliseconds(5)) { _, _ in
            attempts += 1
            return attempts == 1 ? first : second
        }
        defer { model.stopStreaming() }
        model.setDirectMode(true)
        await model.startStreaming()
        try await waitUntil { model.isStreamConnected }
        first.blockNextSend = true
        model.queueDirectKey("left")
        try await waitUntil { first.blockedSend != nil }
        model.queueDirectText("old input")
        model.flushDirectInput()
        try await waitUntil { attempts == 2 && model.isStreamConnected }
        first.blockedSend?.resume(throwing: URLError(.networkConnectionLost))
        first.blockedSend = nil
        model.queueDirectText("new input")
        model.flushDirectInput()
        try await waitUntil { second.sent.contains { $0.contains("new input") } }
        #expect(!second.sent.contains { $0.contains("old input") })
        #expect(!second.cancelled)
        #expect(model.isStreamConnected)
        let mode = try JSONDecoder().decode(PaneStreamRequest.self, from: Data(second.sent[0].utf8))
        #expect(mode.type == "direct_mode" && mode.enabled == true)
    }

    @Test func copyRequestAndResponsePreserveUnicodeAndNewlines() throws {
        let data = try JSONEncoder().encode(PaneStreamRequest.copySelection)
        #expect(try JSONDecoder().decode(PaneStreamRequest.self, from: data).type == "copy_selection")
        let response = try JSONDecoder().decode(PaneStreamResponse.self, from: Data(#"{"type":"clipboard","text":"日本語\nnext","error":null}"#.utf8))
        #expect(response.text == "日本語\nnext")
    }
}

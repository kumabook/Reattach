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

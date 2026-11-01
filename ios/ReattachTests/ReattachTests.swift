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

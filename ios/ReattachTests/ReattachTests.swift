//
//  ReattachTests.swift
//  ReattachTests
//

import Foundation
import Testing
import UIKit
@testable import Reattach

@MainActor
struct ReattachTests {

    @Test func directTextMessageEncoding() throws {
        let data = try JSONEncoder().encode(PaneStreamRequest.directText("hello"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "text")
        #expect(object["text"] as? String == "hello")
        #expect(object["key"] == nil)
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

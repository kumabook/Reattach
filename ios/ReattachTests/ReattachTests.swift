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

}

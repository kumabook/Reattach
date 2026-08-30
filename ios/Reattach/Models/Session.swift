//
//  Session.swift
//  Reattach
//

import Foundation

struct Pane: Codable, Identifiable, Hashable {
    let index: UInt32
    let active: Bool
    let target: String
    let currentPath: String

    var id: String { target }

    var shortPath: String {
        (currentPath as NSString).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case index, active, target
        case currentPath = "current_path"
    }
}

struct Window: Codable, Identifiable, Hashable {
    let index: UInt32
    let name: String
    let active: Bool
    let panes: [Pane]

    var id: UInt32 { index }
}

struct Session: Codable, Identifiable, Hashable {
    let name: String
    let attached: Bool
    let windows: [Window]

    var id: String { name }
}

struct CreateSessionRequest: Codable {
    let name: String
    let cwd: String
}

struct SendInputRequest: Codable {
    let text: String
}

struct RegisterDeviceRequest: Codable {
    let token: String
    let sandbox: Bool
    let deviceId: String
    let serverName: String

    enum CodingKeys: String, CodingKey {
        case token, sandbox
        case deviceId = "device_id"
        case serverName = "server_name"
    }
}

struct OutputResponse: Codable {
    let output: String
}

struct PaneStreamRequest: Codable {
    let type: String
    let text: String?
    let key: String?
    let modifiers: [String]?

    static func input(_ text: String) -> PaneStreamRequest {
        PaneStreamRequest(type: "input", text: text, key: nil, modifiers: nil)
    }

    static func directText(_ text: String) -> PaneStreamRequest {
        PaneStreamRequest(type: "text", text: text, key: nil, modifiers: nil)
    }

    static func key(_ key: String, modifiers: [String] = []) -> PaneStreamRequest {
        PaneStreamRequest(type: "key", text: nil, key: key, modifiers: modifiers)
    }

    static let escape = PaneStreamRequest(type: "escape", text: nil, key: nil, modifiers: nil)
    static let refresh = PaneStreamRequest(type: "refresh", text: nil, key: nil, modifiers: nil)
}

struct PaneStreamResponse: Codable {
    let type: String
    let output: String?
    let error: String?
    let startLine: Int?
    let deleteCount: Int?
    let lines: [String]?
    let cursor: PaneCursorState?

    enum CodingKeys: String, CodingKey {
        case type, output, error, lines, cursor
        case startLine = "start_line"
        case deleteCount = "delete_count"
    }
}

struct PaneCursorState: Codable, Equatable {
    let x: Int
    let rowFromBottom: Int
    let paneWidth: Int
    let visible: Bool

    enum CodingKeys: String, CodingKey {
        case x, visible
        case rowFromBottom = "row_from_bottom"
        case paneWidth = "pane_width"
    }
}

struct ErrorResponse: Codable {
    let error: String
}

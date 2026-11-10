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
    var geometry: PaneGeometry? = nil

    var id: String { target }

    var shortPath: String {
        (currentPath as NSString).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case index, active, target, geometry
        case currentPath = "current_path"
    }
}

struct Window: Codable, Identifiable, Hashable {
    let index: UInt32
    let name: String
    let active: Bool
    let panes: [Pane]
    var width: Int? = nil
    var height: Int? = nil
    var zoomed: Bool? = nil
    var borders: PaneBorders? = nil

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

struct CreateWindowRequest: Codable {
    let target: String
    var independent: Bool = false
}

enum PaneSplitDirection: String, Codable {
    case leftRight = "left_right"
    case topBottom = "top_bottom"
}

struct SplitPaneRequest: Codable {
    let direction: PaneSplitDirection
    let independent: Bool
}

struct CreatedTarget: Codable {
    let target: String
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
    var enabled: Bool? = nil

    static func directMode(_ enabled: Bool) -> PaneStreamRequest {
        PaneStreamRequest(type: "direct_mode", text: nil, key: nil, modifiers: nil, enabled: enabled)
    }

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
    static let copySelection = PaneStreamRequest(type: "copy_selection", text: nil, key: nil, modifiers: nil)
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
    var text: String? = nil
    var clipboard: Bool? = nil
    var tmuxKeys: Bool? = nil
    var independentSelection: Bool? = nil
    var state: TmuxNavigationState? = nil

    enum CodingKeys: String, CodingKey {
        case type, output, error, lines, cursor, state, text, clipboard
        case tmuxKeys = "tmux_keys"
        case independentSelection = "independent_selection"
        case startLine = "start_line"
        case deleteCount = "delete_count"
    }
}

struct TmuxNavigationState: Codable, Equatable {
    let paneId: String
    let keyTable: String
    let prefix: String
    let target: String
    let windowName: String

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case keyTable = "key_table"
        case windowName = "window_name"
        case prefix, target
    }
}

struct PaneCursorState: Codable, Equatable {
    let x: Int
    let rowFromBottom: Int
    let paneWidth: Int
    let visible: Bool
    var copyMode: Bool? = nil
    var selection: [PaneSelectionSpan]? = nil

    enum CodingKeys: String, CodingKey {
        case x, visible, selection
        case copyMode = "copy_mode"
        case rowFromBottom = "row_from_bottom"
        case paneWidth = "pane_width"
    }
}

struct ErrorResponse: Codable {
    let error: String
}

struct PaneSelectionSpan: Codable, Equatable {
    let rowFromBottom: Int
    let startX: Int
    let endX: Int
    enum CodingKeys: String, CodingKey {
        case rowFromBottom = "row_from_bottom"
        case startX = "start_x"
        case endX = "end_x"
    }
}

struct PaneGeometry: Codable, Hashable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
}

struct PaneBorders: Codable, Hashable {
    let style: String
    let activeStyle: String
    let indicators: String

    enum CodingKeys: String, CodingKey {
        case style, indicators
        case activeStyle = "active_style"
    }
}

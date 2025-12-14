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

struct OutputResponse: Codable {
    let output: String
}

struct ErrorResponse: Codable {
    let error: String
}

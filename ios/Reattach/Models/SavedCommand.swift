//
//  SavedCommand.swift
//  Reattach
//

import Foundation
import Observation
import SwiftUI

struct SavedCommand: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String
    var command: String
    var createdAt: Date

    init(id: UUID = UUID(), label: String, command: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.command = command
        self.createdAt = createdAt
    }
}

@MainActor
@Observable
class SavedCommandManager {
    static let shared = SavedCommandManager()

    private(set) var commands: [SavedCommand] = []
    private let userDefaultsKey = "savedCommands"

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([SavedCommand].self, from: data) else {
            // Default commands
            commands = [
                SavedCommand(label: "Yes", command: "y"),
                SavedCommand(label: "No", command: "n"),
            ]
            return
        }
        commands = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    var canAddCommand: Bool {
        commands.count < PurchaseManager.shared.bookmarkLimit
    }

    func add(_ command: SavedCommand) {
        guard canAddCommand else { return }
        commands.append(command)
        save()
    }

    func update(_ command: SavedCommand) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[index] = command
        save()
    }

    func delete(_ command: SavedCommand) {
        commands.removeAll { $0.id == command.id }
        save()
    }

    func delete(at offsets: IndexSet) {
        commands.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        commands.move(fromOffsets: source, toOffset: destination)
        save()
    }
}

// MARK: - Command History

struct CommandHistoryItem: Identifiable, Codable, Equatable {
    var id: UUID
    var command: String
    var sentAt: Date

    init(id: UUID = UUID(), command: String, sentAt: Date = Date()) {
        self.id = id
        self.command = command
        self.sentAt = sentAt
    }
}

@MainActor
@Observable
class CommandHistoryManager {
    static let shared = CommandHistoryManager()

    private(set) var history: [CommandHistoryItem] = []
    private let userDefaultsKey = "commandHistory"

    private var maxCount: Int {
        PurchaseManager.shared.historyLimit
    }

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([CommandHistoryItem].self, from: data) else {
            return
        }
        history = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    func add(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Remove duplicate if exists
        history.removeAll { $0.command == trimmed }

        // Add to beginning
        let item = CommandHistoryItem(command: trimmed)
        history.insert(item, at: 0)

        // Limit to maxCount
        if history.count > maxCount {
            history = Array(history.prefix(maxCount))
        }

        save()
    }

    func clear() {
        history.removeAll()
        save()
    }
}

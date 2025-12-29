//
//  CommandEditorView.swift
//  Reattach
//

import SwiftUI

struct CommandEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var commandManager = SavedCommandManager.shared
    @State private var showAddSheet = false
    @State private var editingCommand: SavedCommand?

    var body: some View {
        NavigationStack {
            List {
                ForEach(commandManager.commands) { command in
                    Button {
                        editingCommand = command
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(command.label)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(command.command)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fontDesign(.monospaced)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    commandManager.delete(at: offsets)
                }
                .onMove { source, destination in
                    commandManager.move(from: source, to: destination)
                }
            }
            .navigationTitle("Saved Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showAddSheet) {
                CommandFormView(mode: .add)
            }
            .sheet(item: $editingCommand) { command in
                CommandFormView(mode: .edit(command))
            }
        }
    }
}

struct CommandFormView: View {
    enum Mode {
        case add
        case edit(SavedCommand)
    }

    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var commandManager = SavedCommandManager.shared
    @State private var label: String = ""
    @State private var command: String = ""

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !command.isEmpty
    }

    private var title: String {
        switch mode {
        case .add: return "Add Command"
        case .edit: return "Edit Command"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                    TextField("Command", text: $command)
                        .fontDesign(.monospaced)
                } footer: {
                    Text("The label is shown on the button. The command is sent when tapped.")
                }

                if case .edit(let existingCommand) = mode {
                    Section {
                        Button(role: .destructive) {
                            commandManager.delete(existingCommand)
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Command")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                if case .edit(let existingCommand) = mode {
                    label = existingCommand.label
                    command = existingCommand.command
                }
            }
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .add:
            let newCommand = SavedCommand(label: trimmedLabel, command: command)
            commandManager.add(newCommand)
        case .edit(let existingCommand):
            var updated = existingCommand
            updated.label = trimmedLabel
            updated.command = command
            commandManager.update(updated)
        }
    }
}

struct CommandPickerView: View {
    enum Tab: String, CaseIterable {
        case saved = "Saved"
        case history = "History"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var commandManager = SavedCommandManager.shared
    @State private var historyManager = CommandHistoryManager.shared
    @State private var selectedTab: Tab = {
        let saved = UserDefaults.standard.string(forKey: "commandPickerTab")
        return Tab(rawValue: saved ?? "") ?? .saved
    }()
    @State private var savingHistoryItem: CommandHistoryItem?
    @State private var editingCommand: SavedCommand?
    @State private var isReordering = false
    var onCommandSelected: (String) -> Void
    var onCommandInsert: ((String) -> Void)?
    var onEditCommands: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                .disabled(isReordering)
                .onChange(of: selectedTab) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: "commandPickerTab")
                }

                Group {
                    switch selectedTab {
                    case .saved:
                        savedCommandsView
                    case .history:
                        historyView
                    }
                }
            }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isReordering {
                        Button("Done") {
                            isReordering = false
                        }
                    } else {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selectedTab == .saved && !commandManager.commands.isEmpty && !isReordering {
                        Button {
                            isReordering = true
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                }
            }
            .sheet(item: $savingHistoryItem) { item in
                SaveFromHistoryView(command: item.command)
            }
            .sheet(item: $editingCommand) { command in
                CommandFormView(mode: .edit(command))
            }
        }
    }

    @ViewBuilder
    private var savedCommandsView: some View {
        if commandManager.commands.isEmpty {
            ContentUnavailableView(
                "No Saved Commands",
                systemImage: "bookmark",
                description: Text("Tap Edit to add commands")
            )
        } else {
            List {
                ForEach(commandManager.commands) { command in
                    Button {
                        if !isReordering {
                            dismiss()
                            onCommandSelected(command.command)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.label)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(command.command)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(isReordering)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = command.command
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        Divider()

                        if onCommandInsert != nil {
                            Button {
                                dismiss()
                                onCommandInsert?(command.command)
                            } label: {
                                Label("Insert", systemImage: "text.cursor")
                            }
                        }

                        Button {
                            dismiss()
                            onCommandSelected(command.command)
                        } label: {
                            Label("Send", systemImage: "paperplane")
                        }

                        Divider()

                        Button {
                            editingCommand = command
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            commandManager.delete(command)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onMove { source, destination in
                    commandManager.move(from: source, to: destination)
                }
            }
            .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        }
    }

    @ViewBuilder
    private var historyView: some View {
        if historyManager.history.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "clock",
                description: Text("Commands you send will appear here")
            )
        } else {
            List {
                ForEach(historyManager.history) { item in
                    Button {
                        dismiss()
                        onCommandSelected(item.command)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.command)
                                    .font(.body)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(item.sentAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "paperplane")
                                .foregroundStyle(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            savingHistoryItem = item
                        } label: {
                            Label("Save", systemImage: "bookmark")
                        }
                        .tint(.purple)
                    }
                }
            }
        }
    }
}

struct SaveFromHistoryView: View {
    let command: String
    @Environment(\.dismiss) private var dismiss
    @State private var commandManager = SavedCommandManager.shared
    @State private var label: String = ""

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                    Text(command)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Enter a label for this command")
                }
            }
            .navigationTitle("Save Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newCommand = SavedCommand(
                            label: label.trimmingCharacters(in: .whitespaces),
                            command: command
                        )
                        commandManager.add(newCommand)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

#Preview {
    CommandEditorView()
}

//
//  CreateSessionView.swift
//  Reattach
//

import SwiftUI

struct CreateSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var isCreating = false
    @State private var creationError: String?

    let onCreate: (String, String) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Session Name"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField(String(localized: "Working Directory (optional)"), text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(String(localized: "New Session"))
                } footer: {
                    Text(String(localized: "A new tmux session will open with your default shell."))
                }
            }
            .navigationTitle(String(localized: "Create Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create")) {
                        Task {
                            isCreating = true
                            defer { isCreating = false }
                            do {
                                try await onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), cwd)
                                dismiss()
                            } catch {
                                creationError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
            .interactiveDismissDisabled(isCreating)
            .alert(String(localized: "Create Session Failed"), isPresented: Binding(get: { creationError != nil }, set: { if !$0 { creationError = nil } })) {
                Button(String(localized: "OK")) { creationError = nil }
            } message: {
                Text(creationError ?? "")
            }
        }
    }
}

#Preview {
    CreateSessionView { name, cwd in
        print("Create: \(name) at \(cwd)")
    }
}

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

    let onCreate: (String, String) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Working Directory", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("New Session")
                } footer: {
                    Text("The session will be created as 'claude-\(name)' and Claude Code will be started automatically.")
                }
            }
            .navigationTitle("Create Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            isCreating = true
                            await onCreate(name, cwd)
                            isCreating = false
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || cwd.isEmpty || isCreating)
                }
            }
            .interactiveDismissDisabled(isCreating)
        }
    }
}

#Preview {
    CreateSessionView { name, cwd in
        print("Create: \(name) at \(cwd)")
    }
}

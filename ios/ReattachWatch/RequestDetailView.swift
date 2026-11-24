import SwiftUI

struct RequestDetailView: View {
    let requestID: String
    @Environment(\.dismiss) private var dismiss
    @State private var store = WatchStore.shared
    @State private var sending: String?
    @State private var failure: String?

    private var request: PendingRequest? {
        store.requests.first { $0.id == requestID }
    }

    var body: some View {
        ScrollView {
            if let request {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.target).font(.headline)
                    if let prompt = request.prompt {
                        if !prompt.context.isEmpty {
                            Text(prompt.context).font(.footnote)
                        }
                        ForEach(prompt.choices, id: \.self) { choice in
                            Button {
                                answer(request, choice: choice.number)
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(choice.number).bold()
                                    Text(choice.label).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    if sending == choice.number { ProgressView().frame(width: 16) }
                                }
                            }
                            .disabled(sending != nil)
                        }
                    } else {
                        Text("The choices are not visible on screen. Answer from iPhone or the terminal.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                }
            } else {
                Text("This request is no longer pending.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(request?.tool ?? "")
    }

    private func answer(_ request: PendingRequest, choice: String) {
        sending = choice
        failure = nil
        Task {
            do {
                try await store.respond(to: request, choice: choice)
                dismiss()
            } catch {
                failure = error.localizedDescription
                await store.refresh()
            }
            sending = nil
        }
    }
}

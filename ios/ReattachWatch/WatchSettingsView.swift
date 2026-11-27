import SwiftUI

enum WatchSettings {
    static let choicesFirstKey = "choicesFirst"
}

struct WatchSettingsView: View {
    @AppStorage(WatchSettings.choicesFirstKey) private var choicesFirst = true

    var body: some View {
        List {
            Section {
                Toggle("Choices first", isOn: $choicesFirst)
            } footer: {
                Text("Show the choices above the request details.")
            }
        }
        .navigationTitle("Settings")
    }
}

import SwiftUI

@main
struct ReattachWatchApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .font(.title2)
                Text("Permission requests from Reattach appear as notifications. Tap a number to answer.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

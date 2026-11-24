import SwiftUI

@main
struct ReattachWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RequestListView()
        }
    }
}

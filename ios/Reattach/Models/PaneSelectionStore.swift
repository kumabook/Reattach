import Foundation

struct PaneSelectionStore {
    private let defaults: UserDefaults
    private let key = "last_selected_panes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func target(for serverID: String) -> String? {
        defaults.dictionary(forKey: key)?[serverID] as? String
    }

    func save(_ target: String?, for serverID: String) {
        var targets = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard targets[serverID] != target else { return }
        targets[serverID] = target
        defaults.set(targets, forKey: key)
    }
}

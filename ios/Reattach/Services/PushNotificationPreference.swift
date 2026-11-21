import Foundation

enum PushNotificationPreference: String, CaseIterable {
    case all
    case permissionOnly = "permission_only"
    case off
    static let key = "pushNotificationPreference"
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .all }
    static let permissionContentKey = "pushPermissionContent"
    static var includesPermissionContent: Bool {
        UserDefaults.standard.object(forKey: permissionContentKey) as? Bool ?? true
    }
    var title: String {
        switch self {
        case .all: String(localized: "All notifications")
        case .permissionOnly: String(localized: "Permission requests only")
        case .off: String(localized: "Off")
        }
    }
}

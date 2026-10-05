import Foundation

enum AppIdentity {
    /// The product name in one place, so a rename is a one-line change.
    /// Bundle IDs, data paths and protocol prefixes are separate decisions.
    static let displayName = "EventKit Bridge"
    static let dataFolderName = "EventKitBridge"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
}

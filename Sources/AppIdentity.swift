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

/// Client names are unique among active clients, compared this way. Shared by
/// the registry, the app's copied commands and `client.py --client NAME`.
enum ClientNames {
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
    }
}

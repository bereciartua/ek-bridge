import AppKit

/// Settings ▸ General ▸ Appearance: follow macOS, or keep the app light or
/// dark whatever macOS uses. The same setting, key and wording as Funes Vault.
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark

    static let defaultsKey = "Appearance"

    /// A missing or unknown value is Automatic.
    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .automatic
    }

    init(defaults: UserDefaults) {
        self.init(stored: defaults.string(forKey: Self.defaultsKey))
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// nil follows macOS.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .automatic: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    var appearance: NSAppearance? { appearanceName.flatMap(NSAppearance.init(named:)) }
}

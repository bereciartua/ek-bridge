import AppKit

@main
struct AppAppearanceTests {
    static func main() {
        // The default, and values a newer or older copy might have written.
        precondition(AppAppearance(stored: nil) == .automatic)
        precondition(AppAppearance(stored: "") == .automatic)
        precondition(AppAppearance(stored: "Dark") == .automatic)
        precondition(AppAppearance(stored: "sepia") == .automatic)
        for choice in AppAppearance.allCases {
            precondition(AppAppearance(stored: choice.rawValue) == choice)
        }
        // The same key and raw values as Funes Vault.
        precondition(AppAppearance.defaultsKey == "Appearance")
        precondition(AppAppearance.allCases.map(\.rawValue) == ["automatic", "light", "dark"])
        // Through user defaults: unset is Automatic, then what was saved.
        let suite = "ek-bridge-appearance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(AppAppearance(defaults: defaults) == .automatic)
        defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.defaultsKey)
        precondition(AppAppearance(defaults: defaults) == .dark)
        // The mapping to NSApp.appearance: nil follows macOS.
        precondition(AppAppearance.automatic.appearanceName == nil)
        precondition(AppAppearance.automatic.appearance == nil)
        precondition(AppAppearance.light.appearanceName == .aqua)
        precondition(AppAppearance.light.appearance?.name == .aqua)
        precondition(AppAppearance.dark.appearanceName == .darkAqua)
        precondition(AppAppearance.dark.appearance?.name == .darkAqua)
        precondition(AppAppearance.allCases.map(\.title) == ["Automatic", "Light", "Dark"])
        print("App appearance: default, stored values, mapping and titles passed")
    }
}

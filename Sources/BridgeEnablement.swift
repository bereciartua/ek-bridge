import Foundation

protocol BridgePreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: BridgePreferenceStore {}

final class BridgeEnablement {
    // New key: the older 15-minute pilot has no persisted enablement state.
    // Missing or malformed values must not silently activate its replacement.
    static let key = "DurableLocalBridgeEnabled"

    private let store: BridgePreferenceStore

    init(store: BridgePreferenceStore = UserDefaults.standard) {
        self.store = store
    }

    var isEnabled: Bool {
        store.object(forKey: Self.key) as? Bool == true
    }

    func setEnabled(_ enabled: Bool) {
        store.set(enabled, forKey: Self.key)
    }
}

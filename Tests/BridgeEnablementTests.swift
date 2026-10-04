import Foundation

@main
struct BridgeEnablementTests {
    static func main() {
        let store = MemoryPreferences()
        let firstLaunch = BridgeEnablement(store: store)
        precondition(!firstLaunch.isEnabled) // No legacy pilot key.
        store.set("true", forKey: BridgeEnablement.key)
        precondition(!firstLaunch.isEnabled) // Malformed state fails closed.
        firstLaunch.setEnabled(true)
        precondition(firstLaunch.isEnabled)
        let restarted = BridgeEnablement(store: store)
        precondition(restarted.isEnabled)
        restarted.setEnabled(false)
        precondition(!BridgeEnablement(store: store).isEnabled)
        print("Bridge enablement: migration off, explicit on, restart restore, disable passed")
    }
}

private final class MemoryPreferences: BridgePreferenceStore {
    private var values = [String: Any]()
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

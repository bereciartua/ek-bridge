import Foundation

// build/rollback-harness: the 0.8.2 registry (Tests/rollback-0.8.2), built
// on its own. `rollback-harness <data folder> [--write]` loads the folder's
// client-registry.json the way 0.8.2 does and prints what it found as JSON
// (counts and IDs only, never names). With --write it then does what 0.8.2
// does on every request (an Activity row, written into the registry) so the
// current code's import can be checked. Exits 1 when 0.8.2 can't load it.
@main
struct RollbackHarness {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: rollback-harness <data folder> [--write]\n".utf8))
            exit(2)
        }
        MainActor.assumeIsolated {
            let registry = ClientRegistry(directory: URL(fileURLWithPath: arguments[1]))
            guard let clients = registry.clients(), let activity = registry.activity() else {
                print(#"{"loaded":false}"#)
                exit(1)
            }
            var wrote = false
            if arguments.contains("--write"), let client = clients.first(where: { !$0.revoked }) {
                let request = BridgeRequest(id: "rollback-\(UUID().uuidString)", command: .scopeStatus,
                                            parameters: [:])
                if case .success(let call) = registry.authorize(clientID: client.id, request: request, origin: .cli) {
                    wrote = registry.recordResult(call, outcome: "success")
                }
            }
            let summary: [String: Any] = [
                "loaded": true,
                "clientIDs": clients.map(\.id).sorted(),
                "active": clients.filter { !$0.revoked }.count,
                "grants": clients.reduce(0) { $0 + $1.grants.count },
                "ask": clients.filter { $0.approval == .ask }.count,
                "paused": clients.filter(\.paused).count,
                "mcp": clients.filter(\.hasMCPToken).count,
                "activityRows": activity.count,
                "wrote": wrote,
            ]
            let data = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        }
    }
}

import Foundation

// Compiled twice by test.sh. The production build writes its identities to the
// file named by the first argument; the live-test build (-D EVENTKIT_LIVE_TEST)
// reads them and checks that each of its own differs, so the test copy can't
// share the installed app's bundle ID, data, transport, ports or server key.
@main
struct LiveTestIsolationTests {
    static func main() {
        let path = CommandLine.arguments[1]
        let values = LiveTestIsolation.Values.current
        #if EVENTKIT_LIVE_TEST
        precondition(AppIdentity.isLiveTest)
        let production = (try? String(contentsOfFile: path, encoding: .utf8))!
            .split(separator: "\n").map(String.init)
        precondition(production.count == values.lines.count, "run the production half first")
        for (mine, theirs) in zip(values.lines, production) {
            let key = mine.prefix { $0 != "=" }
            precondition(theirs.hasPrefix(key + "="), "\(theirs) is out of order")
            precondition(mine != theirs, "the live-test copy shares \(theirs)")
        }
        // ProductionIdentity is what the production build really uses.
        precondition(LiveTestIsolation.Values.production.lines == production)
        precondition(LiveTestIsolation.collisions(values, runningBundleID: AppIdentity.bundleID).isEmpty)
        precondition(LiveTestIsolation.collisions(values, runningBundleID: ProductionIdentity.bundleID)
            == ["bundle ID"])
        var shifted = values
        shifted.mcpPort = ProductionIdentity.remotePort
        precondition(LiveTestIsolation.collisions(shifted, runningBundleID: nil) == ["MCP port"])
        precondition(AppIdentity.toolDataFolder(inSupport: URL(fileURLWithPath: "/var/empty"))
            .lastPathComponent == "EKBridge Live Test")

        // The hard guard: never copy, move, trash or delete the installed app.
        for refused in ["/Applications/EKBridge.app", "/Applications/EKBridge.app/",
                        "/Users/someone/Applications/ekbridge.app", "/Applications/./EKBridge.app",
                        "/Applications/EventKitBridge.app", "EKBridge.app"] {
            precondition(!LiveTestIsolation.mayModifyBundle(atPath: refused), refused)
        }
        for allowed in ["/Applications/EK Bridge Test.app", "/Users/someone/Downloads/ek-test/EK Bridge Test.app",
                        "/Volumes/EK Bridge Test/EK Bridge Test.app"] {
            precondition(LiveTestIsolation.mayModifyBundle(atPath: allowed), allowed)
        }
        print("Live-test isolation: 7 identities differ from production, startup guard, bundle guard passed")
        #else
        precondition(!AppIdentity.isLiveTest)
        precondition(values == .production)
        precondition(LiveTestIsolation.collisions(values, runningBundleID: values.bundleID).count == 7)
        precondition(LiveTestIsolation.mayModifyBundle(atPath: "/Applications/EKBridge.app"))
        precondition((try? values.lines.joined(separator: "\n").write(toFile: path, atomically: true,
                                                                       encoding: .utf8)) != nil)
        #endif
    }
}

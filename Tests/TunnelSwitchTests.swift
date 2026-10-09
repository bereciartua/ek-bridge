import Foundation

/// Plan 08 T06, T07: Switch Tunnel… and Address ▸ Edit…, step by step;
/// the confirmation's lists; remembered addresses.
@main
struct TunnelSwitchTests {
    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition { fatalError("TunnelSwitchTests line \(line): \(message)") }
    }

    static let funnel = "https://my-mac.tail1234.ts.net"
    static let quick = "https://quiet-river-1234.trycloudflare.com"

    static func main() {
        steps()
        tests()
        summary()
        memory()
        print("Tunnel switch: steps, In use, the test before Switch, another tunnel answering, the confirmation's lists and remembered addresses passed")
    }

    static func steps() {
        var change = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: funnel)
        check(change.step == .choose && change.steps == [.choose, .start, .test, .confirm], "starts at Choose")
        check(change.steps.map(change.title) == ["Choose", "Start it", "Paste and test", "Switch"], "header")
        check(!change.canChoose(.tailscaleFunnel) && change.canChoose(.cloudflareQuick) && change.canChoose(.other),
              "the tunnel in use can't be picked")
        change.picked = .cloudflareQuick
        check(change.step == .start, "Start it")
        change.started = true
        check(change.step == .test, "Paste and test")
        change.confirming = true
        check(change.step == .confirm, "Switch")
        // Edit…: the same tunnel, at step 3, with the address in use.
        let edit = TunnelSwitch(kind: .editAddress, fromTunnel: .cloudflareQuick, fromOrigin: quick)
        check(edit.step == .test && edit.picked == .cloudflareQuick && edit.address == quick && edit.addressSource == .inUse,
              "Edit… opens at Paste and test")
        check(edit.steps == [.test, .confirm] && edit.title(.confirm) == "Save", "Paste and test · Save")
        // Step 3's address: the running tunnel's, then the remembered one.
        check(TunnelSwitch.prefill(found: quick, remembered: "https://old.trycloudflare.com") == (quick, .runningTunnel),
              "running tunnel first")
        check(TunnelSwitch.prefill(found: nil, remembered: quick) == (quick, .remembered), "then remembered")
        check(TunnelSwitch.prefill(found: nil, remembered: nil) == ("", .none), "else empty")
    }

    static func tests() {
        var change = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: funnel)
        change.picked = .cloudflareQuick
        change.started = true
        check(!change.canConfirm(normalized: quick), "not before a test")
        change.test = .testing(address: quick)
        check(!change.canConfirm(normalized: quick), "not while testing")
        change.test = .notReachable(address: quick, reason: "No answer.")
        check(!change.canConfirm(normalized: quick), "not when it failed")
        change.test = .reachable(address: quick, ms: 84, tunnel: .cloudflareQuick)
        check(change.canConfirm(normalized: quick) && change.otherTunnel == nil, "reachable through the picked tunnel")
        check(!change.canConfirm(normalized: "https://edited.trycloudflare.com")
              && change.result(for: "https://edited.trycloudflare.com") == .notTested, "an edited address needs a new test")
        check(!change.canConfirm(normalized: nil), "an invalid address")
        // Another tunnel answered.
        change.test = .reachable(address: quick, ms: 84, tunnel: .tailscaleFunnel)
        check(change.otherTunnel == .tailscaleFunnel, "says which tunnel answered")
        change.test = .reachable(address: quick, ms: 84, tunnel: .other)
        check(change.otherTunnel == nil, "an unrecognized tunnel says nothing")
        // Nothing would change: the same address through the same tunnel.
        var edit = TunnelSwitch(kind: .editAddress, fromTunnel: .cloudflareQuick, fromOrigin: quick)
        edit.test = .reachable(address: quick, ms: 50, tunnel: .cloudflareQuick)
        check(!edit.canConfirm(normalized: quick), "the address in use isn't a change")
        edit.test = .reachable(address: "https://new-name-77.trycloudflare.com", ms: 50, tunnel: .cloudflareQuick)
        check(edit.canConfirm(normalized: "https://new-name-77.trycloudflare.com"), "a new quick-tunnel address")
    }

    static func summary() {
        var change = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: funnel)
        change.picked = .cloudflareQuick
        let full = TunnelSwitchSummary.make(change, newOrigin: quick, port: 47616,
                                            remoteTokenClients: ["Claude Code"], oauthApps: ["claude.ai"])
        check(full.mcpURL == quick + "/r/••••••/mcp", "the new URL, secret hidden")
        check(full.updateURLIn == ["Claude Code"] && full.disconnected == ["claude.ai"] && !full.noCloudAgents, "names")
        check(full.stopTunnel == .tailscaleFunnel && full.stopCommands == ["tailscale funnel --bg 47616 off"],
              "then you can stop Tailscale Funnel")
        let none = TunnelSwitchSummary.make(change, newOrigin: quick, port: 47616, remoteTokenClients: [], oauthApps: [])
        check(none.noCloudAgents, "No cloud agents use the current URL yet")
        // Quick tunnel → Tailscale: nothing to stop (Control-C).
        var back = TunnelSwitch(kind: .switchTunnel, fromTunnel: .cloudflareQuick, fromOrigin: quick)
        back.picked = .tailscaleFunnel
        let reverse = TunnelSwitchSummary.make(back, newOrigin: funnel, port: 47616, remoteTokenClients: ["A"], oauthApps: [])
        check(reverse.stopTunnel == nil && reverse.stopCommands.isEmpty, "no off command")
        // The same address through another tunnel: the URL stays.
        let same = TunnelSwitchSummary.make(change, newOrigin: funnel, port: 47616,
                                            remoteTokenClients: ["Claude Code"], oauthApps: ["claude.ai"])
        check(same.noCloudAgents, "nothing to update")
        // Edit… never suggests stopping the tunnel in use.
        let edit = TunnelSwitch(kind: .editAddress, fromTunnel: .tailscaleFunnel, fromOrigin: funnel)
        check(TunnelSwitchSummary.make(edit, newOrigin: "https://other.tail1234.ts.net", port: 47616,
                                       remoteTokenClients: [], oauthApps: []).stopTunnel == nil, "Edit… stops nothing")
    }

    static func memory() {
        let defaults = UserDefaults(suiteName: "tunnel-switch-tests-\(UUID().uuidString)")!
        check(TunnelAddressMemory.load(defaults).isEmpty, "empty")
        TunnelAddressMemory.save([.tailscaleFunnel: funnel, .cloudflareQuick: quick], defaults)
        check(defaults.dictionary(forKey: "RemoteTunnelAddresses") as? [String: String]
              == ["tailscaleFunnel": funnel, "cloudflareQuick": quick], "stored by raw value")
        check(TunnelAddressMemory.load(defaults) == [.tailscaleFunnel: funnel, .cloudflareQuick: quick], "loaded")
        defaults.set(["tailscaleFunnel": funnel, "warp": "https://x", "ngrok": "http://insecure"],
                     forKey: "RemoteTunnelAddresses")
        check(TunnelAddressMemory.load(defaults) == [.tailscaleFunnel: funnel], "unknown tunnels and bad addresses dropped")
        check(TunnelAddressMemory.hostname("https://mcp.example.com") == "mcp.example.com"
              && TunnelAddressMemory.hostname(nil) == nil, "hostname")
    }
}

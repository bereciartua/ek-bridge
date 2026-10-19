import Foundation

// Switch Tunnel… and Address ▸ Edit… (plan 08 T06, T07). BridgeKitRemote's
// TunnelSwitch holds one switch's session-only state; these are EK Bridge's
// words for it, and its off commands for the confirmation.

extension TunnelSwitch {
    func title(_ step: Step) -> String {
        switch step {
        case .choose: String(localized: "Choose")
        case .start: String(localized: "Start it")
        case .test: String(localized: "Paste and test")
        case .confirm: kind == .editAddress ? String(localized: "Save") : String(localized: "Switch")
        }
    }
}

extension TunnelSwitchSummary {
    /// Step 4 with EK Bridge's off commands: only Funnel keeps running in the background, and
    /// `funnelOff` gives its commands for the address being left.
    static func make(_ change: TunnelSwitch, newOrigin: String, port: Int, remoteTokenClients: [String],
                     oauthApps: [String], funnelOff: (String) -> [String]) -> TunnelSwitchSummary {
        make(change, newOrigin: newOrigin, port: port, remoteTokenClients: remoteTokenClients,
             oauthApps: oauthApps, offCommands: { provider, _, origin in
            provider == .tailscaleFunnel ? funnelOff(origin) : []
        })
    }
}

extension TunnelProvider {
    /// The tunnel inside a sentence: "Switch to Tailscale Funnel?", but
    /// "Switch to another tunnel?" for Other tunnel.
    var inSentence: String { self == .other ? String(localized: "another tunnel") : name }
}

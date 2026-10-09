import Foundation

/// Switch Tunnel… and Address ▸ Edit… (plan 08 T06, T07): one switch's
/// session-only state. The tunnel and address in use keep working, and
/// nothing is saved, until Switch (D3). Memory only: Cancel, quitting or
/// turning Remote Access off leaves everything as it was.
struct TunnelSwitch: Equatable {
    enum Kind: Equatable {
        /// Switch Tunnel…: Choose · Start it · Paste and test · Switch.
        case switchTunnel
        /// Address ▸ Edit…: the same tunnel at a new address, Paste and test · Save.
        case editAddress
    }

    enum Step: Int, CaseIterable, Equatable {
        case choose = 1, start, test, confirm
    }

    enum Test: Equatable {
        case notTested
        case testing(address: String)
        case reachable(address: String, ms: Int, tunnel: TunnelProvider?)
        case notReachable(address: String, reason: String)
    }

    /// Where step 3's address came from, for its caption.
    enum AddressSource: Equatable { case none, runningTunnel, remembered, inUse }

    let kind: Kind
    /// The tunnel and address in use when the switch began.
    let fromTunnel: TunnelProvider
    let fromOrigin: String
    var picked: TunnelProvider?
    /// Step 2 is behind us (found, Continue or I've Started It).
    var started = false
    /// Step 2 moved on by itself since it was entered from step 1 (D8).
    var advancedThisEntry = false
    /// Step 3's text field.
    var address = ""
    var addressSource = AddressSource.none
    var test = Test.notTested
    /// Step 4, the confirmation sheet.
    var confirming = false

    init(kind: Kind, fromTunnel: TunnelProvider, fromOrigin: String) {
        self.kind = kind
        self.fromTunnel = fromTunnel
        self.fromOrigin = fromOrigin
        if kind == .editAddress {
            picked = fromTunnel
            started = true
            address = fromOrigin
            addressSource = .inUse
        }
    }

    var step: Step {
        if confirming { return .confirm }
        guard picked != nil else { return .choose }
        return started ? .test : .start
    }

    /// The steps the header shows.
    var steps: [Step] { kind == .editAddress ? [.test, .confirm] : Step.allCases }

    func title(_ step: Step) -> String {
        switch step {
        case .choose: String(localized: "Choose")
        case .start: String(localized: "Start it")
        case .test: String(localized: "Paste and test")
        case .confirm: kind == .editAddress ? String(localized: "Save") : String(localized: "Switch")
        }
    }

    /// The tunnel in use can't be picked: a new address for it is Edit… (§4.3).
    func canChoose(_ provider: TunnelProvider) -> Bool { provider != fromTunnel }

    /// The test result for the address now in the field (nil once it's edited).
    func result(for normalized: String?) -> Test {
        switch test {
        case .notTested: return .notTested
        case .testing(let address), .reachable(let address, _, _), .notReachable(let address, _):
            return address == normalized ? test : .notTested
        }
    }

    /// Switch… (Save…) once the address in the field passed the test, and
    /// something would change.
    func canConfirm(normalized: String?) -> Bool {
        guard let normalized, case .reachable = result(for: normalized) else { return false }
        return normalized != fromOrigin || picked != fromTunnel
    }

    /// A different tunnel answered than the one picked: say so, and offer to
    /// continue as that one. An unrecognized tunnel ("Other") says nothing.
    /// Other tunnel means any tunnel, so a recognized one answering isn't news.
    var otherTunnel: TunnelProvider? {
        guard case .reachable(_, _, let tunnel?) = test, tunnel != .other, tunnel != picked,
              picked != .other else { return nil }
        return tunnel
    }

    /// Step 3's address: the running tunnel's, then the one remembered for it.
    static func prefill(found: String?, remembered: String?) -> (String, AddressSource) {
        if let found { return (found, .runningTunnel) }
        if let remembered { return (remembered, .remembered) }
        return ("", .none)
    }
}

/// Step 4: what switching changes, by name (D5).
struct TunnelSwitchSummary: Equatable {
    let tunnel: TunnelProvider
    /// The new MCP URL with the secret path hidden.
    let mcpURL: String
    /// Connections with cloud access and a remote token: their agents need the new URL.
    let updateURLIn: [String]
    /// Signed-in cloud apps (OAuth): bound to the old URL, so they're disconnected.
    let disconnected: [String]
    /// The old tunnel and its off command, when it has one.
    let stopTunnel: TunnelProvider?
    let stopCommands: [String]

    var noCloudAgents: Bool { updateURLIn.isEmpty && disconnected.isEmpty }

    static func make(_ change: TunnelSwitch, newOrigin: String, port: Int, remoteTokenClients: [String],
                     oauthApps: [String]) -> TunnelSwitchSummary {
        let tunnel = change.picked ?? change.fromTunnel
        // Same address through another tunnel: the URL stays, nothing needs updating.
        let urlChanges = newOrigin != change.fromOrigin
        let stopping = change.kind == .switchTunnel && tunnel != change.fromTunnel
            && !change.fromTunnel.offCommands(port: port).isEmpty
        return TunnelSwitchSummary(
            tunnel: tunnel,
            mcpURL: newOrigin + "/r/••••••/mcp",
            updateURLIn: urlChanges ? remoteTokenClients : [],
            disconnected: urlChanges ? oauthApps : [],
            stopTunnel: stopping ? change.fromTunnel : nil,
            stopCommands: stopping ? change.fromTunnel.offCommands(port: port) : [])
    }
}

extension TunnelProvider {
    /// The tunnel inside a sentence: "Switch to Tailscale Funnel?", but
    /// "Switch to another tunnel?" for Other tunnel.
    var inSentence: String { self == .other ? String(localized: "another tunnel") : name }
}

/// Each tunnel's last address (D2): UserDefaults `RemoteTunnelAddresses`,
/// `{tunnel: address}`, next to `RemoteTunnelChoice`. Never in the registry,
/// so 0.10.x ignores it.
enum TunnelAddressMemory {
    static let key = "RemoteTunnelAddresses"

    static func load(_ defaults: UserDefaults) -> [TunnelProvider: String] {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        var result = [TunnelProvider: String]()
        for (raw, origin) in stored {
            if let provider = TunnelProvider(rawValue: raw), origin.hasPrefix("https://"), origin.count <= 300 {
                result[provider] = origin
            }
        }
        return result
    }

    static func save(_ addresses: [TunnelProvider: String], _ defaults: UserDefaults) {
        defaults.set(Dictionary(uniqueKeysWithValues: addresses.map { ($0.key.rawValue, $0.value) }), forKey: key)
    }

    /// The hostname step 2 pre-fills for Cloudflare Tunnel and ngrok.
    static func hostname(_ origin: String?) -> String? {
        origin.flatMap(URL.init(string:))?.host
    }
}

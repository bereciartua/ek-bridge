import Foundation

// Is the tunnel running on this Mac? (plan 08 §5). BridgeKitRemote's
// TunnelHealth says what each tunnel's tool reports; these are the words EK
// Bridge shows for it. The result is display only: it never changes what the
// server accepts.

extension TunnelHealth {
    /// The pill (plan 08 §1.2).
    var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .wrongPort: String(localized: "Wrong port")
        case .notPublic: String(localized: "Not public")
        case .incomplete: String(localized: "Incomplete")
        case .notRunning(let reason):
            reason == .noSharablePort ? String(localized: "No shareable port") : String(localized: "Not running")
        case .notInstalled: String(localized: "Not installed")
        case .unknown: String(localized: "Can't check on this Mac")
        }
    }

    /// The text next to the pill. `remotePort` is the Remote Access port,
    /// `mcpPort` the local MCP server's.
    func detail(_ provider: TunnelProvider, remotePort: Int, mcpPort: Int) -> String? {
        switch self {
        case .running(_, let port):
            return String(localized: "on this Mac · forwards to \(String(port))")
        case .wrongPort(let port, _):
            return port == mcpPort
                ? String(localized: "Forwards to \(String(port)), the local MCP port. Use \(String(remotePort)).")
                : String(localized: "Forwards to \(String(port)). Use \(String(remotePort)).")
        case .incomplete(_, let missing):
            return missing == 1
                ? String(localized: "Funnel forwards all but one of the Remote Access paths, so cloud agents can't sign in. Add it in Terminal.")
                : String(localized: "Funnel forwards only some of the Remote Access paths (\(String(missing)) missing), so cloud agents can't sign in. Add them in Terminal.")
        case .notPublic:
            return provider == .tailscaleFunnel
                ? String(localized: "Tailscale Serve is on, but Funnel isn't, so cloud agents can't reach it.")
                : String(localized: "It's reachable only from your own network, so cloud agents can't reach it.")
        case .notRunning(let reason):
            switch reason {
            case .loggedOut: return String(localized: "Tailscale is logged out. Open Tailscale and log in.")
            case .funnelNotAllowed:
                return String(localized: "Your tailnet policy doesn't allow Funnel for this Mac. Add the funnel node attribute in the Tailscale admin console.")
            case .stopped:
                return provider == .tailscaleFunnel
                    ? String(localized: "Tailscale is turned off. Turn it on, then start Funnel.")
                    : String(localized: "\(provider.name) runs, but isn't connected yet.")
            case .noTunnel: return nil
            case .noSharablePort:
                return String(localized: "Funnel's ports 443, 8443 and 10000 each have a tailnet-only entry or a TCP forwarder on this Mac, which adding the Remote Access paths would make public or replace. Change one of them, or choose another tunnel.")
            }
        case .notInstalled:
            switch provider {
            case .tailscaleFunnel: return String(localized: "Install Tailscale, or choose another tunnel.")
            case .ngrok: return String(localized: "Install ngrok, or choose another tunnel.")
            default: return String(localized: "Install cloudflared with brew install cloudflared, or choose another tunnel.")
            }
        case .unknown:
            return nil
        }
    }

    /// The Status row's reason when the reachability test failed and this
    /// check explains it (*Tailscale Funnel isn't running on this Mac.*).
    func unreachableReason(_ provider: TunnelProvider, remotePort: Int) -> String? {
        switch self {
        case .notRunning: String(localized: "\(provider.name) isn't running on this Mac.")
        case .wrongPort(let port, _):
            String(localized: "\(provider.name) forwards to port \(String(port)), not \(String(remotePort)).")
        case .incomplete: String(localized: "\(provider.name) forwards only some of the Remote Access paths.")
        case .notPublic: provider == .tailscaleFunnel
            ? String(localized: "Tailscale Serve is on, but Funnel isn't.")
            : String(localized: "\(provider.name) isn't public.")
        case .notInstalled: String(localized: "\(provider.name) isn't installed on this Mac.")
        case .running, .unknown: nil
        }
    }
}

extension TunnelProvider {
    /// The name the reachability test reported (`detect(headers:)`'s name).
    static func named(_ name: String?) -> TunnelProvider? {
        guard let name else { return nil }
        return allCases.first { $0.name == name }
    }

    /// The one command that starts the tunnel once it's set up, for the Tunnel
    /// row's Not running state. Nil for Other tunnel.
    func runCommand(port: Int, hostname: String?, publicPort: Int? = 443, paths: [String] = []) -> String? {
        switch self {
        case .tailscaleFunnel:
            commands(port: port, hostname: hostname, publicPort: publicPort, paths: paths)
                .joined(separator: "\n").nilIfEmpty
        case .cloudflareQuick: commands(port: port, hostname: hostname).first
        case .cloudflareTunnel: "cloudflared tunnel run \(Self.cloudflareTunnelName)"
        case .ngrok: commands(port: port, hostname: hostname).first { $0.hasPrefix("ngrok http ") }
        case .other: nil
        }
    }
}

// MARK: - Funnel's public ports

extension FunnelPorts {
    /// Step 2's line above the commands: that another app on 443 keeps working, why Remote Access
    /// uses another port than 443, or why no port can take its paths. Nil when there's nothing
    /// else on its port, or it already runs or is incomplete.
    var reason: String? {
        guard running == nil, incomplete == nil else { return nil }
        guard let publicPort else {
            let taken = inTheWay.map(Self.describe).formatted(.list(type: .and))
            return String(localized: "No Funnel port on this Mac can take EK Bridge's paths without changing another app: \(taken). Change one of them, or choose another tunnel.")
        }
        if publicPort == Self.cloudAgentPort {
            guard let others = entry(on: publicPort), !others.handlers.isEmpty else { return nil }
            return String(localized: "Funnel's \(Self.describe(others)) already serves another app on this Mac. These commands add only EK Bridge's paths, so it keeps working.")
        }
        let taken = inTheWay.map(Self.describe).formatted(.list(type: .and))
        return String(localized: "Funnel's \(taken) can't take EK Bridge's paths without changing another app, so EK Bridge uses port \(String(publicPort)). claude.ai and ChatGPT only connect to port 443, so they can't reach it there; other cloud agents can.")
    }

    /// "port 443 (it forwards to 47627)", "port 443 (tailnet only, it forwards to 4000)".
    static func describe(_ entry: Entry) -> String {
        let port = String(entry.publicPort)
        let targets = entry.targets.map { String($0) }.formatted(.list(type: .and))
        switch (entry.funnel, entry.targets.isEmpty) {
        case (true, true): return String(localized: "port \(port)")
        case (true, false): return String(localized: "port \(port) (it forwards to \(targets))")
        case (false, true): return String(localized: "port \(port) (tailnet only)")
        case (false, false): return String(localized: "port \(port) (tailnet only, it forwards to \(targets))")
        }
    }

    /// When the check couldn't read what Funnel serves: the 443 commands, with this warning.
    static let unknownWarning = String(localized: "EK Bridge couldn't check what Funnel already serves on this Mac. These commands add only its paths to port 443, but if 443 has a tailnet-only entry from another app, they make that entry public: check with tailscale funnel status first.")
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

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
        case .notRunning(let reason):
            reason == .allPortsTaken ? String(localized: "No free port") : String(localized: "Not running")
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
            case .allPortsTaken:
                return String(localized: "Funnel's three public ports already serve other apps on this Mac. Turn one off, or choose another tunnel.")
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
    func runCommand(port: Int, hostname: String?, publicPort: Int? = 443) -> String? {
        switch self {
        case .tailscaleFunnel, .cloudflareQuick: commands(port: port, hostname: hostname, publicPort: publicPort).first
        case .cloudflareTunnel: "cloudflared tunnel run \(Self.cloudflareTunnelName)"
        case .ngrok: commands(port: port, hostname: hostname).first { $0.hasPrefix("ngrok http ") }
        case .other: nil
        }
    }
}

// MARK: - Funnel's public ports

extension FunnelPorts {
    /// Step 2's line above the commands: why Funnel uses another port than 443, or what's on all
    /// three. Nil when it uses 443 or already runs.
    var reason: String? {
        let taken = inTheWay.map(Self.describe).formatted(.list(type: .and))
        guard !taken.isEmpty else { return nil }
        guard let publicPort else {
            return String(localized: "Funnel already serves other apps on this Mac on \(taken). Starting it would replace one of them, so turn one off first, or choose another tunnel.")
        }
        return inTheWay.count == 1
            ? String(localized: "Funnel already serves another app on this Mac on \(taken), so EK Bridge uses port \(String(publicPort)). Its address ends in :\(String(publicPort)).")
            : String(localized: "Funnel already serves other apps on this Mac on \(taken), so EK Bridge uses port \(String(publicPort)). Its address ends in :\(String(publicPort)).")
    }

    /// "port 443 (it forwards to 47627)".
    static func describe(_ entry: Entry) -> String {
        let port = String(entry.publicPort)
        switch entry.targets.count {
        case 0: return String(localized: "port \(port)")
        case 1: return String(localized: "port \(port) (it forwards to \(String(entry.targets[0])))")
        default:
            let targets = entry.targets.map { String($0) }.formatted(.list(type: .and))
            return String(localized: "port \(port) (it forwards to \(targets))")
        }
    }

    /// When the check couldn't read what Funnel serves: the 443 command, with this warning.
    static let unknownWarning = String(localized: "EK Bridge couldn't check what Funnel already serves on this Mac. If it serves another app on port 443, this command replaces it: check with tailscale funnel status first.")
}

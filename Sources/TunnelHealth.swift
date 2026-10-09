import Foundation

// Is the tunnel running on this Mac? (plan 08 §5). Pure parsers for what each
// tunnel's own tool reports, and the words the app shows for it. The checks
// that collect the input (TunnelChecks.swift) are read-only and local, and
// the result is display only: it never changes what the server accepts.

/// What a tunnel's tool says about it, for the Remote Access port.
enum TunnelHealth: Equatable {
    enum NotRunningReason: Equatable {
        /// The tool runs, but the tunnel isn't connected (Tailscale turned off,
        /// cloudflared not connected to Cloudflare yet).
        case stopped
        /// Tailscale needs a login.
        case loggedOut
        /// The tailnet policy doesn't allow Funnel for this Mac.
        case funnelNotAllowed
        /// No tunnel at all: start it.
        case noTunnel
    }

    /// Forwards to the Remote Access port. `address` is its public https
    /// address when the tool reports it.
    case running(address: String?, port: Int)
    /// Runs, but forwards to another port.
    case wrongPort(port: Int, address: String?)
    /// Tailscale Serve without Funnel: reachable from the tailnet only.
    case notPublic(address: String?)
    case notRunning(reason: NotRunningReason)
    case notInstalled
    /// Other tunnel, or the check failed or timed out: the reachability test
    /// is the only signal.
    case unknown

    enum Tone: Equatable { case ok, warn, neutral }

    /// The pill (plan 08 §1.2).
    var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .wrongPort: String(localized: "Wrong port")
        case .notPublic: String(localized: "Not public")
        case .notRunning: String(localized: "Not running")
        case .notInstalled: String(localized: "Not installed")
        case .unknown: String(localized: "Can't check on this Mac")
        }
    }

    var tone: Tone {
        switch self {
        case .running: .ok
        case .wrongPort, .notPublic, .notRunning: .warn
        case .notInstalled, .unknown: .neutral
        }
    }

    /// While Remote Access is on, these mean cloud agents can't get through (D10).
    var warns: Bool {
        switch self {
        case .wrongPort, .notPublic, .notRunning: true
        case .running, .notInstalled, .unknown: false
        }
    }

    /// The public address the tool reported, if any.
    var address: String? {
        switch self {
        case .running(let address, _), .wrongPort(_, let address), .notPublic(let address): address
        case .notRunning, .notInstalled, .unknown: nil
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

    /// Whether the start command helps: the tunnel isn't up, but nothing else is in the way.
    var showsStartCommand: Bool {
        if case .notRunning(let reason) = self { return reason == .noTunnel || reason == .stopped }
        return false
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

    /// For the page's VoiceOver label and the live-test state.
    var code: String {
        switch self {
        case .running: "running"
        case .wrongPort: "wrongPort"
        case .notPublic: "notPublic"
        case .notRunning(let reason): "notRunning.\(reason)"
        case .notInstalled: "notInstalled"
        case .unknown: "unknown"
        }
    }
}

extension TunnelProvider {
    /// What the address looks like (D4): `.ts.net` is Tailscale Funnel,
    /// `.trycloudflare.com` a quick tunnel, ngrok's domains ngrok. Nil when it
    /// could be anything (a Cloudflare Tunnel or ngrok on your own domain).
    static func detect(address: String?) -> TunnelProvider? {
        guard let host = address.flatMap(URL.init(string:))?.host?.lowercased() else { return nil }
        if host.hasSuffix(".ts.net") { return .tailscaleFunnel }
        if host.hasSuffix(".trycloudflare.com") { return .cloudflareQuick }
        if ngrokDomains.contains(where: { host.hasSuffix($0) }) { return .ngrok }
        return nil
    }

    /// The name the reachability test reported (`detect(headers:)`'s name).
    static func named(_ name: String?) -> TunnelProvider? {
        guard let name else { return nil }
        return allCases.first { $0.name == name }
    }

    /// The one command that starts the tunnel once it's set up, for the Tunnel
    /// row's Not running state. Nil for Other tunnel.
    func runCommand(port: Int, hostname: String?) -> String? {
        switch self {
        case .tailscaleFunnel, .cloudflareQuick: commands(port: port, hostname: hostname).first
        case .cloudflareTunnel: "cloudflared tunnel run \(Self.cloudflareTunnelName)"
        case .ngrok: commands(port: port, hostname: hostname).first { $0.hasPrefix("ngrok http ") }
        case .other: nil
        }
    }

    /// Where to get the tool, for Not installed.
    var installLink: String? {
        switch self {
        case .tailscaleFunnel: "https://tailscale.com/download/mac"
        case .ngrok: "https://ngrok.com/download"
        case .cloudflareTunnel, .cloudflareQuick, .other: nil
        }
    }
}

/// The Tunnel row's name (D4): the tunnel that answered the last test, then
/// what the address looks like, then the stored choice, so it can't disagree
/// with the address. A test answered by an unrecognized tunnel ("Other")
/// says less than the address or the choice, so it's used last.
enum TunnelLabel {
    static func resolve(lastTested: TunnelProvider?, address: String?, stored: TunnelProvider) -> TunnelProvider {
        if let lastTested, lastTested != .other { return lastTested }
        if let detected = TunnelProvider.detect(address: address) { return detected }
        if lastTested == .other, stored != .other, address != nil {
            // A Cloudflare Tunnel or ngrok on your own domain answers with no
            // header of its own: keep the choice.
            return stored
        }
        return lastTested ?? stored
    }
}

/// Reads JSON a CLI printed, skipping anything before the first `{` (the
/// `tailscale` CLI prints a version-mismatch warning on some installs).
enum ToolJSON {
    static func object(_ data: Data?) -> [String: Any]? {
        guard let data, let start = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data[start...])) as? [String: Any]
    }

    /// The port a forwarding target names: `http://127.0.0.1:47616`,
    /// `http://localhost:47616/`, `localhost:47616`, `127.0.0.1:47616` or `47616`.
    /// Nil for anything else, including targets on another machine.
    static func localPort(_ target: String) -> Int? {
        var text = target.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["http://", "https://", "tcp://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        if let port = Int(text) { return (1...65_535).contains(port) ? port : nil }
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["127.0.0.1", "localhost", "[::1]"].contains(parts[0]),
              let port = Int(parts[1]), (1...65_535).contains(port) else { return nil }
        return port
    }

    /// `https://<host>`, with `:<port>` unless it's 443.
    static func origin(host: String, port: Int) -> String {
        "https://" + host.lowercased() + (port == 443 ? "" : ":\(port)")
    }
}

/// `tailscale status --json` and `tailscale funnel status --json`.
enum TailscaleStatus {
    static func parse(status: Data?, funnel: Data?, port: Int) -> TunnelHealth {
        guard let status = ToolJSON.object(status) else { return .unknown }
        switch status["BackendState"] as? String {
        case "Running": break
        case "NeedsLogin", "NoState", "NeedsMachineAuth": return .notRunning(reason: .loggedOut)
        case "Stopped": return .notRunning(reason: .stopped)
        default: return .unknown
        }
        let me = status["Self"] as? [String: Any]
        guard let config = ToolJSON.object(funnel) else { return .unknown }
        let web = config["Web"] as? [String: Any] ?? [:]
        let allowFunnel = config["AllowFunnel"] as? [String: Any] ?? [:]
        // Each served host:port and the local ports its handlers forward to;
        // 443 first, so the usual address wins.
        let served: [(key: String, host: String, port: Int, targets: [Int], funnel: Bool)] = web.compactMap { key, value in
            guard let colon = key.lastIndex(of: ":"), let servePort = Int(key[key.index(after: colon)...]) else { return nil }
            let host = String(key[..<colon])
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            let targets = handlers.values.compactMap { ($0 as? [String: Any])?["Proxy"] as? String }
                .compactMap(ToolJSON.localPort)
            return (key, host, servePort, targets, allowFunnel[key] as? Bool == true)
        }.sorted { ($0.port == 443 ? 0 : 1, $0.port) < ($1.port == 443 ? 0 : 1, $1.port) }
        if let entry = served.first(where: { $0.funnel && $0.targets.contains(port) }) {
            return .running(address: ToolJSON.origin(host: entry.host, port: entry.port), port: port)
        }
        let capMap = me?["CapMap"] as? [String: Any]
        let capabilities = me?["Capabilities"] as? [String] ?? []
        let funnelAllowed = capMap.map { $0.keys.contains("funnel") } ?? true || capabilities.contains("funnel")
        if !funnelAllowed { return .notRunning(reason: .funnelNotAllowed) }
        if let entry = served.first(where: { $0.targets.contains(port) }) {
            return .notPublic(address: ToolJSON.origin(host: entry.host, port: entry.port))
        }
        // Only Funnel entries count as "this tunnel, at the wrong port": a
        // Serve entry for another app on this Mac isn't shown (plan 08 §5.5).
        if let entry = served.first(where: { $0.funnel && !$0.targets.isEmpty }) {
            return .wrongPort(port: entry.targets.min()!, address: ToolJSON.origin(host: entry.host, port: entry.port))
        }
        return .notRunning(reason: .noTunnel)
    }
}

/// One cloudflared metrics server (`127.0.0.1:20241…20245`): `/ready`,
/// `/quicktunnel` and `/config`, as fetched.
struct CloudflaredEndpoint: Equatable {
    var ready: Data?
    var quickTunnel: Data?
    var config: Data?
}

/// cloudflared: named tunnels and quick tunnels.
enum CloudflaredStatus {
    /// `quick` picks quick tunnels (`--url`, a trycloudflare.com address) or
    /// named ones. `processes` are the arguments of running cloudflared
    /// processes (the fallback when no metrics server answers);
    /// `configFile` is `~/.cloudflared/config.yml` (or `--config`'s file).
    static func parse(quick: Bool, endpoints: [CloudflaredEndpoint], processes: [[String]], configFile: String?,
                      port: Int, installed: Bool) -> TunnelHealth {
        let fileRules = configFile.map(ingress(yaml:)) ?? []
        var notReady = false
        var elsewhere: (port: Int, address: String?)?
        for endpoint in endpoints {
            let hostname = (ToolJSON.object(endpoint.quickTunnel)?["hostname"] as? String)?.lowercased() ?? ""
            guard hostname.isEmpty != quick else { continue }
            let rules = endpoint.config.map(ingress(json:)) ?? (quick ? [] : fileRules)
            let ready = (ToolJSON.object(endpoint.ready)?["readyConnections"] as? Int ?? 0) > 0
            guard ready else { notReady = true; continue }
            func address(_ rule: (hostname: String, port: Int)?) -> String? {
                if quick { return hostname.isEmpty ? nil : "https://" + hostname }
                guard let name = rule?.hostname, !name.isEmpty else { return nil }
                return "https://" + name
            }
            if let rule = rules.first(where: { $0.port == port }) {
                return .running(address: address(rule), port: port)
            }
            if let rule = rules.first, elsewhere == nil { elsewhere = (rule.port, address(rule)) }
            if rules.isEmpty && quick { return .running(address: address(nil), port: port) }
        }
        if let elsewhere { return .wrongPort(port: elsewhere.port, address: elsewhere.address) }
        if notReady { return .notRunning(reason: .stopped) }
        // No metrics server answered: look at the processes.
        let matching = processes.filter { args in
            let isQuick = TunnelProcess.cloudflaredURLPort(args) != nil
            return isQuick == quick && (quick || args.contains("run"))
        }
        if !matching.isEmpty {
            if quick {
                let ports = matching.compactMap(TunnelProcess.cloudflaredURLPort)
                if ports.contains(port) { return .running(address: nil, port: port) }
                return .wrongPort(port: ports[0], address: nil)
            }
            if let rule = fileRules.first(where: { $0.port == port }) {
                return .running(address: rule.hostname.isEmpty ? nil : "https://" + rule.hostname, port: port)
            }
            return .unknown
        }
        return installed ? .notRunning(reason: .noTunnel) : .notInstalled
    }

    /// `/config`'s `{"config": {"ingress": [{"hostname", "service"}]}}`.
    static func ingress(json data: Data) -> [(hostname: String, port: Int)] {
        let config = ToolJSON.object(data)?["config"] as? [String: Any]
        let rules = config?["ingress"] as? [[String: Any]] ?? []
        return rules.compactMap { rule in
            guard let service = rule["service"] as? String, let port = ToolJSON.localPort(service) else { return nil }
            return ((rule["hostname"] as? String ?? "").lowercased(), port)
        }
    }

    /// The `ingress` rules of a config.yml: `hostname:` / `service:` pairs,
    /// read line by line (not a YAML parser; quotes and comments are dropped).
    static func ingress(yaml text: String) -> [(hostname: String, port: Int)] {
        var rules = [(hostname: String, port: Int)]()
        var inIngress = false
        var hostname = ""
        func value(_ line: Substring, after key: String) -> String {
            var text = line.drop { $0 == " " || $0 == "-" }.dropFirst(key.count)
            if let hash = text.firstIndex(of: "#") { text = text[..<hash] }
            return text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")[...]
            if !line.hasPrefix(" ") && !line.hasPrefix("-") && !line.isEmpty && !line.hasPrefix("#") {
                inIngress = line.hasPrefix("ingress:")
                continue
            }
            guard inIngress else { continue }
            let trimmed = line.drop { $0 == " " || $0 == "-" }
            if trimmed.hasPrefix("hostname:") {
                hostname = value(line, after: "hostname:").lowercased()
            } else if trimmed.hasPrefix("service:") {
                let service = value(line, after: "service:")
                if let port = ToolJSON.localPort(service) { rules.append((hostname, port)) }
                hostname = ""
            }
        }
        return rules
    }
}

/// ngrok's agent API: `GET /api/tunnels`.
enum NgrokStatus {
    static func parse(apiTunnels data: Data?, port: Int) -> TunnelHealth {
        guard let object = ToolJSON.object(data), let tunnels = object["tunnels"] as? [[String: Any]] else {
            return .unknown
        }
        let found: [(address: String?, port: Int)] = tunnels.compactMap { tunnel in
            guard let addr = (tunnel["config"] as? [String: Any])?["addr"] as? String,
                  let target = ToolJSON.localPort(addr) else { return nil }
            let url = tunnel["public_url"] as? String
            return (url.flatMap(RemoteOriginText.normalized), target)
        }
        if let match = found.first(where: { $0.port == port }) {
            return .running(address: match.address, port: port)
        }
        if let other = found.first { return .wrongPort(port: other.port, address: other.address) }
        return .notRunning(reason: .noTunnel)
    }
}

/// The fallback when a tool's local status endpoint is off: the arguments of
/// a running process (same user only).
enum TunnelProcess {
    /// `cloudflared tunnel --url http://127.0.0.1:47616` (or `--url=…`).
    static func cloudflaredURLPort(_ args: [String]) -> Int? {
        value(args, "--url").flatMap(ToolJSON.localPort)
    }

    /// `ngrok http 47616` (or `localhost:47616`, `http://localhost:47616`).
    static func ngrokPort(_ args: [String]) -> Int? {
        guard let index = args.firstIndex(of: "http"), index + 1 < args.count else { return nil }
        return args[(index + 1)...].first { !$0.hasPrefix("-") }.flatMap(ToolJSON.localPort)
    }

    /// `--config` of a named cloudflared tunnel, if given.
    static func cloudflaredConfig(_ args: [String]) -> String? { value(args, "--config") }

    private static func value(_ args: [String], _ flag: String) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == flag, index + 1 < args.count { return args[index + 1] }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}

/// `https://host[:port]` from a tool's public URL, like `RemoteConfiguration.normalizedOrigin`.
enum RemoteOriginText {
    static func normalized(_ text: String) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return "https://" + host.lowercased() + (url.port.map { ":\($0)" } ?? "")
    }
}

import Foundation

/// Plan 08 T01: what each tunnel's tool reports, parsed from fixtures
/// (`Tests/tunnel-health/`; Tailscale's captured on a real Mac, anonymized),
/// the Tunnel row's name and the words for each state.
@main
struct TunnelHealthTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("tunnel-health")

    static func fixture(_ name: String) -> Data {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) else {
            fatalError("missing fixture \(name)")
        }
        return data
    }

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition { fatalError("TunnelHealthTests line \(line): \(message)") }
    }

    static func main() {
        tailscale()
        funnelPorts()
        cloudflared()
        ngrok()
        processes()
        labels()
        words()
        schedule()
        startStep()
        print("Tunnel health: Tailscale, cloudflared and ngrok parsers, the Tunnel row's name, state words and the check schedule passed")
    }

    /// The public paths for a sample secret.
    static let paths = RemoteConfiguration(secret: "q7Zk2vN4bXwP9sL1mT6hYa", publicOrigin: nil, port: 47616).publicPaths

    static func tailscale() {
        let status = fixture("tailscale-status.json")
        let funnel = fixture("tailscale-funnel.json")
        let parse = { (status: Data?, funnel: Data?, port: Int) in
            TailscaleStatus.parse(status: status, funnel: funnel, port: port, paths: paths, mistakenPorts: [MCPDefaults.port])
        }
        // The real config: Funnel on 443 → 47616, and another app's Serve entry on 8443.
        check(parse(status, funnel, 47616) == .running(address: "https://my-mac.tail1234.ts.net", port: 47616), "running")
        // Another port (the test copy's, or Funes Vault's 47627): 443 and 8443 belong to other apps,
        // not to this tunnel at the wrong port. Not started yet; 443 is public, so its paths go there.
        check(parse(status, funnel, 47626) == .notRunning(reason: .noTunnel), "other apps' entries aren't wrong port")
        let shared = FunnelPorts.parse(funnel: funnel, port: 47626, paths: paths)
        check(shared?.publicPort == 443 && shared?.inTheWay.isEmpty == true, "443 shared by path")
        check(TailscaleStatus.parse(status: status, funnel: fixture("tailscale-funnel-wrong-port.json"), port: 47616,
                                    paths: paths) == .notRunning(reason: .noTunnel),
              "a port not named as a mistake is another app's")
        check(parse(status, fixture("tailscale-funnel-warning.txt"), 47616)
              == .running(address: "https://my-mac.tail1234.ts.net", port: 47616), "version warning before the JSON")
        var warned = Data("Warning: client version \"1\" != tailscaled server version \"2\"\n".utf8)
        warned.append(status)
        check(parse(warned, funnel, 47616) == .running(address: "https://my-mac.tail1234.ts.net", port: 47616),
              "warning before the status JSON")
        check(parse(status, fixture("tailscale-funnel-serve-only.json"), 47616)
              == .notPublic(address: "https://my-mac.tail1234.ts.net"), "Serve without Funnel")
        check(parse(status, fixture("tailscale-funnel-wrong-port.json"), 47616)
              == .wrongPort(port: 47615, address: "https://my-mac.tail1234.ts.net"), "Funnel to the MCP port")
        check(parse(status, fixture("tailscale-funnel-8443.json"), 47616)
              == .running(address: "https://my-mac.tail1234.ts.net:8443", port: 47616), "8443, localhost and a slash")
        check(parse(status, fixture("tailscale-funnel-none.json"), 47616) == .notRunning(reason: .noTunnel), "no Funnel")
        check(parse(fixture("tailscale-status-logged-out.json"), Data("{}".utf8), 47616) == .notRunning(reason: .loggedOut),
              "logged out")
        check(parse(fixture("tailscale-status-stopped.json"), funnel, 47616) == .notRunning(reason: .stopped), "stopped")
        check(parse(fixture("tailscale-status-no-funnel.json"), fixture("tailscale-funnel-serve-only.json"), 47616)
              == .notRunning(reason: .funnelNotAllowed), "Funnel not allowed in the policy")
        // A Funnel entry that runs wins over the policy check (CapMap can lag).
        check(parse(fixture("tailscale-status-no-funnel.json"), funnel, 47616)
              == .running(address: "https://my-mac.tail1234.ts.net", port: 47616), "running despite CapMap")
        check(parse(nil, funnel, 47616) == .unknown, "no status")
        check(parse(Data("not json".utf8), funnel, 47616) == .unknown, "garbage")
        check(parse(status, nil, 47616) == .unknown, "no funnel status")
        check(parse(Data(#"{"BackendState":"Starting"}"#.utf8), funnel, 47616) == .unknown, "an unknown state")
        // What Tailscale.app's binary prints when it doesn't run as the CLI (0.11.0's bug).
        check(parse(Data("The Tailscale GUI failed to start: The operation couldn’t be completed.\n".utf8), nil, 47616)
              == .unknown, "the GUI answer")
        // An app opened from Finder has no SHLVL or TERM: the CLI is asked for by name.
        let environment = TailscaleStatus.cliEnvironment(["HOME": "/Users/test", "PATH": "/usr/bin:/bin"])
        check(environment == ["HOME": "/Users/test", "PATH": "/usr/bin:/bin", "TAILSCALE_BE_CLI": "1"],
              "TAILSCALE_BE_CLI added, the rest kept")
    }

    /// Funes Vault and EK Bridge on one Mac, sharing Funnel's port 443 by path: the commands and words.
    static func funnelPorts() {
        func entry(_ port: Int, _ handlers: [(String, Int, String)], funnel: Bool) -> FunnelPorts.Entry {
            FunnelPorts.Entry(publicPort: port, host: "my-mac.tail1234.ts.net",
                              handlers: handlers.map { FunnelPorts.Handler(path: $0.0, port: $0.1, targetPath: $0.2) },
                              funnel: funnel)
        }
        func ports(_ entries: [FunnelPorts.Entry]) -> FunnelPorts { FunnelPorts(entries: entries, port: 47616, paths: paths) }
        let funnel = TunnelProvider.tailscaleFunnel
        let commands = funnel.commands(port: 47616, hostname: nil, paths: paths)
        check(commands.count == 4 && commands.allSatisfy { $0.hasPrefix("tailscale funnel --bg --https=443 --set-path /") },
              "443: one command per path")
        check(funnel.commands(port: 47616, hostname: nil, publicPort: nil, paths: paths).isEmpty
              && funnel.runCommand(port: 47616, hostname: nil, publicPort: nil, paths: paths) == nil, "no port: no command")
        check(ports([]).reason == nil, "nothing served: no line")
        // Funes Vault set up first, by path on 443: EK Bridge adds its own paths beside them.
        let funesPaths = RemoteConfiguration(secret: "Zz9Yy8Xx7Ww6Vv5Uu4Tt3S", publicOrigin: nil, port: 47627).publicPaths
        let funes = ports([entry(443, funesPaths.map { ($0, 47627, $0) }, funnel: true)])
        check(funes.publicPort == 443 && funes.reason?.contains("These commands add only EK Bridge's paths") == true,
              "Funes Vault on 443 keeps working")
        let tailnet = ports([entry(443, [("/", 4000, "")], funnel: false)])
        check(tailnet.publicPort == 8443 && tailnet.reason?.contains("claude.ai and ChatGPT only connect to port 443") == true,
              "a tailnet-only 443: 8443, with the warning")
        // EK Bridge's own setup from before: / of 443. Still running, and its off command names /.
        let legacy = ports([entry(443, [("/", 47616, "")] + funesPaths.map { ($0, 47627, $0) }, funnel: true)])
        check(legacy.running?.publicPort == 443 && legacy.reason == nil, "/ from before is running")
        check(TailscaleFunnelCommand.off(legacy, address: nil, paths: paths) == ["tailscale funnel --https=443 --set-path / off"],
              "turning off / leaves Funes Vault's paths")
        let none = TunnelHealth.notRunning(reason: .noSharablePort)
        check(none.label == "No shareable port" && none.detail(funnel, remotePort: 47616, mcpPort: 47615)?.isEmpty == false,
              "No shareable port's words")
        let incomplete = TunnelHealth.incomplete(address: nil, missing: 2)
        check(incomplete.label == "Incomplete" && incomplete.detail(funnel, remotePort: 47616, mcpPort: 47615)?.contains("2 missing") == true,
              "Incomplete's words")
        check(FunnelPorts.unknownWarning.hasPrefix("EK Bridge couldn't check"), "unknown")
        // 0.11.3's drafts on 8443 move to 443 once 443 can take the paths, running or not.
        let on8443 = ports([entry(443, funesPaths.map { ($0, 47627, $0) }, funnel: true), entry(8443, [("/", 47616, "")], funnel: true)])
        let address = "https://my-mac.tail1234.ts.net:8443"
        let running = TunnelHealth.running(address: address, port: 47616)
        let move = FunnelPorts.Move.inUse(provider: funnel, health: running, ports: on8443, address: address)
        check(move?.start == TailscaleFunnelCommand.start(port: 47616, paths: paths)
              && move?.off == ["tailscale funnel --https=8443 --set-path / off"] && move?.address == "https://my-mac.tail1234.ts.net",
              "running on 8443: 443's paths, then / of 8443 off")
        check(move?.intro.contains("claude.ai and ChatGPT only connect to Funnel's port 443") == true
              && move?.after.last == "Then change the address to https://my-mac.tail1234.ts.net with Address ▸ Edit….",
              "the move's words")
        let notRunning = ports([entry(443, funesPaths.map { ($0, 47627, $0) }, funnel: true)])
        check(FunnelPorts.Move.inUse(provider: funnel, health: .notRunning(reason: .noTunnel), ports: notRunning,
                                     address: address)?.off == [], "not running: 443's commands instead of 8443's")
        check(FunnelPorts.Move.inUse(provider: funnel, health: .notRunning(reason: .loggedOut), ports: notRunning,
                                     address: address) == nil, "log in first")
        check(FunnelPorts.Move.inUse(provider: funnel, health: nil, ports: on8443, address: address) == nil, "not checked")
        check(FunnelPorts.Move.inUse(provider: .cloudflareTunnel, health: running, ports: on8443, address: address) == nil,
              "not Funnel")
        check(FunnelPorts.Move.inUse(provider: funnel, health: .running(address: nil, port: 47616), ports: legacy,
                                     address: "https://my-mac.tail1234.ts.net") == nil, "/ of 443 stays as it is")
        check(FunnelPorts.Move.inUse(provider: funnel, health: running,
                                     ports: ports([entry(443, [("/", 4000, "")], funnel: false), entry(8443, [("/", 47616, "")], funnel: true)]),
                                     address: address) == nil, "a tailnet-only 443 would become public")
    }

    static func cloudflared() {
        let ready = fixture("cloudflared-ready.json")
        let quick = CloudflaredEndpoint(ready: ready, quickTunnel: fixture("cloudflared-quicktunnel.json"),
                                        config: fixture("cloudflared-config-quick.json"))
        let named = CloudflaredEndpoint(ready: ready, quickTunnel: fixture("cloudflared-quicktunnel-named.json"),
                                        config: nil)
        let yaml = String(decoding: fixture("cloudflared-config.yml"), as: UTF8.self)
        func parse(_ isQuick: Bool, _ endpoints: [CloudflaredEndpoint], processes: [[String]] = [],
                   config: String? = nil, port: Int = 47616, installed: Bool = true) -> TunnelHealth {
            CloudflaredStatus.parse(quick: isQuick, endpoints: endpoints, processes: processes, configFile: config,
                                    port: port, installed: installed)
        }
        check(parse(true, [quick]) == .running(address: "https://quiet-river-1234.trycloudflare.com", port: 47616),
              "quick tunnel")
        check(parse(true, [quick], port: 47626) == .wrongPort(port: 47616, address: "https://quiet-river-1234.trycloudflare.com"),
              "quick tunnel to another port")
        // Without /config (older cloudflared): the quick tunnel is taken as running.
        check(parse(true, [CloudflaredEndpoint(ready: ready, quickTunnel: quick.quickTunnel, config: nil)])
              == .running(address: "https://quiet-river-1234.trycloudflare.com", port: 47616), "no /config")
        check(parse(true, [CloudflaredEndpoint(ready: fixture("cloudflared-not-ready.json"), quickTunnel: quick.quickTunnel,
                                               config: quick.config)]) == .notRunning(reason: .stopped), "not connected yet")
        // A quick tunnel isn't a named one, and the other way round.
        check(parse(false, [quick]) == .notRunning(reason: .noTunnel), "quick isn't named")
        check(parse(true, [named], config: yaml) == .notRunning(reason: .noTunnel), "named isn't quick")
        check(parse(false, [named], config: yaml) == .running(address: "https://mcp.example.com", port: 47616),
              "named, from config.yml")
        check(parse(false, [CloudflaredEndpoint(ready: ready, quickTunnel: named.quickTunnel,
                                                config: fixture("cloudflared-config-named.json"))])
              == .running(address: "https://mcp.example.com", port: 47616), "named, from /config")
        check(parse(false, [named], config: yaml, port: 47626) == .wrongPort(port: 8080, address: "https://wiki.example.com"),
              "named, another port")
        // Two metrics servers: the second one is ours.
        check(parse(true, [CloudflaredEndpoint(ready: ready, quickTunnel: Data(#"{"hostname":"other-name-9.trycloudflare.com"}"#.utf8),
                                               config: Data(#"{"config":{"ingress":[{"service":"http://127.0.0.1:8080"}]}}"#.utf8)),
                           quick]) == .running(address: "https://quiet-river-1234.trycloudflare.com", port: 47616),
              "the matching tunnel among several")
        // No metrics server: the processes.
        let quickArgs = ["cloudflared", "tunnel", "--url", "http://127.0.0.1:47616", "--http-host-header", "127.0.0.1:47616"]
        check(parse(true, [], processes: [quickArgs]) == .running(address: nil, port: 47616), "quick tunnel process")
        check(parse(true, [], processes: [quickArgs], port: 47626) == .wrongPort(port: 47616, address: nil), "process, another port")
        check(parse(false, [], processes: [["cloudflared", "tunnel", "run", "ek-bridge"]], config: yaml)
              == .running(address: "https://mcp.example.com", port: 47616), "named process with config.yml")
        check(parse(false, [], processes: [["cloudflared", "tunnel", "run", "ek-bridge"]]) == .unknown,
              "named process without details")
        check(parse(true, []) == .notRunning(reason: .noTunnel), "nothing running")
        check(parse(true, [], installed: false) == .notInstalled, "not installed")
        // config.yml rules, line by line.
        let rules = CloudflaredStatus.ingress(yaml: yaml)
        check(rules.map(\.hostname) == ["wiki.example.com", "mcp.example.com"] && rules.map(\.port) == [8080, 47616],
              "two ingress rules, quotes dropped, http_status skipped")
        check(CloudflaredStatus.ingress(yaml: "tunnel: x\ningress:\n\t- hostname: a.example.com # mine\n\t  service: localhost:47616\n")
              .map(\.port) == [47616], "tabs and comments")
        check(CloudflaredStatus.ingress(yaml: "ingress:\n  - service: http://192.168.1.2:47616\n").isEmpty,
              "another machine isn't this Mac")
    }

    static func ngrok() {
        let tunnels = fixture("ngrok-tunnels.json")
        check(NgrokStatus.parse(apiTunnels: tunnels, port: 47616)
              == .running(address: "https://my-mac-example.ngrok-free.app", port: 47616), "ngrok to the port")
        check(NgrokStatus.parse(apiTunnels: tunnels, port: 47626)
              == .wrongPort(port: 8080, address: "https://wiki-example.ngrok-free.app"), "ngrok elsewhere")
        check(NgrokStatus.parse(apiTunnels: fixture("ngrok-empty.json"), port: 47616) == .notRunning(reason: .noTunnel),
              "no tunnels")
        check(NgrokStatus.parse(apiTunnels: nil, port: 47616) == .unknown, "no answer")
        for addr in ["http://localhost:47616", "localhost:47616", "47616", "127.0.0.1:47616", "http://127.0.0.1:47616/"] {
            check(ToolJSON.localPort(addr) == 47616, addr)
        }
        for addr in ["http://example.com:47616", "file:///tmp", "localhost", "70000", "http_status:404"] {
            check(ToolJSON.localPort(addr) == nil, addr)
        }
    }

    static func processes() {
        check(TunnelProcess.cloudflaredURLPort(["cloudflared", "tunnel", "--url=http://localhost:47626"]) == 47626, "--url=")
        check(TunnelProcess.cloudflaredURLPort(["cloudflared", "tunnel", "run", "x"]) == nil, "named")
        check(TunnelProcess.ngrokPort(["ngrok", "http", "47616", "--url", "https://x.ngrok-free.app"]) == 47616, "ngrok port")
        check(TunnelProcess.ngrokPort(["ngrok", "http", "--url", "https://x.ngrok-free.app", "localhost:47616"]) == nil,
              "a flag value isn't the port")
        check(TunnelProcess.cloudflaredConfig(["cloudflared", "--config", "/tmp/c.yml", "tunnel", "run"]) == "/tmp/c.yml", "--config")
    }

    static func schedule() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let interval = TunnelCheckSchedule.interval
        check(interval(false, false) == nil && interval(false, true) == nil, "nothing while Remote Access is off")
        check(interval(true, false) == 60 && interval(true, true) == 3, "60 s while on, 3 s while waiting in step 2")
        let due = { (last: Date?, seconds: TimeInterval?) in TunnelCheckSchedule.isDue(lastCheck: last, now: now, interval: seconds) }
        check(due(nil, 60) && !due(nil, nil), "first check")
        check(!due(now.addingTimeInterval(-59), 60) && due(now.addingTimeInterval(-60), 60), "60 s")
        check(!due(now.addingTimeInterval(-2.9), 3) && due(now.addingTimeInterval(-3), 3), "3 s")
        check(due(now.addingTimeInterval(30), 60), "a clock that went back")
        check(!due(now.addingTimeInterval(-3600), nil), "never while off")
    }

    static func startStep() {
        let make = TunnelStartState.make
        let running = TunnelHealth.running(address: "https://quiet-river-1234.trycloudflare.com", port: 47616)
        check(make(false, .tailscaleFunnel, running) == .turnOn, "off: turn on first")
        check(make(true, .tailscaleFunnel, nil) == .waiting, "not checked yet")
        check(make(true, .tailscaleFunnel, .notRunning(reason: .noTunnel)) == .waiting, "waiting")
        check(make(true, .cloudflareQuick, running) == .found(address: "https://quiet-river-1234.trycloudflare.com"), "found")
        check(make(true, .tailscaleFunnel, .wrongPort(port: 47615, address: nil)) == .problem(.wrongPort(port: 47615, address: nil)),
              "wrong port stays")
        check(make(true, .tailscaleFunnel, .notRunning(reason: .loggedOut)) == .problem(.notRunning(reason: .loggedOut)),
              "logged out stays with the reason")
        check(make(true, .other, running) == .cantCheck(nil), "Other is never checked")
        check(make(true, .ngrok, .notInstalled).offersStarted && make(true, .ngrok, .unknown).offersStarted, "I've Started It")
        check(!make(true, .ngrok, nil).offersStarted && !make(true, .ngrok, running).offersStarted, "…only when it can't tell")
        // Once per entry into step 2; Continue after Back.
        let found = make(true, .cloudflareQuick, running)
        check(found.autoAdvances(advancedThisEntry: false) && !found.autoAdvances(advancedThisEntry: true), "once")
        check(found.offersContinue && !TunnelStartState.waiting.autoAdvances(advancedThisEntry: false), "Continue")
        // Hostnames typed into step 2.
        check(TunnelProvider.hostname(" https://MCP.example.com/ ") == "mcp.example.com", "scheme and slash dropped")
        check(TunnelProvider.hostname("my name.example.com") == nil && TunnelProvider.hostname("localhost") == nil, "not a hostname")
        check(TunnelProvider.cloudflareTunnel.asksForHostname && TunnelProvider.ngrok.asksForHostname
              && !TunnelProvider.cloudflareQuick.asksForHostname, "who asks")
    }

    static func labels() {
        // By domain.
        check(TunnelProvider.detect(address: "https://my-mac.tail1234.ts.net") == .tailscaleFunnel, ".ts.net")
        check(TunnelProvider.detect(address: "https://quiet-river-1234.trycloudflare.com") == .cloudflareQuick, "quick")
        check(TunnelProvider.detect(address: "https://my-mac-example.ngrok-free.app") == .ngrok, "ngrok")
        check(TunnelProvider.detect(address: "https://mcp.example.com") == nil, "own domain")
        check(TunnelProvider.detect(address: nil) == nil, "no address")
        // D4: the tunnel that answered, then the address, then the choice.
        let resolve = TunnelLabel.resolve
        check(resolve(.cloudflareTunnel, "https://my-mac.tail1234.ts.net", .tailscaleFunnel) == .cloudflareTunnel, "tested first")
        check(resolve(nil, "https://my-mac.tail1234.ts.net", .cloudflareTunnel) == .tailscaleFunnel,
              "the address beats a stale choice (the snap-back bug)")
        check(resolve(nil, "https://mcp.example.com", .cloudflareTunnel) == .cloudflareTunnel, "own domain: the choice")
        check(resolve(.other, "https://mcp.example.com", .ngrok) == .ngrok, "an unrecognized answer keeps the choice")
        check(resolve(.other, "https://my-mac.tail1234.ts.net", .ngrok) == .tailscaleFunnel, "…but not over the address")
        check(resolve(.other, "https://mcp.example.com", .other) == .other, "Other stays Other")
        check(resolve(nil, nil, .ngrok) == .ngrok, "nothing else: the choice")
        check(TunnelProvider.named("Cloudflare quick tunnel") == .cloudflareQuick && TunnelProvider.named(nil) == nil, "named")
    }

    static func words() {
        let running = TunnelHealth.running(address: "https://my-mac.tail1234.ts.net", port: 47616)
        check(running.label == "Running" && running.tone == .ok && !running.warns, "running words")
        check(running.detail(.tailscaleFunnel, remotePort: 47616, mcpPort: 47615) == "on this Mac · forwards to 47616",
              "running detail")
        let wrong = TunnelHealth.wrongPort(port: 47615, address: nil)
        check(wrong.label == "Wrong port" && wrong.warns, "wrong port")
        check(wrong.detail(.cloudflareQuick, remotePort: 47616, mcpPort: 47615)
              == "Forwards to 47615, the local MCP port. Use 47616.", "names the local MCP port")
        check(TunnelHealth.wrongPort(port: 8080, address: nil).detail(.ngrok, remotePort: 47616, mcpPort: 47615)
              == "Forwards to 8080. Use 47616.", "another port")
        check(TunnelHealth.notPublic(address: nil).detail(.tailscaleFunnel, remotePort: 47616, mcpPort: 47615)
              == "Tailscale Serve is on, but Funnel isn't, so cloud agents can't reach it.", "not public")
        let stopped = TunnelHealth.notRunning(reason: .noTunnel)
        check(stopped.label == "Not running" && stopped.warns && stopped.showsStartCommand, "not running")
        check(!TunnelHealth.notRunning(reason: .loggedOut).showsStartCommand, "logged out: log in first")
        check(TunnelHealth.notRunning(reason: .loggedOut).detail(.tailscaleFunnel, remotePort: 47616, mcpPort: 47615)
              == "Tailscale is logged out. Open Tailscale and log in.", "logged out")
        check(TunnelHealth.notInstalled.label == "Not installed" && !TunnelHealth.notInstalled.warns, "not installed")
        check(TunnelHealth.notInstalled.detail(.tailscaleFunnel, remotePort: 47616, mcpPort: 47615)
              == "Install Tailscale, or choose another tunnel.", "install words")
        check(TunnelHealth.unknown.label == "Can't check on this Mac" && TunnelHealth.unknown.tone == .neutral
              && !TunnelHealth.unknown.warns, "can't check")
        // Tunnel down (D10): only while Remote Access is on with an address.
        check(TunnelHealth.isDown(remoteActive: true, health: stopped), "down")
        check(!TunnelHealth.isDown(remoteActive: false, health: stopped), "not while off")
        check(!TunnelHealth.isDown(remoteActive: true, health: .unknown) && !TunnelHealth.isDown(remoteActive: true, health: nil)
              && !TunnelHealth.isDown(remoteActive: true, health: .notInstalled), "can't tell isn't down")
        check(TunnelHealth.isDown(remoteActive: true, health: wrong), "wrong port is down")
        // The Status row when the test failed.
        check(stopped.unreachableReason(.tailscaleFunnel, remotePort: 47616) == "Tailscale Funnel isn't running on this Mac.",
              "failure text")
        check(wrong.unreachableReason(.cloudflareQuick, remotePort: 47616)
              == "Cloudflare quick tunnel forwards to port 47615, not 47616.", "wrong port failure text")
        check(running.unreachableReason(.tailscaleFunnel, remotePort: 47616) == nil
              && TunnelHealth.unknown.unreachableReason(.other, remotePort: 47616) == nil, "nothing to explain")
        // Start commands and install links.
        check(TunnelProvider.tailscaleFunnel.runCommand(port: 47616, hostname: nil, paths: [paths[0]])
              == "tailscale funnel --bg --https=443 --set-path /r/q7Zk2vN4bXwP9sL1mT6hYa http://127.0.0.1:47616/r/q7Zk2vN4bXwP9sL1mT6hYa",
              "funnel")
        check(TunnelProvider.cloudflareTunnel.runCommand(port: 47616, hostname: "mcp.example.com") == "cloudflared tunnel run ek-bridge",
              "named")
        check(TunnelProvider.ngrok.runCommand(port: 47616, hostname: "x.ngrok-free.app")
              == "ngrok http 47616 --url https://x.ngrok-free.app --host-header=rewrite", "ngrok")
        check(TunnelProvider.cloudflareQuick.runCommand(port: 47616, hostname: nil)?.hasPrefix("cloudflared tunnel --url") == true,
              "quick")
        check(TunnelProvider.other.runCommand(port: 47616, hostname: nil) == nil, "other")
        check(TunnelProvider.tailscaleFunnel.installLink == "https://tailscale.com/download/mac"
              && TunnelProvider.ngrok.installLink == "https://ngrok.com/download", "links")
    }
}

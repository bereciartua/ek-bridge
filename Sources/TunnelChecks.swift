import Darwin
import Foundation

/// Is the tunnel running on this Mac? (plan 08 §5). Asks the tunnel's own
/// tool, read-only: the `tailscale` CLI's status commands, cloudflared's
/// metrics server, ngrok's agent API, and this user's process list. Nothing
/// is started, stopped or changed, nothing leaves the Mac (HTTP goes to
/// 127.0.0.1 only, without credentials), and the answer is display only.
/// The UI-review build passes a fake.
struct TunnelChecks {
    /// Checks one tunnel for the Remote Access port; the answer arrives on the main queue.
    var check: (TunnelProvider, Int, @escaping (TunnelHealth) -> Void) -> Void

    static let unavailable = TunnelChecks { _, _, done in DispatchQueue.main.async { done(.unknown) } }

    static let live = TunnelChecks { provider, port, done in
        DispatchQueue.global(qos: .utility).async {
            let health = TunnelProbes.check(provider, port: port)
            DispatchQueue.main.async { done(health) }
        }
    }
}

enum TunnelProbes {
    /// Each command and each request gives up quickly, so a hung tool never
    /// holds up the page (§5.4).
    static let commandTimeout: TimeInterval = 2
    static let requestTimeout: TimeInterval = 1
    static let cloudflaredMetricsPorts = 20241...20245
    static let ngrokAPIPorts = [4040, 4041, 4042]

    static func check(_ provider: TunnelProvider, port: Int) -> TunnelHealth {
        switch provider {
        case .tailscaleFunnel: return tailscale(port: port)
        case .cloudflareTunnel: return cloudflared(quick: false, port: port)
        case .cloudflareQuick: return cloudflared(quick: true, port: port)
        case .ngrok: return ngrok(port: port)
        case .other: return .unknown
        }
    }

    // MARK: Tailscale

    /// The app's built-in CLI first: it always matches the daemon.
    static let tailscaleCandidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                      "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    static func tailscale(port: Int) -> TunnelHealth {
        guard let cli = locate("tailscale", candidates: tailscaleCandidates) else { return .notInstalled }
        // Fixed arguments, stdout only: the CLI warns about version mismatches on stderr.
        guard let status = ProcessRunner.run(cli, ["status", "--json"], timeout: commandTimeout, mergeErrors: false),
              !status.timedOut else { return .unknown }
        let funnel = ProcessRunner.run(cli, ["funnel", "status", "--json"], timeout: commandTimeout, mergeErrors: false)
        return TailscaleStatus.parse(status: Data(status.output.utf8),
                                     funnel: funnel.flatMap { $0.timedOut ? nil : Data($0.output.utf8) }, port: port)
    }

    // MARK: cloudflared

    static func cloudflared(quick: Bool, port: Int) -> TunnelHealth {
        var endpoints = [CloudflaredEndpoint]()
        for metrics in cloudflaredMetricsPorts {
            let base = "http://127.0.0.1:\(metrics)"
            // /ready answers 503 while connecting, with a body that says so.
            guard let ready = get(base + "/ready", acceptAnyStatus: true) else { continue }
            endpoints.append(CloudflaredEndpoint(ready: ready, quickTunnel: get(base + "/quicktunnel"),
                                                 config: get(base + "/config")))
        }
        let processes = RunningProcesses.arguments(named: "cloudflared")
        var configFile: String?
        if !quick {
            let path = processes.lazy.compactMap(TunnelProcess.cloudflaredConfig).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared/config.yml").path
            configFile = readSmallFile(path)
        }
        let installed = !processes.isEmpty || locate("cloudflared", candidates: ["/opt/homebrew/bin/cloudflared",
                                                                                "/usr/local/bin/cloudflared"]) != nil
        return CloudflaredStatus.parse(quick: quick, endpoints: endpoints, processes: processes,
                                       configFile: configFile, port: port, installed: installed)
    }

    // MARK: ngrok

    static func ngrok(port: Int) -> TunnelHealth {
        for api in ngrokAPIPorts {
            if let body = get("http://127.0.0.1:\(api)/api/tunnels"),
               case let health = NgrokStatus.parse(apiTunnels: body, port: port), health != .unknown {
                return health
            }
        }
        let processes = RunningProcesses.arguments(named: "ngrok")
        let ports = processes.compactMap(TunnelProcess.ngrokPort)
        if ports.contains(port) { return .running(address: nil, port: port) }
        if let other = ports.first { return .wrongPort(port: other, address: nil) }
        if !processes.isEmpty { return .unknown }
        let installed = locate("ngrok", candidates: ["/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok"]) != nil
        return installed ? .notRunning(reason: .noTunnel) : .notInstalled
    }

    // MARK: Helpers

    /// Fixed install locations, then a login shell's `command -v` (remembered
    /// for a minute, so the 3-second checks in the guide don't start a shell each time).
    static func locate(_ name: String, candidates: [String]) -> String? {
        if let found = candidates.first(where: ExecutableLocator.live.isExecutable) { return found }
        return LookupCache.shared.value(name) {
            ExecutableLocator.live.loginShellLookup(name).flatMap { path -> String? in
                let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
                return path.hasPrefix("/") && ExecutableLocator.live.isExecutable(path) ? path : nil
            }
        }
    }

    /// One GET to 127.0.0.1 with a 1-second timeout, no cache and no cookies.
    static func get(_ url: String, acceptAnyStatus: Bool = false) -> Data? {
        guard let url = URL(string: url), url.host == "127.0.0.1" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout + 0.5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        let result = Box()
        session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, acceptAnyStatus || http.statusCode == 200,
               let data, data.count <= 262_144 {
                result.data = data
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + requestTimeout + 1)
        return result.data
    }

    private final class Box: @unchecked Sendable { var data: Data? }

    static func readSmallFile(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.size] as? Int ?? .max) <= 65_536,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private final class LookupCache: @unchecked Sendable {
        static let shared = LookupCache()
        private let lock = NSLock()
        private var entries = [String: (path: String?, at: Date)]()

        func value(_ name: String, lookup: () -> String?) -> String? {
            lock.lock()
            if let entry = entries[name], Date().timeIntervalSince(entry.at) < 60 { lock.unlock(); return entry.path }
            lock.unlock()
            let path = lookup()
            lock.lock()
            entries[name] = (path, Date())
            lock.unlock()
            return path
        }
    }
}

/// This user's running processes, by executable name, with their arguments
/// (`proc_listallpids`, `proc_pidpath`, `KERN_PROCARGS2`). Read-only.
enum RunningProcesses {
    static func arguments(named name: String) -> [[String]] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let uid = getuid()
        var result = [[String]]()
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  (String(cString: path) as NSString).lastPathComponent == name,
                  let arguments = arguments(pid) else { continue }
            result.append(arguments)
        }
        return result
    }

    /// argc, the executable path, padding, then argc NUL-terminated arguments.
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments = [String]()
        var start = index
        while index < size && arguments.count < argc {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return arguments
    }
}

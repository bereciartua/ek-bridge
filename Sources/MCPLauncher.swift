import Darwin
import Foundation

// bridge-mcp: a dumb pipe between agents and the in-app MCP server. It relays
// stdio to HTTP on 127.0.0.1, prints headers for Claude Code's headersHelper,
// and diagnoses setups. No MCP logic and no grants: the server decides
// everything. Foundation and Darwin only, built with SafePath + AppIdentity.

enum LauncherExit {
    static let ok: Int32 = 0
    static let tokenRejected: Int32 = 1
    static let usage: Int32 = 2
    static let unavailable: Int32 = 3
    static let localFile: Int32 = 4
}

struct LauncherError: Error {
    let exitCode: Int32
    let message: String

    static func usage(_ message: String) -> LauncherError {
        LauncherError(exitCode: LauncherExit.usage, message: message)
    }
}

enum Log {
    private static let lock = NSLock()

    /// One line per problem, prefixed so agents' MCP logs show where it came
    /// from. Callers never pass the token.
    static func line(_ text: String) {
        raw("bridge-mcp: " + text)
    }

    static func raw(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        Output.write(STDERR_FILENO, Data((text + "\n").utf8))
    }
}

enum Output {
    private static let lock = NSLock()

    /// One stdout line per reply, never interleaved.
    static func line(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        write(STDOUT_FILENO, data + Data([10]))
    }

    static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return }
                offset += count
            }
        }
    }
}

// MARK: - Paths

enum LauncherPaths {
    // Test builds (-D EVENTKIT_MCP_TEST) never touch the real support folder:
    // without the override they point at a path that doesn't exist.
    static var supportDirectory: String {
        #if EVENTKIT_MCP_TEST
        return ProcessInfo.processInfo.environment["EVENTKIT_TEST_SUPPORT_DIR"]
            ?? "/var/empty/eventkit-bridge-test-support"
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true).path
        #endif
    }

    static func tokenFile(clientID: UUID) -> String {
        supportDirectory + "/client-credentials/" + clientID.uuidString.lowercased() + ".mcp-token"
    }

    static var endpointFile: String { supportDirectory + "/mcp-endpoint.json" }

    static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Arguments

struct LauncherInvocation {
    enum Mode { case relay, headers, check, help, version }

    var mode = Mode.relay
    var client: UUID?
    var tokenFile: String?
    var url: String?

    var tokenPath: String { tokenFile ?? LauncherPaths.tokenFile(clientID: client!) }

    static func parse(_ arguments: [String]) throws -> LauncherInvocation {
        var result = LauncherInvocation()
        var help = false, version = false
        var command: String?
        var clientValue: String?
        var firstError: LauncherError?
        func record(_ error: LauncherError) { if firstError == nil { firstError = error } }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--help" || argument == "-h" {
                help = true
            } else if argument == "--version" {
                version = true
            } else if argument.hasPrefix("-") {
                var name = argument
                var value: String?
                if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                    name = String(argument[..<equals])
                    value = String(argument[argument.index(after: equals)...])
                }
                guard ["--client", "--token-file", "--url"].contains(name) else {
                    record(.usage("unknown option \"\(name)\". Run bridge-mcp --help."))
                    continue
                }
                if value == nil, index < arguments.count, !arguments[index].hasPrefix("--") {
                    value = arguments[index]
                    index += 1
                }
                guard let value, !value.isEmpty else {
                    record(.usage("option \"\(name)\" needs a value. Run bridge-mcp --help."))
                    continue
                }
                let duplicate: Bool
                switch name {
                case "--client":
                    duplicate = clientValue != nil
                    clientValue = clientValue ?? value
                case "--token-file":
                    duplicate = result.tokenFile != nil
                    result.tokenFile = result.tokenFile ?? value
                default:
                    duplicate = result.url != nil
                    result.url = result.url ?? value
                }
                if duplicate { record(.usage("option \"\(name)\" was given more than once.")) }
            } else if command == nil && index == 1 {
                command = argument
                if argument != "headers" && argument != "check" {
                    record(.usage("unknown command \"\(argument)\". Run bridge-mcp --help."))
                }
            } else {
                record(.usage("unexpected argument \"\(argument)\". Run bridge-mcp --help."))
            }
        }

        result.mode = command == "headers" ? .headers : command == "check" ? .check : .relay
        if help { result.mode = .help; return result }
        if version { result.mode = .version; return result }
        if let firstError { throw firstError }
        if result.url != nil && result.mode != .headers {
            throw LauncherError.usage("--url is only for bridge-mcp headers.")
        }
        if clientValue != nil && result.tokenFile != nil {
            throw LauncherError.usage("use --client or --token-file, not both.")
        }
        if let clientValue {
            // Agent configs must survive renames, and the launcher never reads
            // the registry, so only the ID is accepted.
            guard let uuid = UUID(uuidString: clientValue.trimmingCharacters(in: .whitespaces)) else {
                throw LauncherError.usage(
                    "--client takes the client's ID (a UUID), not its name. "
                        + "Copy the setup from the client's page in \(AppIdentity.displayName).")
            }
            result.client = uuid
        } else if result.tokenFile == nil {
            throw LauncherError.usage("missing --client or --token-file. Run bridge-mcp --help.")
        }
        return result
    }
}

enum LauncherHelp {
    static let text = """
        Usage: bridge-mcp --client ID                     stdio MCP relay
               bridge-mcp --token-file PATH               stdio relay, explicit token file
               bridge-mcp headers --client ID --url URL   for Claude Code's headersHelper
               bridge-mcp check --client ID               diagnose a setup
               bridge-mcp --help | --version

        Connects an agent on this Mac to \(AppIdentity.displayName)'s MCP server. The relay reads one
        JSON-RPC message per stdin line, posts it to the server and writes each reply as one
        stdout line. Problems go to stderr. Copy the setup for your agent from the client's
        page in \(AppIdentity.displayName).

        Options:
          --client ID         The client's ID (a UUID). Its token file is read from
                              ~/Library/Application Support/\(AppIdentity.dataFolderName)/client-credentials.
          --token-file PATH   Read the token from this file (mode 600) instead.
          --url URL           headers only: the URL in the agent's config. The token is
                              printed only when it's the URL the app serves and the listener
                              there is this user's \(AppIdentity.displayName).
                              CLAUDE_CODE_MCP_SERVER_URL takes precedence when set.

        Exit codes:
          0  ok (relay: stdin closed)
          1  check: token rejected
          2  usage error
          3  check, headers: app or server unavailable, or another program on its port
          4  missing or unsafe token file
        headers prints {} on stdout whenever it refuses, with the reason on stderr.

        """
}

// MARK: - Token file

enum TokenFile {
    static let maxBytes = 128
    static let prefix = "ekb_mcp_v1_"

    /// Same rule as ClientRegistry.validMCPToken: prefix + 64 lowercase hex.
    static func validShape(_ token: String) -> Bool {
        token.utf8.count == 75 && token.hasPrefix(prefix) &&
            token.utf8.dropFirst(11).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The token, or exit-4 errors worded like bridge-client's.
    static func read(_ path: String) throws -> String {
        let data: Data
        do {
            data = try SafePath.readFile(path, maxBytes: maxBytes)
        } catch SafePath.Problem.missing {
            throw problem("token file not found: \(path)")
        } catch SafePath.Problem.tooLarge {
            throw notTokenFile(path)
        } catch let failure as SafePath.Problem {
            throw unsafe(failure, path: path)
        }
        guard let token = String(data: data, encoding: .utf8), validShape(token) else {
            throw notTokenFile(path)
        }
        return token
    }

    static func mode(_ path: String) -> String {
        var details = stat()
        guard lstat(path, &details) == 0 else { return "?" }
        return String(details.st_mode & 0o777, radix: 8)
    }

    private static func notTokenFile(_ path: String) -> LauncherError {
        problem("\(path) isn't an MCP token file for \(AppIdentity.displayName).")
    }

    private static func problem(_ message: String) -> LauncherError {
        LauncherError(exitCode: LauncherExit.localFile, message: message)
    }

    private static func unsafe(_ failure: SafePath.Problem, path: String) -> LauncherError {
        switch failure {
        case .missing: return problem("token file not found: \(path)")
        case .symlink: return problem("\(path) is a symbolic link.")
        case .otherOwner: return problem("\(path) is owned by another user.")
        case .sharedMode(let mode):
            return problem("\(path) can be read by other users (mode \(mode)). Fix: chmod 600 \(path)")
        case .wrongType(let expected): return problem("\(path) isn't a \(expected).")
        case .tooLarge: return notTokenFile(path)
        case .unreadable(let code): return problem("can't read \(path): \(String(cString: strerror(code))).")
        }
    }
}

// MARK: - Endpoint file

struct Endpoint: Equatable {
    let url: URL
    let port: Int
    let pid: pid_t
    let startedAt: Int
}

enum EndpointFile {
    enum Failure: Error {
        /// No file: the app isn't running or its server is off.
        case missing
        /// Present but not trustworthy; never send anything based on it.
        case invalid(String)
    }

    static func read() -> Result<Endpoint, Failure> {
        let path = LauncherPaths.endpointFile
        let data: Data
        do {
            data = try SafePath.readFile(path, maxBytes: 1_024)
        } catch SafePath.Problem.missing {
            return .failure(.missing)
        } catch {
            return .failure(.invalid("\(LauncherPaths.display(path)) isn't private or readable"))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == 1,
              let port = (object["port"] as? NSNumber)?.intValue, (1_024...65_535).contains(port),
              let pidValue = (object["pid"] as? NSNumber)?.intValue, let pid = pid_t(exactly: pidValue),
              pid > 0
        else { return .failure(.invalid("\(LauncherPaths.display(path)) isn't valid")) }
        // Exact match, so a tampered file can't send the token anywhere but
        // IPv4 loopback.
        let expected = "http://127.0.0.1:\(port)/mcp"
        guard object["url"] as? String == expected, let url = URL(string: expected) else {
            return .failure(.invalid("\(LauncherPaths.display(path)) names a URL other than "
                                     + "http://127.0.0.1:<port>/mcp"))
        }
        let startedAt = (object["startedAt"] as? NSNumber)?.intValue ?? 0
        return .success(Endpoint(url: url, port: port, pid: pid, startedAt: startedAt))
    }
}

// MARK: - Listener verification (threat T9)

enum ListenerCheck {
    enum Failure: Error {
        /// The process in the endpoint file is gone: treated as "not running".
        case gone
        case mismatch(String)
    }

    /// Confirms the endpoint's pid is this user's EventKit Bridge and holds a
    /// TCP listener on 127.0.0.1:port, before the token is sent there.
    static func verify(_ endpoint: Endpoint) -> Failure? {
        let pid = endpoint.pid
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
            if kill(pid, 0) != 0 && errno == ESRCH { return .gone }
            return .mismatch("process \(pid) belongs to another user")
        }
        guard info.pbi_uid == getuid() else { return .mismatch("process \(pid) belongs to another user") }
        guard let path = executablePath(pid) else { return .gone }
        if let problem = identityProblem(path, pid: pid) { return .mismatch(problem) }
        guard holdsLoopbackListener(pid, port: endpoint.port) else {
            return .mismatch("process \(pid) isn't listening on 127.0.0.1:\(endpoint.port)")
        }
        return nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    #if EVENTKIT_MCP_TEST
    // Test builds stand a plain harness binary in for the app bundle; uid and
    // socket checks stay real.
    private static func identityProblem(_ path: String, pid: pid_t) -> String? {
        guard let expected = ProcessInfo.processInfo.environment["EVENTKIT_MCP_TEST_SERVER_PATH"] else {
            return "EVENTKIT_MCP_TEST_SERVER_PATH isn't set"
        }
        var resolved = expected
        if let real = realpath(expected, nil) {
            resolved = String(cString: real)
            free(real)
        }
        return resolved == path ? nil : "process \(pid) (\(path)) isn't the test server"
    }
    #else
    private static func identityProblem(_ path: String, pid: pid_t) -> String? {
        guard let own = executablePath(getpid()).flatMap(enclosingBundleIdentifier) else {
            return "bridge-mcp isn't inside the \(AppIdentity.displayName) app"
        }
        guard enclosingBundleIdentifier(path) == own else {
            return "process \(pid) (\(path)) isn't \(AppIdentity.displayName)"
        }
        return nil
    }
    #endif

    /// The CFBundleIdentifier of `…/X.app/Contents/MacOS/<executable>`. Bundle.main
    /// isn't used: for this tool it needn't be the app.
    static func enclosingBundleInfo(_ executable: String) -> [String: Any]? {
        let macOS = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    static func enclosingBundleIdentifier(_ executable: String) -> String? {
        guard let identifier = enclosingBundleInfo(executable)?["CFBundleIdentifier"] as? String,
              !identifier.isEmpty else { return nil }
        return identifier
    }

    private static func holdsLoopbackListener(_ pid: pid_t, port: Int) -> Bool {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let filled = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return false }
        let loopback = UInt32(0x7F00_0001).bigEndian
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            let address = tcp.tcpsi_ini
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_lport)))
            if tcp.tcpsi_state == TSI_S_LISTEN, localPort == port,
               address.insi_vflag & UInt8(INI_IPV4) != 0,
               address.insi_laddr.ina_46.i46a_addr4.s_addr == loopback {
                return true
            }
        }
        return false
    }
}

// MARK: - HTTP

enum Wire {
    /// The modern revision `check` speaks (MCPServer.modernVersions).
    static let modernVersion = "2026-07-28"
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaClientName = "dev.eventkitbridge/client"
    static let timeout: TimeInterval = 60

    struct Reply {
        let status: Int
        let retryAfter: String?
        let body: Data
    }

    enum Failure: Error {
        case refused
        case timedOut
        case lost
        case cancelled
        case other(Int)
    }

    static func headerSafe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x20...0x7E).contains($0) } &&
            value.first != " " && value.last != " "
    }

    /// `Mcp-Name` in plain form when header-safe, else `=?base64?…?=`.
    static func encodedName(_ name: String) -> String {
        headerSafe(name) && !name.hasPrefix("=?")
            ? name : "=?base64?" + Data(name.utf8).base64EncodedString() + "?="
    }

    static func headers(token: String, method: String?, name: String?, version: String?)
        -> [(String, String)] {
        var headers = [("Authorization", "Bearer " + token),
                       ("Content-Type", "application/json"),
                       ("Accept", "application/json, text/event-stream")]
        if let method, headerSafe(method) { headers.append(("Mcp-Method", method)) }
        if method == "tools/call", let name { headers.append(("Mcp-Name", encodedName(name))) }
        if let version, headerSafe(version) { headers.append(("MCP-Protocol-Version", version)) }
        return headers
    }

    /// One fresh ephemeral session per request: a pooled keep-alive connection
    /// the server closed while idle could fail a write ambiguously. Loopback
    /// connections are cheap, and cancelling a task always closes its socket.
    static func post(_ url: URL, body: Data, headers: [(String, String)],
                     completion: @escaping @Sendable (Result<Reply, Failure>) -> Void) -> URLSessionTask {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                let code = (error as? URLError)?.code
                switch code {
                case .cancelled?: completion(.failure(.cancelled))
                case .timedOut?: completion(.failure(.timedOut))
                case .cannotConnectToHost?, .cannotFindHost?, .notConnectedToInternet?,
                     .dnsLookupFailed?:
                    completion(.failure(.refused))
                case .networkConnectionLost?: completion(.failure(.lost))
                default: completion(.failure(.other((error as NSError).code)))
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.other(0)))
                return
            }
            completion(.success(Reply(status: http.statusCode,
                                      retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                      body: data ?? Data())))
        }
        task.resume()
        session.finishTasksAndInvalidate()
        return task
    }

    static func postAndWait(_ url: URL, body: Data, headers: [(String, String)]) -> Result<Reply, Failure> {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        _ = post(url, body: body, headers: headers) { result in
            box.value = result
            done.signal()
        }
        done.wait()
        return box.value ?? .failure(.other(0))
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result<Reply, Failure>?
    }
}

/// Never follow a redirect: the token must only ever go to the verified listener.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - JSON-RPC helpers

enum RPC {
    static func error(id: Any?, code: Int, message: String) -> Data {
        serialize(["jsonrpc": "2.0", "id": id ?? NSNull(),
                   "error": ["code": code, "message": message] as [String: Any]])
    }

    /// Compact JSON. JSONSerialization escapes control characters, so the
    /// result never contains a raw newline.
    static func serialize(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal"}}"#.utf8)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Cancellation matches ids by type and value, like JSON-RPC does.
    static func key(_ id: Any?) -> String? {
        switch id {
        case let string as String: return "s:" + string
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return "n:" + number.stringValue
        default: return nil
        }
    }
}

enum RelayText {
    private static let app = AppIdentity.displayName
    static let notRunning = "\(app) isn't running, or its MCP server is off. "
        + "Open \(app) and turn on Settings ▸ MCP Server."
    static let timeout = "No response from \(app) after 60 s. If this was a change, it may have happened. "
        + "Read before retrying."
    static let lost = "\(app) closed the connection before replying. If this was a change, it may have "
        + "happened. Read before retrying."
    static let squatter = "Another program is using \(app)'s port. "
        + "Open \(app) and check Settings ▸ MCP Server."
    static let badEndpoint = "\(app)'s endpoint file isn't valid, so nothing was sent. "
        + "Quit and reopen \(app)."
    static let rejected = "\(app) doesn't recognize this client's token. "
        + "Open the client in \(app) and check MCP access."

    static func refused(_ status: Int, _ explanation: String) -> String {
        "\(app) refused the request (HTTP \(status)): \(explanation)"
    }

    static func explain(_ status: Int, body: Data, retryAfter: String?) -> String {
        if let message = (RPC.object(body)?["error"] as? [String: Any])?["message"] as? String,
           !message.isEmpty {
            return message
        }
        switch status {
        case 403: return "requests from web pages or tunnels aren't accepted."
        case 405: return "only POST is accepted."
        case 406: return "the Accept header was refused."
        case 413: return "the message is larger than the server accepts."
        case 415: return "the Content-Type was refused."
        case 421: return "the Host header didn't match the server's address."
        case 429: return "too many failed sign-ins on this Mac. Try again in \(retryAfter ?? "60") s."
        default: return "unexpected reply."
        }
    }
}

// MARK: - Relay

final class Relay: @unchecked Sendable {
    static let maxLineBytes = 1 << 20
    static let graceSeconds: TimeInterval = 5
    static let graceInterval: TimeInterval = 0.2

    private struct Message {
        let body: Data
        let method: String?
        let id: Any?
        let key: String?
        let params: [String: Any]?
        /// Requests get exactly one stdout line; notifications and the
        /// client's own responses get none.
        let expectsReply: Bool
    }

    private final class Pending {
        var task: URLSessionTask?
        var cancelled = false
    }

    private enum Prepared {
        case ready(Endpoint, String)
        case unavailable(String?)
        case refused(String)
    }

    private let tokenPath: String
    private let lock = NSLock()
    private var token: String
    private var negotiatedVersion: String?
    private var pending = [String: Pending]()
    private var graceDeadline: Date?
    private let inFlight = DispatchGroup()

    init(tokenPath: String, token: String) {
        self.tokenPath = tokenPath
        self.token = token
    }

    func run() -> Never {
        readLines()
        // EOF: give in-flight replies a moment, then leave.
        _ = inFlight.wait(timeout: .now() + Self.graceSeconds)
        exit(LauncherExit.ok)
    }

    private func readLines() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var line = Data()
        var skipping = false
        func append(_ bytes: ArraySlice<UInt8>) {
            guard !skipping else { return }
            if line.count + bytes.count > Self.maxLineBytes {
                skipping = true
                line = Data()
            } else {
                line.append(contentsOf: bytes)
            }
        }
        func emit() {
            if skipping {
                Log.line("skipped a message longer than 1 MiB.")
            } else {
                handle(line)
            }
            skipping = false
            line = Data()
        }
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            var chunk = buffer[0..<count]
            while let newline = chunk.firstIndex(of: 10) {
                append(chunk[chunk.startIndex..<newline])
                emit()
                chunk = chunk[(newline + 1)...]
            }
            append(chunk)
        }
        if skipping || !line.isEmpty { emit() }
    }

    private func handle(_ raw: Data) {
        var data = raw
        if data.last == 13 { data.removeLast() }
        guard data.contains(where: { ![9, 10, 13, 32].contains($0) }) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            Log.line("skipped a line that isn't valid JSON.")
            return
        }
        guard let object = json as? [String: Any] else {
            Log.line("skipped a line that isn't a JSON-RPC object (batches aren't supported).")
            return
        }
        let id = object["id"].flatMap { $0 is NSNull ? nil : $0 }
        let message = Message(body: data, method: object["method"] as? String, id: id, key: RPC.key(id),
                              params: object["params"] as? [String: Any],
                              expectsReply: id != nil && object["result"] == nil && object["error"] == nil)
        if message.method == "notifications/cancelled",
           let target = RPC.key(message.params?["requestId"]) {
            cancel(target)
        }
        inFlight.enter()
        let entry = Pending()
        lock.lock()
        if graceDeadline == nil { graceDeadline = Date().addingTimeInterval(Self.graceSeconds) }
        if message.expectsReply, let key = message.key { pending[key] = entry }
        lock.unlock()
        attempt(message, entry, retriedAuth: false)
    }

    /// Stops forwarding a request and drops its reply; the closed connection
    /// tells the server (the notification is forwarded too).
    private func cancel(_ key: String) {
        lock.lock()
        let entry = pending[key]
        entry?.cancelled = true
        lock.unlock()
        entry?.task?.cancel()
    }

    private func attempt(_ message: Message, _ entry: Pending, retriedAuth: Bool) {
        lock.lock()
        let cancelled = entry.cancelled
        lock.unlock()
        if cancelled { return finish(message, entry, nil) }
        switch prepare() {
        case .unavailable(let reason):
            retryOrFail(message, entry, reason: reason)
        case .refused(let text):
            finish(message, entry, RPC.error(id: message.id, code: -32000, message: text))
        case .ready(let endpoint, let token):
            let task = Wire.post(endpoint.url, body: message.body,
                                 headers: Wire.headers(token: token, method: message.method,
                                                       name: message.params?["name"] as? String,
                                                       version: protocolVersion(message))) {
                [self] result in
                completed(message, entry, endpoint: endpoint, sentToken: token, result: result,
                          retriedAuth: retriedAuth)
            }
            lock.lock()
            entry.task = task
            let cancelledNow = entry.cancelled
            lock.unlock()
            if cancelledNow { task.cancel() }
        }
    }

    /// Reads the endpoint file and verifies the listener before every send:
    /// each request opens a new connection, and the app may have died and
    /// another process taken the port since the last one (threat T9).
    private func prepare() -> Prepared {
        let endpoint: Endpoint
        switch EndpointFile.read() {
        case .failure(.missing): return .unavailable(nil)
        case .failure(.invalid(let reason)):
            Log.line("\(reason); nothing was sent.")
            return .refused(RelayText.badEndpoint)
        case .success(let read): endpoint = read
        }
        switch ListenerCheck.verify(endpoint) {
        case .gone?: return .unavailable("process \(endpoint.pid) from the endpoint file isn't running")
        case .mismatch(let reason)?:
            Log.line("\(reason); the token wasn't sent.")
            return .refused(RelayText.squatter)
        case nil: break
        }
        lock.lock()
        let token = self.token
        lock.unlock()
        return .ready(endpoint, token)
    }

    private func protocolVersion(_ message: Message) -> String? {
        if let meta = message.params?["_meta"] as? [String: Any],
           let version = meta[Wire.metaVersion] as? String {
            return version
        }
        lock.lock()
        defer { lock.unlock() }
        return negotiatedVersion
    }

    /// Startup grace: until a request first connects, retry for up to 5 s, in
    /// case the app is starting at login alongside the agent.
    private func retryOrFail(_ message: Message, _ entry: Pending, reason: String?) {
        lock.lock()
        let inGrace = Date() < (graceDeadline ?? .distantPast)
        lock.unlock()
        if inGrace {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.graceInterval) { [self] in
                attempt(message, entry, retriedAuth: false)
            }
            return
        }
        Log.line(reason.map { "\(AppIdentity.displayName) isn't reachable: \($0)." }
                 ?? "\(AppIdentity.displayName) isn't running, or its MCP server is off.")
        finish(message, entry, RPC.error(id: message.id, code: -32000, message: RelayText.notRunning))
    }

    private func completed(_ message: Message, _ entry: Pending, endpoint: Endpoint, sentToken: String,
                           result: Result<Wire.Reply, Wire.Failure>, retriedAuth: Bool) {
        let reply: Wire.Reply
        switch result {
        case .failure(.cancelled):
            return finish(message, entry, nil)
        case .failure(.refused):
            return retryOrFail(message, entry, reason: "connection refused on port \(endpoint.port)")
        case .failure(.timedOut):
            Log.line("no response after 60 s to \(message.method ?? "a message").")
            return finish(message, entry, RPC.error(id: message.id, code: -32000, message: RelayText.timeout))
        case .failure(.lost):
            Log.line("the connection closed before a reply to \(message.method ?? "a message").")
            return finish(message, entry, RPC.error(id: message.id, code: -32000, message: RelayText.lost))
        case .failure(.other(let code)):
            Log.line("couldn't reach \(AppIdentity.displayName) (URL error \(code)).")
            return finish(message, entry, RPC.error(id: message.id, code: -32603,
                                                    message: "Couldn't reach \(AppIdentity.displayName) "
                                                        + "(URL error \(code))."))
        case .success(let value):
            reply = value
        }
        lock.lock()
        graceDeadline = .distantPast
        lock.unlock()

        switch reply.status {
        case 200:
            guard let object = RPC.object(reply.body) else {
                Log.line("unreadable reply to \(message.method ?? "a message").")
                return finish(message, entry, RPC.error(id: message.id, code: -32603,
                                                        message: "\(AppIdentity.displayName) sent an "
                                                            + "unreadable reply."))
            }
            if message.method == "initialize",
               let version = (object["result"] as? [String: Any])?["protocolVersion"] as? String {
                lock.lock()
                negotiatedVersion = version
                lock.unlock()
            }
            finish(message, entry, RPC.serialize(object))
        case 202:
            finish(message, entry, nil)
        case 401:
            // The user may have reset the token while the agent was running.
            if !retriedAuth, let fresh = try? TokenFile.read(tokenPath), fresh != sentToken {
                lock.lock()
                token = fresh
                lock.unlock()
                Log.line("the token was rejected; retrying with the token file's new token.")
                return attempt(message, entry, retriedAuth: true)
            }
            Log.line("the token was rejected. Open the client in \(AppIdentity.displayName) "
                     + "and check MCP access.")
            finish(message, entry, RPC.error(id: message.id, code: -32001, message: RelayText.rejected))
        case 400, 404:
            if var object = RPC.object(reply.body), object["error"] != nil {
                if object["id"] == nil || object["id"] is NSNull, let id = message.id { object["id"] = id }
                return finish(message, entry, RPC.serialize(object))
            }
            fallthrough
        default:
            let explanation = RelayText.explain(reply.status, body: reply.body, retryAfter: reply.retryAfter)
            Log.line("HTTP \(reply.status) for \(message.method ?? "a message"): \(explanation)")
            finish(message, entry, RPC.error(id: message.id, code: -32603,
                                             message: RelayText.refused(reply.status, explanation)))
        }
    }

    private func finish(_ message: Message, _ entry: Pending, _ output: Data?) {
        lock.lock()
        let cancelled = entry.cancelled
        if let key = message.key, pending[key] === entry { pending[key] = nil }
        lock.unlock()
        if let output, message.expectsReply, !cancelled { Output.line(output) }
        inFlight.leave()
    }
}

// MARK: - headers

enum HeadersHelper {
    /// Prints `{}` and a reason whenever it refuses, so no consumer of stdout
    /// ever gets a token for the wrong listener. The exit code is non-zero
    /// then, so Claude Code reports a failed helper instead of connecting
    /// without credentials and starting an OAuth flow that can't succeed.
    static func run(_ invocation: LauncherInvocation) -> Int32 {
        let token: String
        do {
            token = try TokenFile.read(invocation.tokenPath)
        } catch let error as LauncherError {
            return refuse("error: " + error.message, error.exitCode)
        } catch {
            return refuse("error: \(error)", LauncherExit.localFile)
        }
        let environment = ProcessInfo.processInfo.environment["CLAUDE_CODE_MCP_SERVER_URL"] ?? ""
        guard let target = environment.isEmpty ? invocation.url : environment else {
            return refuse("error: missing --url. Run bridge-mcp --help.", LauncherExit.usage)
        }
        let deadline = Date().addingTimeInterval(Relay.graceSeconds)
        while true {
            let endpoint: Endpoint
            switch EndpointFile.read() {
            case .success(let read):
                endpoint = read
            case .failure(.missing):
                if Date() < deadline { Thread.sleep(forTimeInterval: Relay.graceInterval); continue }
                return refuse(RelayText.notRunning, LauncherExit.unavailable)
            case .failure(.invalid(let reason)):
                return refuse("\(reason); no token was printed.", LauncherExit.unavailable)
            }
            guard target == endpoint.url.absoluteString else {
                return refuse("the agent's URL \(target) isn't the one \(AppIdentity.displayName) serves "
                              + "(\(endpoint.url.absoluteString)). Copy the setup again from the "
                              + "client's page.", LauncherExit.unavailable)
            }
            switch ListenerCheck.verify(endpoint) {
            case .gone?:
                if Date() < deadline { Thread.sleep(forTimeInterval: Relay.graceInterval); continue }
                return refuse(RelayText.notRunning, LauncherExit.unavailable)
            case .mismatch(let reason)?:
                return refuse("\(reason). " + RelayText.squatter, LauncherExit.unavailable)
            case nil:
                Output.line(RPC.serialize(["Authorization": "Bearer " + token]))
                return LauncherExit.ok
            }
        }
    }

    static func refuse(_ reason: String, _ code: Int32) -> Int32 {
        Output.line(Data("{}".utf8))
        Log.line(reason)
        return code
    }
}

// MARK: - check

enum SetupCheck {
    private static let app = AppIdentity.displayName

    static func run(_ invocation: LauncherInvocation) -> Int32 {
        let subject = invocation.client.map { id -> String in
            let text = id.uuidString.lowercased()
            return "client " + text.prefix(4) + "…" + text.suffix(4)
        } ?? "token file " + LauncherPaths.display(invocation.tokenPath)
        Log.raw("\(app) MCP check for \(subject)")

        let path = invocation.tokenPath
        let token: String
        do {
            token = try TokenFile.read(path)
        } catch let error as LauncherError {
            return fail("token file: " + error.message, error.exitCode)
        } catch {
            return fail("token file: \(error)", LauncherExit.localFile)
        }
        good("token file  \(LauncherPaths.display(path)) (mode \(TokenFile.mode(path)))")

        let endpoint: Endpoint
        switch EndpointFile.read() {
        case .success(let read): endpoint = read
        case .failure(.missing):
            let file = LauncherPaths.display(LauncherPaths.endpointFile)
            return fail("\(app) isn't running, or its MCP server is off (no \(file))",
                        LauncherExit.unavailable)
        case .failure(.invalid(let reason)):
            return fail("\(reason); nothing was sent", LauncherExit.unavailable)
        }
        switch ListenerCheck.verify(endpoint) {
        case .gone?:
            return fail("\(app) isn't running (process \(endpoint.pid) is gone)", LauncherExit.unavailable)
        case .mismatch(let reason)?:
            return fail("another program is using port \(endpoint.port): \(reason); "
                        + "the token wasn't sent", LauncherExit.unavailable)
        case nil: break
        }

        let discover: [String: Any]
        switch call(endpoint, token, id: 1, method: "server/discover", params: [:]) {
        case .failure(let failure):
            return fail(failure.text, failure.exit)
        case .success(let result):
            discover = result
        }
        good("app running, MCP server listening on \(endpoint.url.absoluteString)")
        let name = ((discover["_meta"] as? [String: Any])?[Wire.metaClientName] as? [String: Any])?["name"]
            as? String
        good("token accepted" + (name.map { ": client \"\($0)\"" } ?? ""))

        let tools: [String]
        switch call(endpoint, token, id: 2, method: "tools/list", params: [:]) {
        case .failure(let failure):
            return fail(failure.text, failure.exit)
        case .success(let result):
            tools = (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        if tools.isEmpty {
            warn("no tools available: grant this client access in \(app)")
        } else {
            good("\(tools.count) tool\(tools.count == 1 ? "" : "s") available: "
                 + tools.joined(separator: ", "))
        }

        // Only a tool call reveals the bridge switch; list_collections is
        // read-only and always visible. It shows in Activity like any call.
        if tools.contains("list_collections") {
            switch call(endpoint, token, id: 3, method: "tools/call",
                        params: ["name": "list_collections", "arguments": [String: Any]()]) {
            case .failure(let failure):
                warn("list_collections failed: \(failure.text)")
            case .success(let result):
                let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                if result["isError"] as? Bool == true {
                    if text.contains("(code: bridge_off)") {
                        warn("the bridge is off: tool calls will be refused until it's turned on")
                    } else {
                        warn("list_collections failed: \(text)")
                    }
                } else {
                    good("the bridge is on")
                }
            }
        }
        return LauncherExit.ok
    }

    private struct Failure: Error {
        let text: String
        let exit: Int32
    }

    private static func call(_ endpoint: Endpoint, _ token: String, id: Int, method: String,
                             params: [String: Any]) -> Result<[String: Any], Failure> {
        var params = params
        params["_meta"] = [
            Wire.metaVersion: Wire.modernVersion,
            Wire.metaCapabilities: [String: Any](),
            Wire.metaClientInfo: ["name": "bridge-mcp check", "version": LauncherVersion.string],
        ] as [String: Any]
        let body = RPC.serialize(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let headers = Wire.headers(token: token, method: method, name: params["name"] as? String,
                                   version: Wire.modernVersion)
        switch Wire.postAndWait(endpoint.url, body: body, headers: headers) {
        case .failure(.refused):
            return .failure(Failure(text: "\(app) isn't running, or its MCP server is off "
                                        + "(connection refused on port \(endpoint.port))",
                                    exit: LauncherExit.unavailable))
        case .failure(.timedOut):
            return .failure(Failure(text: "no response from \(app) after 60 s",
                                    exit: LauncherExit.unavailable))
        case .failure(let other):
            return .failure(Failure(text: "couldn't reach \(app) (\(other))", exit: LauncherExit.unavailable))
        case .success(let reply):
            if reply.status == 401 {
                return .failure(Failure(text: "token rejected: open the client in \(app) "
                                            + "and check MCP access",
                                        exit: LauncherExit.tokenRejected))
            }
            let object = RPC.object(reply.body)
            guard reply.status == 200, let result = object?["result"] as? [String: Any] else {
                let explanation = RelayText.explain(reply.status, body: reply.body,
                                                    retryAfter: reply.retryAfter)
                return .failure(Failure(text: "\(method) failed (HTTP \(reply.status)): \(explanation)",
                                        exit: LauncherExit.unavailable))
            }
            return .success(result)
        }
    }

    private static func good(_ text: String) { Log.raw("  ✓ " + text) }
    private static func warn(_ text: String) { Log.raw("  ! " + text) }

    private static func fail(_ text: String, _ code: Int32) -> Int32 {
        Log.raw("  ✗ " + text)
        return code
    }
}

enum LauncherVersion {
    /// The enclosing app's version; AppIdentity's Bundle.main lookup is the
    /// fallback for builds outside a bundle.
    static var string: String {
        ListenerCheck.executablePath(getpid())
            .flatMap(ListenerCheck.enclosingBundleInfo)?["CFBundleShortVersionString"] as? String
            ?? AppIdentity.version
    }
}

// MARK: - Entry point

@main
struct BridgeMCP {
    static func main() {
        // A reply racing the agent closing its end must not kill the process.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let invocation: LauncherInvocation
        do {
            invocation = try LauncherInvocation.parse(arguments)
        } catch let error as LauncherError {
            if arguments.first == "headers" { Output.line(Data("{}".utf8)) }
            Log.line("error: " + error.message)
            exit(error.exitCode)
        } catch {
            exit(LauncherExit.usage)
        }
        switch invocation.mode {
        case .help:
            Output.write(STDOUT_FILENO, Data(LauncherHelp.text.utf8))
            exit(LauncherExit.ok)
        case .version:
            Output.line(Data("bridge-mcp \(LauncherVersion.string)".utf8))
            exit(LauncherExit.ok)
        case .headers:
            exit(HeadersHelper.run(invocation))
        case .check:
            exit(SetupCheck.run(invocation))
        case .relay:
            let token: String
            do {
                token = try TokenFile.read(invocation.tokenPath)
            } catch let error as LauncherError {
                Log.line("error: " + error.message)
                exit(error.exitCode)
            } catch {
                exit(LauncherExit.localFile)
            }
            Relay(tokenPath: invocation.tokenPath, token: token).run()
        }
    }
}

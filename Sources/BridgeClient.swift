import CryptoKit
import Darwin
import Foundation

// bridge-client signs one request for the local bridge session and prints the
// JSON response on stdout. Every other message goes to stderr, with a distinct
// exit code per failure class (see ExitCode). No AppKit or EventKit here.

enum CLIIdentity {
    static var productName: String { AppIdentity.displayName }
    static let launcher = "client.py"
}

enum ExitCode {
    static let ok: Int32 = 0
    static let requestFailed: Int32 = 1
    static let usage: Int32 = 2
    static let bridgeUnavailable: Int32 = 3
    static let localFile: Int32 = 4
    static let timeout: Int32 = 5
}

struct CLIError: Error {
    let exitCode: Int32
    let message: String
    var details: [String] = []

    static let maxParamsBytes = 8_192
    private static let launcher = CLIIdentity.launcher
    private static let retryAdvice = "Read the item before retrying, and reuse the same idempotencyKey."
    private static let rebuildAdvice = "Rebuild the client with: sh build.sh"

    static func usage(_ message: String) -> CLIError {
        CLIError(exitCode: ExitCode.usage, message: message)
    }
    static func unknownOption(_ option: String) -> CLIError {
        usage("unknown option \"\(option)\". Run \(launcher) --help.")
    }
    static func unknownCommand(_ name: String) -> CLIError {
        let suggestion = Suggestion.closestCommand(to: name).map { " Did you mean \($0)?" } ?? ""
        return CLIError(exitCode: ExitCode.usage,
                        message: "unknown command \"\(name)\".\(suggestion)",
                        details: ["Run \(launcher) --help for all commands."])
    }
    static let invalidParams = usage("params must be a JSON object under 8 KB.")
    static let bridgeNotRunning = CLIError(
        exitCode: ExitCode.bridgeUnavailable,
        message: "\(CLIIdentity.productName) isn't running, or the bridge is off. Turn it on from the menu bar.")
    static let sessionChanged = CLIError(
        exitCode: ExitCode.bridgeUnavailable,
        message: "the bridge session changed. Run the command again.")
    static let writeSessionEnded = CLIError(
        exitCode: ExitCode.bridgeUnavailable,
        message: "the bridge session ended before a response. The write may still have happened.",
        details: [retryAdvice])
    static let incompatibleSession = CLIError(
        exitCode: ExitCode.bridgeUnavailable,
        message: "the running \(CLIIdentity.productName) doesn't match this client.",
        details: [rebuildAdvice])
    static let unreadableResponse = CLIError(
        exitCode: ExitCode.bridgeUnavailable,
        message: "the bridge sent a response this client can't read.",
        details: [rebuildAdvice])
    static func timeout(write: Bool) -> CLIError {
        write
            ? CLIError(exitCode: ExitCode.timeout,
                       message: "no response after 60 s. The write may still have happened.",
                       details: [retryAdvice])
            : CLIError(exitCode: ExitCode.timeout,
                       message: "no response after 10 s. Is the Mac awake and the bridge on?")
    }
    static func notKeyFile(_ path: String) -> CLIError {
        CLIError(exitCode: ExitCode.localFile,
                 message: "\(path) isn't a key file for \(CLIIdentity.productName).")
    }

    /// Ownership, mode and type problems for a local file or directory.
    static func unsafe(_ problem: SafePath.Problem, path: String, privateMode: String = "600")
        -> CLIError {
        let message: String
        var details = [String]()
        switch problem {
        case .missing: message = "file not found: \(path)"
        case .symlink: message = "\(path) is a symbolic link."
        case .otherOwner: message = "\(path) is owned by another user."
        case .sharedMode(let mode):
            message = "\(path) can be read by other users (mode \(mode))."
            details = ["Fix: chmod \(privateMode) \(path)"]
        case .wrongType(let expected): message = "\(path) isn't a \(expected)."
        case .tooLarge: message = "\(path) is too large."
        case .unreadable(let code):
            message = "can't read \(path): \(String(cString: strerror(code)))."
        }
        return CLIError(exitCode: ExitCode.localFile, message: message, details: details)
    }
}

// MARK: - Entry point

@main
struct BridgeClientCLI {
    static func main() {
        do {
            let response = try run(Array(CommandLine.arguments.dropFirst()))
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
            guard response["ok"] as? Bool == true else {
                if let code = response["error"] as? String {
                    let outcome = OutcomePresentation.of(code)
                    if let hint = outcome.fix ?? outcome.why { Terminal.hint(hint) }
                }
                exit(ExitCode.requestFailed)
            }
            exit(ExitCode.ok)
        } catch let error as CLIError {
            Terminal.error(error)
            exit(error.exitCode)
        } catch {
            Terminal.error(CLIError(exitCode: ExitCode.requestFailed,
                                    message: "the request couldn't be sent (\(error))."))
            exit(ExitCode.requestFailed)
        }
    }

    private static func run(_ arguments: [String]) throws -> [String: Any] {
        let invocation = try Invocation.parse(arguments)
        guard let command = invocation.command else {
            Terminal.out(invocation.helpCommand.map(Help.command) ?? Help.general())
            exit(ExitCode.ok)
        }
        let credentialPath = try ClientLookup.credentialPath(invocation)
        let (clientID, signingKey) = try readKeyFile(credentialPath)
        let parameters = try readParameters(invocation.paramsFile)
        return try BridgeExchange.send(command: command, parameters: parameters,
                                       clientID: clientID, signingKey: signingKey)
    }

    private static func readKeyFile(_ path: String) throws
        -> (String, Curve25519.Signing.PrivateKey) {
        let data: Data
        do {
            data = try SafePath.readFile(path, maxBytes: 512)
        } catch SafePath.Problem.missing {
            throw CLIError(exitCode: ExitCode.localFile, message: "key file not found: \(path)")
        } catch SafePath.Problem.tooLarge {
            throw CLIError.notKeyFile(path)
        } catch let problem as SafePath.Problem {
            throw CLIError.unsafe(problem, path: path)
        }
        guard let credentials = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(credentials.keys) == Set(["clientID", "key"]),
              let clientID = credentials["clientID"] as? String,
              let clientUUID = UUID(uuidString: clientID),
              let key = credentials["key"] as? String,
              key.hasPrefix("ekb_v1_"), key.utf8.count == 71,
              let secret = Hex.decode(String(key.dropFirst(7))), secret.count == 32,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        else { throw CLIError.notKeyFile(path) }
        return (clientUUID.uuidString.lowercased(), signingKey)
    }

    private static func readParameters(_ path: String?) throws -> [String: Any] {
        guard let path else { return [:] }
        let data: Data
        if path == "-" {
            data = try readStandardInput(maxBytes: CLIError.maxParamsBytes)
        } else {
            do {
                data = try SafePath.readFile(path, maxBytes: CLIError.maxParamsBytes)
            } catch SafePath.Problem.missing {
                throw CLIError(exitCode: ExitCode.localFile, message: "params file not found: \(path)")
            } catch SafePath.Problem.tooLarge {
                throw CLIError.invalidParams
            } catch let problem as SafePath.Problem {
                throw CLIError.unsafe(problem, path: path)
            }
        }
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw CLIError.invalidParams }
        return parsed
    }

    private static func readStandardInput(maxBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= maxBytes {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw CLIError(exitCode: ExitCode.localFile,
                               message: "can't read params from stdin: \(String(cString: strerror(errno))).")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        throw CLIError.invalidParams
    }
}

// MARK: - Arguments

struct Invocation {
    /// Nil when help was requested.
    var command: BridgeCommand?
    var helpCommand: BridgeCommand?
    var client: String?
    var credentialsFile: String?
    var paramsFile: String?

    private static let valueOptions = ["--client", "--credentials-file", "--params-file"]

    static func parse(_ arguments: [String]) throws -> Invocation {
        var result = Invocation()
        var help = false
        var helpWord = false
        var commandName: String?
        var firstError: CLIError?
        func record(_ error: CLIError) { if firstError == nil { firstError = error } }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--help" || argument == "-h" {
                help = true
            } else if argument.hasPrefix("-"), argument != "-" {
                var name = argument
                var value: String?
                if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                    name = String(argument[..<equals])
                    value = String(argument[argument.index(after: equals)...])
                }
                guard valueOptions.contains(name) else {
                    record(.unknownOption(name))
                    continue
                }
                if value == nil, index < arguments.count, !arguments[index].hasPrefix("--") {
                    value = arguments[index]
                    index += 1
                }
                guard let value, !value.isEmpty else {
                    record(.usage("option \"\(name)\" needs a value. Run \(CLIIdentity.launcher) --help."))
                    continue
                }
                let duplicate: Bool
                switch name {
                case "--client":
                    duplicate = result.client != nil
                    result.client = result.client ?? value
                case "--credentials-file":
                    duplicate = result.credentialsFile != nil
                    result.credentialsFile = result.credentialsFile ?? value
                default:
                    duplicate = result.paramsFile != nil
                    result.paramsFile = result.paramsFile ?? value
                }
                if duplicate { record(.usage("option \"\(name)\" was given more than once.")) }
            } else if argument == "help", commandName == nil, !helpWord {
                helpWord = true
                help = true
            } else if commandName == nil {
                commandName = argument
                if BridgeCommand(rawValue: argument) == nil { record(.unknownCommand(argument)) }
            } else {
                record(.usage("unexpected argument \"\(argument)\". Run \(CLIIdentity.launcher) --help."))
            }
        }

        if help {
            if let commandName {
                guard let command = BridgeCommand(rawValue: commandName) else {
                    throw CLIError.unknownCommand(commandName)
                }
                result.helpCommand = command
            }
            return result
        }
        if let firstError { throw firstError }
        guard let commandName, let command = BridgeCommand(rawValue: commandName) else {
            throw CLIError.usage("missing command. Run \(CLIIdentity.launcher) --help.")
        }
        if result.client != nil && result.credentialsFile != nil {
            throw CLIError.usage("use --client or --credentials-file, not both.")
        }
        if result.client == nil && result.credentialsFile == nil {
            throw CLIError.usage(
                "missing --client or --credentials-file. Run \(CLIIdentity.launcher) --help.")
        }
        result.command = command
        return result
    }
}

enum Suggestion {
    static func closestCommand(to name: String) -> String? {
        var best: (name: String, distance: Int)?
        for command in BridgeCommand.allCases {
            let distance = editDistance(name, command.rawValue)
            if distance <= 2, distance < (best?.distance ?? Int.max) {
                best = (command.rawValue, distance)
            }
        }
        return best?.name
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Help

// Generated from BridgeCommand, its parameter-key table (the one
// CommandPolicy.validate checks) and CommandPresentation, so it can't drift.
enum Help {
    private static let launcher = CLIIdentity.launcher
    private static let credentialUsage = "(--client NAME|ID | --credentials-file PATH)"

    static func general() -> String {
        let width = BridgeCommand.allCases.map(\.rawValue.count).max() ?? 0
        let commands = BridgeCommand.allCases.map { command in
            let name = command.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            return "  \(name)  \(CommandPresentation.label(command.rawValue)). \(access(command))"
        }
        return ([
            "Usage: \(launcher) COMMAND \(credentialUsage) [--params-file PATH|-]",
            "       \(launcher) COMMAND --help",
            "",
            "Sends one signed request to \(CLIIdentity.productName) on this Mac and prints",
            "the JSON response on stdout. Errors and hints go to stderr.",
            "",
            "Options:",
            "  --client NAME|ID         Use the key file of the active client with this",
            "                           name or ID.",
            "  --credentials-file PATH  Use this key file.",
            "  --params-file PATH       Read the parameters, a JSON object under 8 KB.",
            "  --params-file -          Read the parameters from stdin.",
            "  -h, --help               Show this help. After a command, show its help.",
            "",
            "Clients can be renamed, so scripts meant to last should use the client ID",
            "or --credentials-file.",
            "",
            "Commands:",
        ] + commands + [
            "",
            "Exit codes:",
            "  0  ok",
            "  1  request denied or failed (JSON on stdout, hint on stderr)",
            "  2  usage error",
            "  3  bridge unavailable",
            "  4  missing or unsafe local file",
            "  5  no response in time",
            "",
            "Parameter formats and results: docs/API.md.",
        ]).joined(separator: "\n") + "\n"
    }

    static func command(_ command: BridgeCommand) -> String {
        let keys = command.parameterKeys
        var lines = ["Usage: \(launcher) \(command.rawValue) \(credentialUsage)"]
        if !keys.isEmpty {
            let indent = String(repeating: " ", count: "Usage: \(launcher) \(command.rawValue)".count)
            lines.append(indent + " --params-file PATH|-")
        }
        lines += ["", "\(CommandPresentation.label(command.rawValue)). \(access(command))", ""]
        if keys.isEmpty {
            lines.append("Takes no parameters.")
        } else {
            lines.append("Parameters (a JSON object under 8 KB):")
            lines.append("  Required: " + keys.required.joined(separator: ", "))
            if !keys.optional.isEmpty {
                lines.append("  Optional: " + keys.optional.joined(separator: ", "))
            }
        }
        lines.append("")
        if command.isWrite {
            lines.append("Waits up to 60 s for a response. On a retry, reuse the same")
            lines.append("idempotencyKey and parameters.")
        } else {
            lines.append("Waits up to 10 s for a response.")
        }
        lines.append("Parameter formats and results: docs/API.md.")
        return lines.joined(separator: "\n") + "\n"
    }

    static func access(_ command: BridgeCommand) -> String {
        guard let action = CommandPresentation.requiredAction(command.rawValue) else {
            return "Needs an active client."
        }
        let target = CommandPresentation.targetsList(command.rawValue) ? "list" : "calendar"
        return "Needs \(action) access to the \(target)."
    }
}

// MARK: - Local paths

enum LocalPaths {
    // Test builds (-D EVENTKIT_CLIENT_TEST) never touch the real bridge or key
    // files: without the override they point at paths that don't exist.
    static var supportDirectory: String {
        #if EVENTKIT_CLIENT_TEST
        return ProcessInfo.processInfo.environment["EVENTKIT_TEST_SUPPORT_DIR"]
            ?? "/var/empty/eventkit-bridge-test-support"
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EventKitBridge", isDirectory: true).path
        #endif
    }

    static var bridgeRoot: String {
        #if EVENTKIT_CLIENT_TEST
        return ProcessInfo.processInfo.environment["EVENTKIT_TEST_BRIDGE_ROOT"]
            ?? "/var/empty/eventkit-bridge-test-root"
        #else
        return "/tmp/eventkit-bridge-\(getuid())"
        #endif
    }

    static func waitSeconds(write: Bool) -> TimeInterval {
        #if EVENTKIT_CLIENT_TEST
        if let raw = ProcessInfo.processInfo.environment["EVENTKIT_TEST_TIMEOUT_SECONDS"],
           let seconds = TimeInterval(raw) { return seconds }
        #endif
        return write ? 60 : 10
    }

    static func credentialFile(clientID: UUID) -> String {
        supportDirectory + "/client-credentials/" + clientID.uuidString.lowercased() + ".json"
    }
}

// MARK: - --client lookup

enum ClientLookup {
    // Public registry fields only; verifiers, grants and activity are ignored.
    private struct Registry: Decodable {
        struct Client: Decodable {
            let id: String
            let name: String
            let revoked: Bool
        }
        let version: Int
        let clients: [Client]
    }

    static func credentialPath(_ invocation: Invocation) throws -> String {
        if let path = invocation.credentialsFile { return path }
        let value = (invocation.client ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: value) { return LocalPaths.credentialFile(clientID: uuid) }
        let active = try activeClients()
        let key = nameKey(value)
        let matches = active.filter { nameKey($0.name) == key }
        // Registries from before names were unique can hold two active clients
        // with one name; never guess which key to use.
        if matches.count > 1 {
            throw CLIError.usage("more than one active client is named \"\(value)\". Use --client with one of these IDs: "
                                 + matches.map(\.id).joined(separator: ", "))
        }
        guard let match = matches.first,
              let uuid = UUID(uuidString: match.id) else {
            let names = active.map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let list = names.isEmpty
                ? "No active clients."
                : "Clients: " + names.map { "\"\($0)\"" }.joined(separator: ", ")
            throw CLIError.usage("no active client named \"\(value)\". \(list)")
        }
        return LocalPaths.credentialFile(clientID: uuid)
    }

    // Matches ClientRegistry's uniqueness rule for active client names.
    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
    }

    private static func activeClients() throws -> [Registry.Client] {
        let path = LocalPaths.supportDirectory + "/client-registry.json"
        let data: Data
        do {
            data = try SafePath.readFile(path, maxBytes: 1_000_000)
        } catch SafePath.Problem.missing {
            return []
        } catch SafePath.Problem.tooLarge {
            throw unreadable(path)
        } catch let problem as SafePath.Problem {
            throw CLIError.unsafe(problem, path: path)
        }
        guard let registry = try? JSONDecoder().decode(Registry.self, from: data),
              registry.version == 2 || registry.version == 3
        else { throw unreadable(path) }
        return registry.clients.filter { !$0.revoked }
    }

    private static func unreadable(_ path: String) -> CLIError {
        CLIError(exitCode: ExitCode.localFile,
                 message: "can't read the client list in \(path).",
                 details: ["Use --client with the client ID, or --credentials-file."])
    }
}

// MARK: - Bridge exchange

enum BridgeExchange {
    static func send(command: BridgeCommand, parameters: [String: Any], clientID: String,
                     signingKey: Curve25519.Signing.PrivateKey) throws -> [String: Any] {
        let root = LocalPaths.bridgeRoot
        do {
            try SafePath.checkDirectory(root)
        } catch SafePath.Problem.missing {
            throw CLIError.bridgeNotRunning
        } catch let problem as SafePath.Problem {
            throw CLIError.unsafe(problem, path: root, privateMode: "700")
        }
        let descriptorPath = root + "/current.json"
        let descriptorData: Data
        do {
            descriptorData = try SafePath.readFile(descriptorPath, maxBytes: 2_048)
        } catch SafePath.Problem.missing {
            throw CLIError.bridgeNotRunning
        } catch SafePath.Problem.tooLarge {
            throw CLIError.incompatibleSession
        } catch let problem as SafePath.Problem {
            throw CLIError.unsafe(problem, path: descriptorPath)
        }
        guard let descriptor = (try? JSONSerialization.jsonObject(with: descriptorData)) as? [String: Any],
              Set(descriptor.keys) == Set(["version", "session"]),
              descriptor["version"] as? Int == 2,
              let session = descriptor["session"] as? String,
              session.hasPrefix("session-"), UUID(uuidString: String(session.dropFirst(8))) != nil
        else { throw CLIError.incompatibleSession }
        let sessionPath = root + "/" + session
        let requests = sessionPath + "/requests"
        let responses = sessionPath + "/responses"
        for path in [sessionPath, requests, responses] {
            do { try SafePath.checkDirectory(path) } catch { throw CLIError.sessionChanged }
        }

        let requestID = UUID().uuidString.lowercased()
        var object: [String: Any] = [
            "version": 2, "session": session, "id": requestID,
            "clientID": clientID,
            "command": command.rawValue, "issuedAt": Date().timeIntervalSince1970,
            "parameters": parameters,
        ]
        let signed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let signature = try signingKey.signature(for: signed)
        object["signature"] = Hex.encode(signature)
        let request = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard request.count <= BridgeProtocol.maxRequestBytes else { throw CLIError.invalidParams }
        guard SafePath.atomicWrite(request, to: requests + "/" + requestID + ".json") else {
            throw CLIError.sessionChanged
        }

        let responsePath = responses + "/" + requestID + ".json"
        let start = Date().timeIntervalSince1970
        let deadline = start + LocalPaths.waitSeconds(write: command.isWrite)
        var lastSessionCheck = start
        while Date().timeIntervalSince1970 < deadline {
            if let responseData = try? SafePath.readFile(responsePath,
                                                         maxBytes: BridgeProtocol.maxResponseBytes) {
                _ = unlink(responsePath)
                guard let response = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
                      response["version"] as? Int == 2,
                      response["id"] as? String == requestID
                else { throw CLIError.unreadableResponse }
                return response
            }
            let now = Date().timeIntervalSince1970
            if now - lastSessionCheck >= 0.5 {
                lastSessionCheck = now
                // The app removes the session directory when the bridge stops,
                // so no response can arrive any more.
                if (try? SafePath.checkDirectory(responses)) == nil {
                    throw command.isWrite ? CLIError.writeSessionEnded : CLIError.sessionChanged
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CLIError.timeout(write: command.isWrite)
    }
}

// MARK: - File safety

enum SafePath {
    enum Problem: Error {
        case missing
        case symlink
        case otherOwner
        case sharedMode(String)
        case wrongType(String)
        case tooLarge
        case unreadable(Int32)
    }

    /// A private directory: not a symlink, owned by this user, no group/other access.
    static func checkDirectory(_ path: String) throws {
        var details = stat()
        guard lstat(path, &details) == 0 else {
            throw errno == ENOENT || errno == ENOTDIR ? Problem.missing : Problem.unreadable(errno)
        }
        if details.st_mode & S_IFMT == S_IFLNK { throw Problem.symlink }
        guard details.st_mode & S_IFMT == S_IFDIR else { throw Problem.wrongType("directory") }
        try checkOwnerAndMode(details)
    }

    /// A private regular file: not a symlink, owned by this user, no
    /// group/other access, at most `maxBytes`.
    static func readFile(_ path: String, maxBytes: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw Problem.missing }
            if code == ELOOP { throw Problem.symlink }
            var details = stat()
            if lstat(path, &details) == 0 {
                if details.st_mode & S_IFMT == S_IFLNK { throw Problem.symlink }
                if details.st_uid != getuid() { throw Problem.otherOwner }
            }
            throw Problem.unreadable(code)
        }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0 else { throw Problem.unreadable(errno) }
        guard details.st_mode & S_IFMT == S_IFREG else { throw Problem.wrongType("regular file") }
        try checkOwnerAndMode(details)
        guard details.st_size <= maxBytes else { throw Problem.tooLarge }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            .read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw Problem.tooLarge }
        return data
    }

    private static func checkOwnerAndMode(_ details: stat) throws {
        guard details.st_uid == getuid() else { throw Problem.otherOwner }
        guard details.st_mode & 0o077 == 0 else {
            throw Problem.sharedMode(String(details.st_mode & 0o777, radix: 8))
        }
    }

    static func atomicWrite(_ data: Data, to path: String) -> Bool {
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var offset = 0
        let complete = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard complete, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }
}

// MARK: - Output

enum Terminal {
    // Color only on an interactive stderr, and never when NO_COLOR is set.
    private static let color = isatty(STDERR_FILENO) == 1 && getenv("NO_COLOR") == nil

    static func out(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func error(_ error: CLIError) {
        let lines = [styled("error:", code: "1;31") + " " + error.message] +
            error.details.map { "  " + $0 }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    static func hint(_ text: String) {
        FileHandle.standardError.write(Data((styled("hint:", code: "1;33") + " " + text + "\n").utf8))
    }

    private static func styled(_ text: String, code: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}

enum Hex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ string: String) -> Data? {
        guard string.count == 64, string.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

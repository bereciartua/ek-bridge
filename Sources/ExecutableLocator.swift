import Foundation

/// Finds a command-line agent such as `claude` (B07). A GUI app's PATH is
/// minimal, so it never relies on it: it tries fixed install locations, then
/// asks a login shell, accepting only an absolute path to an executable file.
struct ExecutableLocator {
    var isExecutable: (String) -> Bool
    /// `command -v <name>` in a login shell; nil when it isn't found or times out.
    var loginShellLookup: (String) -> String?

    static func candidates(_ name: String, home: String) -> [String] {
        var paths = name == "claude" ? [home + "/.claude/local/claude"] : []
        paths += [home + "/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                  home + "/.npm-global/bin/\(name)", home + "/.bun/bin/\(name)"]
        return paths
    }

    func locate(_ name: String, home: String) -> String? {
        if let found = Self.candidates(name, home: home).first(where: isExecutable) { return found }
        guard let found = loginShellLookup(name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              found.hasPrefix("/"), !found.contains("\n"), isExecutable(found) else { return nil }
        return found
    }

    static let live = ExecutableLocator(
        isExecutable: { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        },
        loginShellLookup: { name in
            // Only plain tool names reach the shell.
            guard name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
                return nil
            }
            return ProcessRunner.run("/bin/zsh", ["-l", "-c", "command -v \(name)"], timeout: 3)?.output
        })
}

/// Runs a program with an argument array (never a shell string), collecting
/// its output, and stops it after `timeout` seconds.
enum ProcessRunner {
    struct Result {
        let exitCode: Int32
        let output: String
        let timedOut: Bool
    }

    /// `mergeErrors` false drops stderr, for tools whose warnings would get
    /// in the way of the JSON they print (`tailscale status --json`).
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil, mergeErrors: Bool = true) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeErrors ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return Result(exitCode: timedOut ? -1 : process.terminationStatus,
                      output: String(decoding: collected.data, as: UTF8.self), timedOut: timedOut)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var storage = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ chunk: Data) {
            lock.lock()
            storage.append(chunk)
            // Keep the last 64 KB; the UI shows the last 20 lines.
            if storage.count > 65_536 { storage.removeFirst(storage.count - 65_536) }
            lock.unlock()
        }
    }
}

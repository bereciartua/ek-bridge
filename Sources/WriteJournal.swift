import CryptoKit
import Darwin
import Foundation

// A write is recorded as pending before EventKit is called. If the app stops
// between EventKit and the response, retrying cannot silently create twice.
// Pending entries require manual reconciliation. No item titles are stored.
final class WriteJournal {
    enum Decision {
        case execute
        case repeatResult([String: Any])
        case reject(String)
    }

    private struct Entry: Codable {
        let digest: String
        let semanticDigest: String?
        var result: Data?
    }
    private struct State: Codable {
        var version = 3
        var highWater: TimeInterval
        var entries: [String: Entry]
    }

    private let directory: URL
    private let file: URL
    private let now: () -> TimeInterval
    private let maxEntries: Int
    private var state: State?

    init(directory override: URL? = nil,
         maxEntries: Int = 1_000,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        directory = override ?? support.appendingPathComponent("EventKitBridge", isDirectory: true)
        file = directory.appendingPathComponent("write-journal.json")
        self.maxEntries = maxEntries
        self.now = now
    }

    func inspect(_ request: BridgeRequest) -> Decision {
        guard let key = request.parameters["idempotencyKey"] as? String,
              WriteIdempotencyKey.timestamp(key) != nil,
              let digest = digest(request) else { return .reject("invalid_idempotency_key") }
        guard load() else { return .reject("journal_unavailable") }
        let current = now()
        guard current.isFinite, current + WriteIdempotencyKey.futureSkew >= state!.highWater
        else { return .reject("journal_clock_rollback") }
        guard WriteIdempotencyKey.isCurrent(key, now: current)
        else { return .reject("idempotency_expired") }
        pruneCompletedExpired(now: current)
        if let entry = state!.entries[key] {
            guard entry.digest == digest else { return .reject("idempotency_conflict") }
            guard let data = entry.result,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .reject("idempotency_pending_review") }
            return .repeatResult(result)
        }
        guard state!.entries.count < maxEntries else { return .reject("journal_full") }
        return .execute
    }

    func begin(_ request: BridgeRequest) -> Decision {
        switch inspect(request) {
        case .repeatResult(let result): return .repeatResult(result)
        case .reject(let error): return .reject(error)
        case .execute: break
        }
        guard let key = request.parameters["idempotencyKey"] as? String,
              let digest = digest(request) else { return .reject("invalid_idempotency_key") }
        let semantic = semanticDigest(request)
        if let semantic, state!.entries.values.contains(where: {
            $0.semanticDigest == semantic
        }) { return .reject("occurrence_already_requested") }
        state!.entries[key] = Entry(digest: digest, semanticDigest: semantic, result: nil)
        state!.highWater = max(state!.highWater, now())
        guard persist() else { return .reject("journal_unavailable") }
        return .execute
    }

    func finish(_ request: BridgeRequest, result: [String: Any]) -> Bool {
        guard let key = request.parameters["idempotencyKey"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              state?.entries[key] != nil else { return false }
        state!.entries[key]?.result = data
        state!.highWater = max(state!.highWater, now())
        guard persist() else {
            state!.entries[key]?.result = nil
            return false
        }
        return true
    }

    private func pruneCompletedExpired(now current: TimeInterval) {
        let previousCount = state!.entries.count
        state!.entries = state!.entries.filter { key, entry in
            guard entry.result != nil,
                  let issued = WriteIdempotencyKey.timestamp(key) else { return true }
            return current - issued <= WriteIdempotencyKey.lifetime +
                WriteIdempotencyKey.futureSkew
        }
        // If the clock jumps forward then back before the next disk write,
        // the in-memory high-water mark still blocks reuse of pruned keys.
        if state!.entries.count != previousCount {
            state!.highWater = max(state!.highWater, current)
        }
    }

    private func digest(_ request: BridgeRequest) -> String? {
        let object: [String: Any] = [
            "command": request.command.rawValue,
            "parameters": request.parameters,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Different transport keys cannot advance the same recurring occurrence
    // twice. The due instant is part of the identity, so a later day's
    // occurrence of the same series is a separate, deliberate request.
    private func semanticDigest(_ request: BridgeRequest) -> String? {
        guard request.command == .completeReminder,
              request.parameters["recurrenceScope"] as? String == "occurrence",
              let list = request.parameters["listID"] as? String,
              let item = request.parameters["itemID"] as? String,
              let due = request.parameters["occurrenceDue"] as? NSNumber,
              CFGetTypeID(due) != CFBooleanGetTypeID(),
              due.doubleValue.isFinite,
              due.doubleValue.rounded() == due.doubleValue else { return nil }
        let object: [String: Any] = ["listID": list, "itemID": item,
                                     "occurrenceDue": due.int64Value]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                      options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func load() -> Bool {
        if state != nil { return true }
        do {
            let existed = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var directoryInfo = stat()
            guard lstat(directory.path, &directoryInfo) == 0,
                  directoryInfo.st_uid == getuid(),
                  directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  directoryInfo.st_mode & 0o077 == 0 else { return false }
            if !existed {
                let parentFD = open(directory.deletingLastPathComponent().path,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parentFD >= 0 else { return false }
                let synced = fsync(parentFD) == 0
                close(parentFD)
                guard synced else { return false }
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                state = State(highWater: now(), entries: [:])
                return true
            }
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0, info.st_size <= 1_000_000 else { return false }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: 1_000_001) ?? Data()
            if let decoded = try? JSONDecoder().decode(State.self, from: data) {
                guard decoded.version == 3, decoded.highWater.isFinite,
                      decoded.highWater >= 0, decoded.entries.count <= maxEntries
                else { return false }
                state = decoded
            } else {
                // Version 2 stored only a dictionary. Keep its entries as
                // tombstones: old UUID keys cannot pass the new request shape,
                // and pending legacy writes must never be retried silently.
                let legacy = try JSONDecoder().decode([String: Entry].self, from: data)
                guard legacy.count <= maxEntries else { return false }
                state = State(highWater: now(), entries: legacy)
            }
            return true
        } catch { return false }
    }

    private func persist() -> Bool {
        guard let state, let data = try? JSONEncoder().encode(state),
              data.count <= 1_000_000 else { return false }
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let success = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard success, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        return fsync(directoryFD) == 0
    }
}

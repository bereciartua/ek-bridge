import CryptoKit
import Darwin
import Foundation

// A write is recorded as pending before EventKit is called. If the app stops
// between EventKit and the response, retrying cannot silently create twice.
// Pending entries require manual reconciliation. Completed entries keep the
// write's receipt for 7 days, which can include item IDs and reminder titles,
// so these files are private (0600) and never attached to an issue.
//
// Capacity is shared, so each client also has its own quota: one busy agent
// can fill its quota, but never block other clients' writes.
//
// Storage is sharded by client (`write-journal/<client>.json`) so a write
// rewrites only its client's file; with 10,000 entries in one file each
// fsynced rewrite took about 65 ms (§9.7 of the MCP plan). Every shard is
// loaded once and kept in memory, so keys, occurrence checks, the clock
// high-water mark and the total cap stay global. `write-journal.json` keeps
// entries written before sharding and entries without a client.
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
        // Nil for entries written before per-client quotas; those count only
        // toward the total. Older builds ignore the field.
        var clientID: String? = nil
    }
    private struct State: Codable {
        var version = 3
        var highWater: TimeInterval
        var entries: [String: Entry]
    }

    static let defaultMaxEntries = 10_000
    static let defaultMaxEntriesPerClient = 2_000
    static let maxFileBytes = 8_000_000
    static let maxShardBytes = 4_000_000
    static let shardFolderName = "write-journal"

    private let directory: URL
    private let file: URL
    private let shardDirectory: URL
    private let now: () -> TimeInterval
    private let maxEntries: Int
    private let maxEntriesPerClient: Int
    /// Keyed by shard name; "" is `write-journal.json`.
    private var shards: [String: State]?
    private var highWater: TimeInterval = 0

    init(directory override: URL? = nil,
         maxEntries: Int = WriteJournal.defaultMaxEntries,
         maxEntriesPerClient: Int = WriteJournal.defaultMaxEntriesPerClient,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        directory = override ?? AppIdentity.dataFolder(inSupport: support)
        file = directory.appendingPathComponent("write-journal.json")
        shardDirectory = directory.appendingPathComponent(Self.shardFolderName, isDirectory: true)
        self.maxEntries = maxEntries
        self.maxEntriesPerClient = maxEntriesPerClient
        self.now = now
    }

    func inspect(_ request: BridgeRequest, clientID: String? = nil) -> Decision {
        guard let key = request.parameters["idempotencyKey"] as? String,
              WriteIdempotencyKey.timestamp(key) != nil,
              let digest = digest(request) else { return .reject("invalid_idempotency_key") }
        guard load() else { return .reject("journal_unavailable") }
        let current = now()
        guard current.isFinite, current + WriteIdempotencyKey.futureSkew >= highWater
        else { return .reject("journal_clock_rollback") }
        guard WriteIdempotencyKey.isCurrent(key, now: current)
        else { return .reject("idempotency_expired") }
        pruneCompletedExpired(now: current)
        if let entry = entry(for: key)?.entry {
            guard entry.digest == digest else { return .reject("idempotency_conflict") }
            guard let data = entry.result,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .reject("idempotency_pending_review") }
            return .repeatResult(result)
        }
        if let semantic = semanticDigest(request), let match = semanticMatch(semantic) {
            return .reject(Self.semanticCode(request, done: match))
        }
        let all = shards!.values.lazy.flatMap(\.entries.values)
        guard all.count < maxEntries else { return .reject("journal_full") }
        if let clientID, all.filter({ $0.clientID == clientID }).count >= maxEntriesPerClient {
            return .reject("journal_full")
        }
        return .execute
    }

    func begin(_ request: BridgeRequest, clientID: String? = nil) -> Decision {
        switch inspect(request, clientID: clientID) {
        case .repeatResult(let result): return .repeatResult(result)
        case .reject(let error): return .reject(error)
        case .execute: break
        }
        guard let key = request.parameters["idempotencyKey"] as? String,
              let digest = digest(request) else { return .reject("invalid_idempotency_key") }
        let semantic = semanticDigest(request)
        if let semantic, let match = semanticMatch(semantic) {
            return .reject(Self.semanticCode(request, done: match))
        }
        let shard = Self.shardName(clientID)
        shards![shard, default: State(highWater: highWater, entries: [:])].entries[key] =
            Entry(digest: digest, semanticDigest: semantic, result: nil, clientID: clientID)
        highWater = max(highWater, now())
        guard persist(shard) else { return .reject("journal_unavailable") }
        return .execute
    }

    func finish(_ request: BridgeRequest, result: [String: Any]) -> Bool {
        guard let key = request.parameters["idempotencyKey"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let shard = entry(for: key)?.shard else { return false }
        shards![shard]!.entries[key]?.result = data
        highWater = max(highWater, now())
        guard persist(shard) else {
            shards![shard]!.entries[key]?.result = nil
            return false
        }
        return true
    }

    /// The file a client's entries go to. Client IDs are UUIDs; anything
    /// else is hashed so it can never name a path.
    static func shardName(_ clientID: String?) -> String {
        guard let clientID else { return "" }
        if let uuid = UUID(uuidString: clientID) { return uuid.uuidString.lowercased() }
        return SHA256.hash(data: Data(clientID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func entry(for key: String) -> (shard: String, entry: Entry)? {
        for (name, state) in shards! {
            if let entry = state.entries[key] { return (name, entry) }
        }
        return nil
    }

    /// An earlier request for the same occurrence: true when it finished
    /// successfully, false while its outcome is unknown (pending), nil when
    /// none, or when it failed (a failed write doesn't block a deliberate retry).
    private func semanticMatch(_ semantic: String) -> Bool? {
        var pending = false
        for shard in shards!.values {
            for entry in shard.entries.values where entry.semanticDigest == semantic {
                guard let data = entry.result,
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { pending = true; continue }
                if result["error"] == nil { return true }
            }
        }
        return pending ? false : nil
    }

    private static func semanticCode(_ request: BridgeRequest, done: Bool) -> String {
        guard request.command == .deleteEvent else { return "occurrence_already_requested" }
        // Only a delete that's known to have happened is "already applied".
        return done ? "already_applied" : "idempotency_pending_review"
    }

    private func pruneCompletedExpired(now current: TimeInterval) {
        var pruned = false
        for name in Array(shards!.keys) {
            let before = shards![name]!.entries.count
            shards![name]!.entries = shards![name]!.entries.filter { key, entry in
                guard entry.result != nil,
                      let issued = WriteIdempotencyKey.timestamp(key) else { return true }
                return current - issued <= WriteIdempotencyKey.lifetime +
                    WriteIdempotencyKey.futureSkew
            }
            pruned = pruned || shards![name]!.entries.count != before
        }
        // If the clock jumps forward then back before the next disk write,
        // the in-memory high-water mark still blocks reuse of pruned keys.
        if pruned { highWater = max(highWater, current) }
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
        // Two keys can't delete the same occurrence (plan 03 §8.3).
        if request.command == .deleteEvent {
            guard let calendar = request.parameters["calendarID"] as? String,
                  let item = request.parameters["itemID"] as? String,
                  let number = request.parameters["occurrenceStart"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            let start = number.int64Value
            let object: [String: Any] = ["command": "delete_event", "calendarID": calendar, "itemID": item,
                                         "occurrenceStart": start,
                                         "span": request.parameters["span"] as? String ?? "this"]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
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

    // MARK: Files

    private func load() -> Bool {
        if shards != nil { return true }
        do {
            let existed = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard Self.privateDirectory(directory) else { return false }
            if !existed {
                guard Self.syncDirectory(directory.deletingLastPathComponent()) else { return false }
            }
            var loaded = [String: State]()
            if FileManager.default.fileExists(atPath: file.path) {
                guard let data = Self.readPrivate(file, maxBytes: Self.maxFileBytes) else { return false }
                if let decoded = try? JSONDecoder().decode(State.self, from: data) {
                    guard decoded.version == 3, decoded.highWater.isFinite,
                          decoded.highWater >= 0, decoded.entries.count <= maxEntries
                    else { return false }
                    loaded[""] = decoded
                } else {
                    // Version 2 stored only a dictionary. Keep its entries as
                    // tombstones: old UUID keys cannot pass the new request shape,
                    // and pending legacy writes must never be retried silently.
                    let legacy = try JSONDecoder().decode([String: Entry].self, from: data)
                    guard legacy.count <= maxEntries else { return false }
                    loaded[""] = State(highWater: now(), entries: legacy)
                }
            }
            if FileManager.default.fileExists(atPath: shardDirectory.path) {
                guard Self.privateDirectory(shardDirectory) else { return false }
                for name in try FileManager.default.contentsOfDirectory(atPath: shardDirectory.path)
                where name.hasSuffix(".json") && !name.hasPrefix(".") {
                    let url = shardDirectory.appendingPathComponent(name)
                    guard let data = Self.readPrivate(url, maxBytes: Self.maxShardBytes),
                          let decoded = try? JSONDecoder().decode(State.self, from: data),
                          decoded.version == 3, decoded.highWater.isFinite, decoded.highWater >= 0,
                          decoded.entries.count <= maxEntries else { return false }
                    loaded[String(name.dropLast(5))] = decoded
                }
            }
            guard loaded.values.map(\.entries.count).reduce(0, +) <= maxEntries else { return false }
            highWater = loaded.values.map(\.highWater).max() ?? now()
            shards = loaded
            return true
        } catch { return false }
    }

    private func persist(_ shard: String) -> Bool {
        guard var state = shards?[shard] else { return false }
        state.highWater = highWater
        let target: URL
        let limit: Int
        if shard.isEmpty {
            target = file
            limit = Self.maxFileBytes
        } else {
            if !FileManager.default.fileExists(atPath: shardDirectory.path) {
                guard mkdir(shardDirectory.path, 0o700) == 0 || errno == EEXIST,
                      Self.syncDirectory(directory) else { return false }
            }
            guard Self.privateDirectory(shardDirectory) else { return false }
            target = shardDirectory.appendingPathComponent(shard + ".json")
            limit = Self.maxShardBytes
        }
        guard let data = try? JSONEncoder().encode(state), data.count <= limit else { return false }
        shards![shard]?.highWater = highWater
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".tmp-\(UUID().uuidString)")
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
        guard success, rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return Self.syncDirectory(folder)
    }

    private static func privateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() &&
            info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o077 == 0
    }

    private static func syncDirectory(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
    }

    private static func readPrivate(_ url: URL, maxBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= maxBytes,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }
}

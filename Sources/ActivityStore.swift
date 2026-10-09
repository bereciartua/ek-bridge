import Darwin
import Foundation

/// The item a change touched, by EventKit identifier only. Never a title,
/// notes or other content: the app looks the item up live to name it.
struct ItemRef: Codable, Equatable, Hashable {
    /// "event" or "reminder".
    let kind: String
    /// `eventIdentifier` (an event's series) or `calendarItemIdentifier`.
    let id: String
    /// The occurrence: an event's `occurrenceStart`, or a repeating
    /// reminder's completed due date, in seconds since 1970.
    var occurrence: Double? = nil
    /// "this", "future" or "all" for events; the recurrence scope for reminders.
    var span: String? = nil
    /// `calendarItemExternalIdentifier` when known (stabler across sync).
    var externalID: String? = nil

    static let maxIDBytes = 512

    /// IDs come from EventKit or from the request; anything odd isn't kept.
    var isValid: Bool {
        ["event", "reminder"].contains(kind) && Self.validID(id) &&
            (externalID.map(Self.validID) ?? true) &&
            (span.map { $0.utf8.count <= 16 && Self.validID($0) } ?? true) &&
            (occurrence?.isFinite ?? true)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxIDBytes && id.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

/// One line of `activity/activity.jsonl`. A request writes a "start" row
/// when it's accepted and a "result" row when it ends; a request refused
/// before that (and a failed sign-in) writes one "event" row.
///
/// Stores the time, connection, command, result, calendar or list ID, how
/// the request came in, the agent's reported name, the approval answer and,
/// for changes, the item's EventKit ID. Never titles or other item content,
/// keys or tokens.
struct ActivityRecord: Codable, Equatable {
    var v = 1
    /// Unique row ID: "<requestID>|<phase>", or "legacy|…" for imported rows.
    var id: String
    /// "<clientID or ->|<request ID>"; joins a start row to its result. Nil
    /// for rows imported from the registry and for failed sign-ins.
    var requestID: String? = nil
    let phase: String
    let at: Date
    let clientID: String?
    let command: String
    /// "accepted", "success", "forbidden", "unauthorized" or "error:<code>".
    let outcome: String
    /// The calendar or list the request named (a move's source).
    var targetID: String? = nil
    /// A move's destination calendar or list.
    var destinationID: String? = nil
    /// "cli", "mcp" or "remote".
    var via: String? = nil
    /// The agent's name as it reported it; display only.
    var agent: String? = nil
    /// How Ask before changes or an access request was answered.
    var approval: String? = nil
    /// Writes only.
    var item: ItemRef? = nil
    /// A `forbidden` refusal: the `ClientGrant` bit the connection lacked.
    var missing: Int? = nil

    static let start = "start"
    static let result = "result"
    static let event = "event"

    /// Ask before changes ("user", "window", "denied", "timeout") and access
    /// requests ("access_…"). Only the first four ever go in the registry.
    static let approvalValues: Set<String> = [
        "user", "window", "denied", "timeout",
        "access_once", "access_always", "access_denied", "access_timeout",
    ]

    var isWrite: Bool { BridgeCommand(rawValue: command)?.isWrite == true }
}

/// Where the registry writes Activity. `ActivityStore` is the real one.
protocol ActivityRecorder: AnyObject {
    /// Appends and syncs one row. False when it couldn't be written; the
    /// request is then refused with `activity_unavailable`.
    func append(_ record: ActivityRecord) -> Bool
    /// Every kept row, oldest first.
    func records() -> [ActivityRecord]
    /// Whether a row with this ID exists (the registry import skips it).
    func contains(id: String) -> Bool
}

/// For tests.
final class InMemoryActivityRecorder: ActivityRecorder {
    private(set) var rows = [ActivityRecord]()
    var failing = false

    func append(_ record: ActivityRecord) -> Bool {
        guard !failing else { return false }
        rows.append(record)
        return true
    }

    func records() -> [ActivityRecord] { rows }
    func contains(id: String) -> Bool { rows.contains { $0.id == id } }
}

/// How long Activity keeps a row (P6): changes and problems for 90 days (at
/// most 5,000), everything else for 7 days (at most 2,000). A start row is
/// kept only while its request hasn't finished, and for at most a day.
enum ActivityRetention {
    static let importantAge: TimeInterval = 90 * 86_400
    static let importantLimit = 5_000
    static let routineAge: TimeInterval = 7 * 86_400
    static let routineLimit = 2_000
    static let startAge: TimeInterval = 86_400

    /// A change (any outcome), anything that didn't succeed, or a row with an
    /// approval answer. Refusals and errors of reads count: they're what the
    /// user comes back to look for.
    static func isImportant(_ record: ActivityRecord) -> Bool {
        record.isWrite || record.outcome != "success" || record.approval != nil
    }

    /// `records` oldest first; the result keeps that order.
    static func keep(_ records: [ActivityRecord], now: Date) -> [ActivityRecord] {
        let finished = Set(records.compactMap { $0.phase == ActivityRecord.start ? nil : $0.requestID })
        var importantLeft = importantLimit
        var routineLeft = routineLimit
        var kept = [ActivityRecord]()
        kept.reserveCapacity(min(records.count, importantLimit + routineLimit))
        // Newest first, so the limits drop the oldest rows.
        for record in records.reversed() {
            let age = now.timeIntervalSince(record.at)
            if record.phase == ActivityRecord.start {
                guard age < startAge, let request = record.requestID, !finished.contains(request)
                else { continue }
                kept.append(record)
            } else if isImportant(record) {
                guard age < importantAge, importantLeft > 0 else { continue }
                importantLeft -= 1
                kept.append(record)
            } else {
                guard age < routineAge, routineLeft > 0 else { continue }
                routineLeft -= 1
                kept.append(record)
            }
        }
        return kept.reversed()
    }
}

/// `<data>/activity/activity.jsonl`: append-only JSON Lines, one
/// `ActivityRecord` per line, 0600 in a 0700 folder.
///
/// Activity is a log, not a security decision, so it doesn't fail closed: an
/// unreadable line is skipped and counted. It lives outside the registry so
/// that file stays small and older versions keep loading it (0.8.2 refuses a
/// registry with more than 500 rows or approval values it doesn't know).
///
/// Thread-safe. Appends come from the main thread; compaction runs on a
/// background queue and rows appended meanwhile go to both files.
final class ActivityStore: ActivityRecorder {
    static let folderName = "activity"
    static let fileName = "activity.jsonl"
    /// Only the newest 16 MB are read at launch.
    static let maxReadBytes = 16 << 20
    /// Compact when the file grows past this, and at least every 6 hours.
    static let compactBytes = 8 << 20
    static let compactInterval: TimeInterval = 6 * 3_600

    let folder: URL
    let file: URL
    private let now: () -> Date
    private let autoCompact: Bool
    private let sync: (Int32) -> Int32
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ActivityStore.compaction", qos: .utility)

    private var loaded = false
    private var rows = [ActivityRecord]()
    private var ids = Set<String>()
    private var descriptor: Int32 = -1
    private var fileBytes = 0
    private var compacting = false
    private var appendedWhileCompacting = [ActivityRecord]()
    private var lastCompaction: Date?
    /// Lines skipped at load because they didn't decode.
    private(set) var invalidLines = 0

    /// `dataFolder` is the app's data folder; the store uses `activity/` in it.
    /// `sync` is `fsync`, injectable to test a failing disk.
    init(dataFolder: URL, now: @escaping () -> Date = Date.init, autoCompact: Bool = false,
         sync: @escaping (Int32) -> Int32 = { fsync($0) }) {
        folder = dataFolder.appendingPathComponent(Self.folderName, isDirectory: true)
        file = folder.appendingPathComponent(Self.fileName)
        self.now = now
        self.autoCompact = autoCompact
        self.sync = sync
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    func records() -> [ActivityRecord] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return rows
    }

    func contains(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return ids.contains(id)
    }

    var skippedLines: Int {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return invalidLines
    }

    func append(_ record: ActivityRecord) -> Bool {
        lock.lock()
        loadIfNeeded()
        var record = record
        // Request IDs are unique per connection, but a reused one (or a
        // second row in the same phase) must still get its own row ID.
        if ids.contains(record.id) {
            var ordinal = 2
            while ids.contains("\(record.id)#\(ordinal)") { ordinal += 1 }
            record.id = "\(record.id)#\(ordinal)"
        }
        guard let line = Self.encode(record), openForAppend() else {
            lock.unlock()
            return false
        }
        // A write that fails partway (a full disk) or isn't synced is taken
        // back, so a torn line can't swallow the next row.
        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0, write(line, to: descriptor) else {
            if end >= 0 { ftruncate(descriptor, end) }
            lock.unlock()
            return false
        }
        fileBytes += line.count
        rows.append(record)
        ids.insert(record.id)
        if compacting { appendedWhileCompacting.append(record) }
        let due = autoCompact && !compacting && (fileBytes > Self.compactBytes ||
            lastCompaction.map { now().timeIntervalSince($0) >= Self.compactInterval } ?? true)
        lock.unlock()
        if due { scheduleCompaction() }
        return true
    }

    /// Compacts in the background (at launch, and when `append` finds it due).
    func scheduleCompaction() {
        queue.async { [weak self] in _ = self?.compact() }
    }

    /// Rewrites the file with only the rows `ActivityRetention` keeps. Rows
    /// appended meanwhile are added to the new file before it replaces the old.
    @discardableResult
    func compact() -> Bool {
        lock.lock()
        loadIfNeeded()
        guard !compacting else { lock.unlock(); return false }
        compacting = true
        appendedWhileCompacting = []
        let snapshot = rows
        let at = now()
        lock.unlock()

        let kept = ActivityRetention.keep(snapshot, now: at)
        var data = Data()
        for record in kept { if let line = Self.encode(record) { data.append(line) } }
        let temporary = folder.appendingPathComponent(Self.fileName + ".tmp")
        unlink(temporary.path)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var ok = fd >= 0 && write(data, to: fd)

        lock.lock()
        defer {
            compacting = false
            appendedWhileCompacting = []
            lock.unlock()
        }
        var tail = Data()
        for record in appendedWhileCompacting { if let line = Self.encode(record) { tail.append(line) } }
        ok = ok && write(tail, to: fd) && sync(fd) == 0
        if fd >= 0 { close(fd) }
        guard ok, Darwin.rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        syncFolder()
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        rows = kept + appendedWhileCompacting
        ids = Set(rows.map(\.id))
        fileBytes = data.count + tail.count
        lastCompaction = at
        return true
    }

    // MARK: File

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func encode(_ record: ActivityRecord) -> Data? {
        guard var data = try? encoder().encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Reads the newest `maxReadBytes` of the file. Caller holds the lock.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { return }
        let size = Int(info.st_size)
        fileBytes = size
        let skip = max(0, size - Self.maxReadBytes)
        if skip > 0 { lseek(fd, off_t(skip), SEEK_SET) }
        guard var data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            .read(upToCount: Self.maxReadBytes) else { return }
        // Starting mid-file: drop the partial first line.
        if skip > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        let decoder = Self.decoder()
        var seen = Set<String>()
        var loadedRows = [ActivityRecord]()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(ActivityRecord.self, from: line),
                  record.v == 1, !seen.contains(record.id) else {
                invalidLines += 1
                continue
            }
            seen.insert(record.id)
            loadedRows.append(record)
        }
        rows = loadedRows
        ids = seen
    }

    /// Opens the file for appending, creating the folder (0700) and file
    /// (0600). Refuses links and files owned by someone else. Caller holds the lock.
    private func openForAppend() -> Bool {
        if descriptor >= 0 { return true }
        // The data folder too, as the registry does on its first write.
        let parent = folder.deletingLastPathComponent().path
        if mkdir(parent, 0o700) != 0 && errno != EEXIST { return false }
        if mkdir(folder.path, 0o700) != 0 && errno != EEXIST { return false }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR else { return false }
        if info.st_mode & 0o077 != 0 { chmod(folder.path, 0o700) }
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return false
        }
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        descriptor = fd
        return true
    }

    private func write(_ data: Data, to fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        if data.isEmpty { return true }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        // Appends sync themselves; compaction syncs once at the end.
        return written && (fd != descriptor || sync(fd) == 0)
    }

    private func syncFolder() {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = sync(fd)
        close(fd)
    }
}

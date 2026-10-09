import Darwin
import Foundation

@main
struct ActivityStoreTests {
    static func main() throws {
        try appendAndLoad()
        try invalidLines()
        try compaction()
        try appendDuringCompaction()
        try failingDisk()
        retention()
        try performance()
        print("Activity store: append, load, file modes, invalid lines skipped, unique IDs, compaction, "
              + "appends during compaction, failing fsync, retention rules at their boundaries passed")
    }

    static let base = Date(timeIntervalSince1970: 2_000_000_000)

    static func record(_ n: Int, phase: String = ActivityRecord.result, command: String = "read_events",
                       outcome: String = "success", at: Date = base, request: String? = nil,
                       approval: String? = nil) -> ActivityRecord {
        let requestID = request ?? "client|r\(n)"
        var row = ActivityRecord(id: "\(requestID)|\(phase)", requestID: requestID, phase: phase, at: at,
                                 clientID: "client", command: command, outcome: outcome)
        row.approval = approval
        return row
    }

    static func appendAndLoad() throws {
        let data = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let store = ActivityStore(dataFolder: data)
        precondition(store.records().isEmpty)
        var write = record(1, command: "update_event")
        write.item = ItemRef(kind: "event", id: "EV1", occurrence: 1_800_000_000, span: "this")
        write.missing = nil
        write.destinationID = "CAL-B"
        precondition(store.append(record(1, phase: ActivityRecord.start, outcome: "accepted")))
        precondition(store.append(write))
        // A reused ID still gets its own row.
        precondition(store.append(write))
        let rows = store.records()
        precondition(rows.count == 3 && rows[2].id == "client|r1|result#2")
        precondition(rows[1] == write)
        // Modes: folder 0700, file 0600.
        precondition(mode(store.folder) == 0o700 && mode(store.file) == 0o600)
        // A second process reads the same rows.
        let reloaded = ActivityStore(dataFolder: data).records()
        precondition(reloaded == rows, "\(reloaded)")
        precondition(ActivityStore(dataFolder: data).contains(id: "client|r1|result#2"))
        // One JSON object per line, no titles.
        let text = try String(contentsOf: store.file, encoding: .utf8)
        precondition(text.split(separator: "\n").count == 3)
        precondition(text.contains(#""item":{"id":"EV1","kind":"event","occurrence":1800000000,"span":"this"}"#),
                     text)
    }

    static func invalidLines() throws {
        let data = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let store = ActivityStore(dataFolder: data)
        precondition(store.append(record(1)))
        let handle = try FileHandle(forWritingTo: store.file)
        handle.seekToEndOfFile()
        handle.write(Data("{not json\n{\"v\":2,\"id\":\"x\"}\n\n".utf8))
        try handle.close()
        let other = ActivityStore(dataFolder: data)
        precondition(other.append(record(2)))
        let reread = ActivityStore(dataFolder: data)
        precondition(reread.records().map(\.id) == ["client|r1|result", "client|r2|result"])
        precondition(reread.skippedLines == 2)
    }

    static func compaction() throws {
        let data = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let now = base.addingTimeInterval(30 * 86_400)
        let store = ActivityStore(dataFolder: data, now: { now })
        // An old read (dropped), an old change (kept), a finished start
        // (dropped), an unfinished recent start (kept).
        precondition(store.append(record(1, at: base)))
        precondition(store.append(record(2, command: "create_event", at: base)))
        precondition(store.append(record(3, phase: ActivityRecord.start, outcome: "accepted",
                                         at: now.addingTimeInterval(-10))))
        precondition(store.append(record(3, at: now.addingTimeInterval(-9))))
        precondition(store.append(record(4, phase: ActivityRecord.start, outcome: "accepted",
                                         at: now.addingTimeInterval(-5))))
        precondition(store.compact())
        let kept = store.records().map(\.id)
        precondition(kept == ["client|r2|result", "client|r3|result", "client|r4|start"], "\(kept)")
        precondition(ActivityStore(dataFolder: data).records().map(\.id) == kept)
        precondition(mode(store.file) == 0o600)
        precondition(!FileManager.default.fileExists(atPath: store.file.path + ".tmp"))
        // Appending after compaction goes to the new file.
        precondition(store.append(record(5, at: now)))
        precondition(ActivityStore(dataFolder: data).records().count == 4)
    }

    static func appendDuringCompaction() throws {
        let data = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let store = ActivityStore(dataFolder: data, now: { base })
        for n in 0..<3_000 { precondition(store.append(record(n, command: "create_event"))) }
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { precondition(store.compact()) }
        // Appends from another thread while compaction runs.
        for n in 3_000..<3_200 { precondition(store.append(record(n, command: "create_event"))) }
        group.wait()
        let rows = store.records()
        precondition(rows.count == 3_200, "\(rows.count)")
        precondition(Set(rows.map(\.id)).count == 3_200)
        let reread = ActivityStore(dataFolder: data).records()
        precondition(reread.count == 3_200 && reread.last?.id == "client|r3199|result", "\(reread.count)")
    }

    static func failingDisk() throws {
        let data = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        var failing = false
        let store = ActivityStore(dataFolder: data, sync: { failing ? -1 : fsync($0) })
        precondition(store.append(record(1)))
        failing = true
        precondition(!store.append(record(2)), "a failed fsync reports failure")
        precondition(store.records().count == 1)
        failing = false
        precondition(store.append(record(3)))
        // The failed row was taken back: the file has rows 1 and 3, whole.
        precondition(ActivityStore(dataFolder: data).records().map(\.id) == ["client|r1|result", "client|r3|result"])
        precondition(ActivityStore(dataFolder: data).skippedLines == 0)
        // A folder that isn't ours or is a link: refused.
        let linked = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: linked) }
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("activity"),
                                                   withDestinationURL: data.appendingPathComponent("activity"))
        precondition(!ActivityStore(dataFolder: linked).append(record(4)), "a linked folder is refused")
    }

    static func retention() {
        let now = base
        let day: TimeInterval = 86_400
        func at(_ age: TimeInterval) -> Date { now.addingTimeInterval(-age) }
        // Routine reads: kept under 7 days.
        let reads = [record(1, at: at(7 * day - 1)), record(2, at: at(7 * day))]
        precondition(ActivityRetention.keep(reads, now: now).map(\.id) == ["client|r1|result"])
        // Changes, problems and approval answers: kept under 90 days.
        let important = [
            record(3, command: "delete_reminder", at: at(90 * day - 1)),
            record(4, command: "delete_reminder", at: at(90 * day)),
            record(5, outcome: "forbidden", at: at(89 * day)),
            record(6, outcome: "error:rate_limited", at: at(30 * day)),
            record(7, outcome: "success", at: at(30 * day), approval: "user"),
        ]
        precondition(ActivityRetention.keep(important, now: now).map(\.id) ==
                     ["client|r3|result", "client|r5|result", "client|r6|result", "client|r7|result"])
        // Start rows: kept while unfinished and under a day.
        let starts = [
            record(8, phase: ActivityRecord.start, outcome: "accepted", at: at(day - 1)),
            record(9, phase: ActivityRecord.start, outcome: "accepted", at: at(day)),
            record(10, phase: ActivityRecord.start, outcome: "accepted", at: at(10)),
            record(10, at: at(9)),
        ]
        precondition(ActivityRetention.keep(starts, now: now).map(\.id) ==
                     ["client|r8|start", "client|r10|result"])
        // Limits keep the newest: 2,000 routine and 5,000 important.
        let many = (0..<2_500).map { record($0, at: at(Double(2_500 - $0))) } +
            (0..<5_200).map { record(10_000 + $0, command: "create_event", at: at(Double(5_200 - $0))) }
        let kept = ActivityRetention.keep(many.sorted { $0.at < $1.at }, now: now)
        precondition(kept.filter { $0.command == "read_events" }.count == 2_000)
        precondition(kept.filter { $0.command == "create_event" }.count == 5_000)
        precondition(kept.first { $0.command == "read_events" }?.id == "client|r500|result")
        precondition(kept.first { $0.command == "create_event" }?.id == "client|r10200|result")
        precondition(zip(kept, kept.dropFirst()).allSatisfy { $0.at <= $1.at }, "order is kept")
        // Event rows (refusals before authorization) follow the same rules.
        var refused = record(11, phase: ActivityRecord.event, outcome: "error:bridge_off", at: at(30 * day))
        refused.requestID = nil
        precondition(ActivityRetention.keep([refused], now: now).count == 1)
    }

    /// 10,000 rows appended and loaded. Prints the time; doesn't fail on it.
    static func performance() throws {
        let data = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let store = ActivityStore(dataFolder: data, sync: { _ in 0 })
        for n in 0..<10_000 { precondition(store.append(record(n, command: n % 3 == 0 ? "update_event" : "read_events"))) }
        let start = Date()
        let loaded = ActivityStore(dataFolder: data).records()
        let elapsed = Date().timeIntervalSince(start)
        precondition(loaded.count == 10_000)
        print("Activity store: loaded 10,000 rows in \(Int(elapsed * 1_000)) ms (target under 300 ms)")
    }

    static func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0) & 0o777
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("eventkit-activity-\(UUID().uuidString)")
    }
}

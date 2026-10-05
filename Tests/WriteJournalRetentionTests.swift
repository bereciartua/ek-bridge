import Foundation

@main
struct WriteJournalRetentionTests {
    static func main() throws {
        var clock: TimeInterval = 2_000_000_000
        let formatProbe = WriteIdempotencyKey.make(now: clock)
        precondition(WriteIdempotencyKey.isCurrent(formatProbe, now: clock))
        precondition(WriteIdempotencyKey.isCurrent(formatProbe,
            now: clock + WriteIdempotencyKey.lifetime))
        precondition(!WriteIdempotencyKey.isCurrent(formatProbe,
            now: clock + WriteIdempotencyKey.lifetime + 1))
        precondition(WriteIdempotencyKey.timestamp(UUID().uuidString) == nil)
        precondition(WriteIdempotencyKey.timestamp("ekb3_02000000000_\(UUID().uuidString.lowercased())") == nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WriteJournal(directory: directory, maxEntries: 3, now: { clock })
        let original = (0..<3).map { index in
            request(key: WriteIdempotencyKey.make(now: clock), title: "Item \(index)")
        }
        for request in original {
            expectExecute(journal.begin(request))
            precondition(journal.finish(request, result: ["saved": true]))
        }
        let overflow = request(key: WriteIdempotencyKey.make(now: clock), title: "Overflow")
        expectError(journal.begin(overflow), "journal_full")
        let restarted = WriteJournal(directory: directory, maxEntries: 3, now: { clock })
        expectReplay(restarted.begin(original[0]))

        clock += WriteIdempotencyKey.lifetime + WriteIdempotencyKey.futureSkew + 1
        expectError(restarted.begin(original[0]), "idempotency_expired")
        let rollover = request(key: WriteIdempotencyKey.make(now: clock), title: "After expiry")
        expectExecute(restarted.inspect(rollover)) // Prune in memory only.
        let forward = clock
        clock = 2_000_000_000
        expectError(restarted.begin(original[0]), "journal_clock_rollback")
        clock = forward
        expectExecute(restarted.begin(rollover))
        precondition(restarted.finish(rollover, result: ["saved": true]))
        let afterRollover = WriteJournal(directory: directory, maxEntries: 3, now: { clock })
        expectReplay(afterRollover.begin(rollover))
        let saved = try JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("write-journal.json"))) as! [String: Any]
        let entries = saved["entries"] as! [String: Any]
        precondition(entries.count == 1 && entries[original[0].parameters["idempotencyKey"] as! String] == nil)

        // A wall-clock rollback cannot make a pruned key valid again.
        clock = 2_000_000_000
        let rollback = WriteJournal(directory: directory, maxEntries: 3, now: { clock })
        expectError(rollback.begin(original[0]), "journal_clock_rollback")

        let pendingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pendingDirectory) }
        clock = 2_000_000_000
        let pending = request(key: WriteIdempotencyKey.make(now: clock), title: "Uncertain")
        let first = WriteJournal(directory: pendingDirectory, maxEntries: 1, now: { clock })
        expectExecute(first.begin(pending))
        clock += WriteIdempotencyKey.lifetime + WriteIdempotencyKey.futureSkew + 1
        let pendingRestart = WriteJournal(directory: pendingDirectory, maxEntries: 1, now: { clock })
        expectError(pendingRestart.begin(pending), "idempotency_expired")
        expectError(pendingRestart.begin(
            request(key: WriteIdempotencyKey.make(now: clock), title: "Blocked")), "journal_full")

        // Version 2's UUID-only journal is decoded without deleting its
        // uncertain records; its keys are invalid under the new write shape.
        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        try FileManager.default.createDirectory(at: legacyDirectory,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let oldKey = UUID().uuidString
        let fixture = try JSONSerialization.data(withJSONObject: [oldKey: ["digest": "legacy", "result": NSNull()]])
        let legacyFile = legacyDirectory.appendingPathComponent("write-journal.json")
        try fixture.write(to: legacyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyFile.path)
        let migrated = WriteJournal(directory: legacyDirectory, maxEntries: 2, now: { clock })
        let fresh = request(key: WriteIdempotencyKey.make(now: clock), title: "Migrated")
        expectExecute(migrated.begin(fresh))
        let migratedData = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        precondition((migratedData["entries"] as! [String: Any])[oldKey] != nil)
        expectError(migrated.begin(request(key: oldKey, title: "Legacy retry")),
                    "invalid_idempotency_key")
        let oldV3Directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-old-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: oldV3Directory) }
        try FileManager.default.createDirectory(at: oldV3Directory,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let oldV3Key = WriteIdempotencyKey.make(now: clock)
        let oldV3: [String: Any] = ["version": 3, "highWater": clock,
            "entries": [oldV3Key: ["digest": "old-digest", "result": NSNull()]]]
        let oldV3File = oldV3Directory.appendingPathComponent("write-journal.json")
        try JSONSerialization.data(withJSONObject: oldV3).write(to: oldV3File)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                             ofItemAtPath: oldV3File.path)
        let oldV3Journal = WriteJournal(directory: oldV3Directory, now: { clock })
        expectExecute(oldV3Journal.inspect(request(
            key: WriteIdempotencyKey.make(now: clock), title: "New after v3")))
        let occurrenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-occurrence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: occurrenceDirectory) }
        let occurrence = WriteJournal(directory: occurrenceDirectory, now: { clock })
        let firstDue = 2_000_010_000
        let firstOccurrence = occurrenceRequest(key: WriteIdempotencyKey.make(now: clock),
                                               due: firstDue)
        expectExecute(occurrence.begin(firstOccurrence))
        expectError(occurrence.begin(occurrenceRequest(
            key: WriteIdempotencyKey.make(now: clock), due: firstDue)),
            "occurrence_already_requested")
        precondition(occurrence.finish(firstOccurrence, result: ["saved": true]))
        let occurrenceRestart = WriteJournal(directory: occurrenceDirectory, now: { clock })
        expectReplay(occurrenceRestart.begin(firstOccurrence))
        expectError(occurrenceRestart.begin(occurrenceRequest(
            key: WriteIdempotencyKey.make(now: clock), due: firstDue)),
            "occurrence_already_requested")
        expectExecute(occurrenceRestart.begin(occurrenceRequest(
            key: WriteIdempotencyKey.make(now: clock), due: firstDue + 86_400)))
        print("Write journal: rollover, expiry, restart, rollback, pending, legacy migration passed")
    }

    static func request(key: String, title: String) -> BridgeRequest {
        BridgeRequest(id: UUID().uuidString, command: .createReminder,
                      parameters: ["listID": "synthetic", "title": title,
                                   "idempotencyKey": key])
    }
    static func occurrenceRequest(key: String, due: Int) -> BridgeRequest {
        BridgeRequest(id: UUID().uuidString, command: .completeReminder,
                      parameters: ["listID": "synthetic", "itemID": "series",
                                   "expectedVersion": "1", "recurrenceScope": "occurrence",
                                   "occurrenceDue": due,
                                   "occurrenceFingerprint": String(repeating: "a", count: 64),
                                   "idempotencyKey": key])
    }
    static func expectExecute(_ result: WriteJournal.Decision) {
        guard case .execute = result else { preconditionFailure("expected execute") }
    }
    static func expectReplay(_ result: WriteJournal.Decision) {
        guard case .repeatResult(let value) = result,
              value["saved"] as? Bool == true else { preconditionFailure("expected cached result") }
    }
    static func expectError(_ result: WriteJournal.Decision, _ expected: String) {
        guard case .reject(let actual) = result, actual == expected
        else { preconditionFailure("expected \(expected)") }
    }
}

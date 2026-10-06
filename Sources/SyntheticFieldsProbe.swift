#if EVENTKIT_SYNTHETIC_TEST
import AppKit
import CoreLocation
import Darwin
import EventKit
import Foundation

// Plan 03 live checks (spikes S1, S2, S4, S5 storage and S6 on this Mac),
// built only for the supervised synthetic test. It creates its own uniquely
// named calendars and reminder lists in one account, drives the real
// EventKitCommands with a throwaway journal, records what the account kept,
// then removes the collections as a unit and checks they are gone. It never
// reads or changes any other calendar or list, and reports no titles but its
// own synthetic ones.
@MainActor
final class SyntheticFieldsProbe {
    private static let idsKey = "fieldsProbeCollectionIDs"
    private static let prefix = "EventKit Bridge Fields Probe"

    private let store = EKEventStore()
    private let commands: EventKitCommands
    private let journalDirectory: URL
    private var calendar: EKCalendar!
    private var calendar2: EKCalendar!
    private var list: EKCalendar!
    private var list2: EKCalendar!
    private var steps = [[String: Any]]()
    private var observations = [String: Any]()
    private var failures = 0

    private init() {
        journalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-fields-probe-\(UUID().uuidString)")
        commands = EventKitCommands(store: store, journal: WriteJournal(directory: journalDirectory))
    }

    static func run(source: String) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            report(["outcome": "full_access_required"]); return
        }
        guard UserDefaults.standard.array(forKey: idsKey) == nil else {
            report(["outcome": "previous_probe_not_cleaned_up"]); return
        }
        let probe = SyntheticFieldsProbe()
        var result: [String: Any]
        do {
            try probe.createCollections(source: source)
            probe.events()
            probe.reminders()
            result = ["outcome": probe.failures == 0 ? "passed" : "failed", "failures": probe.failures,
                      "steps": probe.steps, "observations": probe.observations, "source": source,
                      "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                      "macZone": TimeZone.current.identifier]
        } catch let error as ProbeError {
            result = ["outcome": error.code, "steps": probe.steps]
        } catch {
            result = ["outcome": "unexpected_error"]
        }
        result["cleanup"] = probe.cleanup()
        try? FileManager.default.removeItem(at: probe.journalDirectory)
        report(result)
    }

    /// Shows the macOS Calendar and Reminders prompts for this test build,
    /// which macOS treats as its own app.
    static func requestAccess() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let store = EKEventStore()
        var events: Bool?, reminders: Bool?
        store.requestFullAccessToEvents { granted, _ in DispatchQueue.main.async { events = granted } }
        let deadline = Date().addingTimeInterval(180)
        while events == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        store.requestFullAccessToReminders { granted, _ in DispatchQueue.main.async { reminders = granted } }
        while reminders == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        report(["outcome": "access_requested", "calendars": events ?? false, "reminders": reminders ?? false])
    }

    /// Leaves a few synthetic items for the owner to check on an iPhone (S4,
    /// S5, S6), in the probe's own collections. `--synthetic-fields-cleanup`
    /// removes them afterwards.
    static func stageForPhone() {
        guard UserDefaults.standard.array(forKey: idsKey) == nil else {
            report(["outcome": "previous_probe_not_cleaned_up"]); return
        }
        let probe = SyntheticFieldsProbe()
        var result: [String: Any] = ["outcome": "staged"]
        do {
            try probe.createCollections(source: "iCloud")
            result["items"] = probe.stage()
        } catch let error as ProbeError {
            result["outcome"] = error.code
            result["cleanup"] = probe.cleanup()
        } catch {}
        report(result)
    }

    private func stage() -> [String: Any] {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let tomorrow = local.date(byAdding: .day, value: 1, to: local.startOfDay(for: Date()))!
        let due = local.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        let zone = TimeZone.current.identifier
        let park: [String: Any] = ["title": "Apple Park", "latitude": 37.3349, "longitude": -122.0090, "radius": 200]
        var items = [String: Any]()
        let reminder = call(.createReminder, [
            "listID": list.calendarIdentifier, "title": "EKB phone check: URL, priority, notes, alarms",
            "due": ["kind": "timed", "at": seconds(due), "timeZone": zone],
            "start": ["kind": "timed", "at": seconds(due) - 3_600, "timeZone": zone],
            "notes": "Synthetic. Check the link, the priority and both alerts.",
            "url": "https://example.com/eventkit-bridge", "priority": "high",
            "alarms": [["kind": "relative", "offset": -3_600],
                       ["kind": "location", "location": park, "proximity": "leave"]]])
        items["reminder"] = error(reminder) == "none" ? "created" : error(reminder)
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        var madridDay = Calendar(identifier: .gregorian)
        madridDay.timeZone = madrid
        var meeting = madridDay.date(bySettingHour: 18, minute: 0, second: 0,
                                     of: madridDay.date(byAdding: .day, value: 2, to: Date())!)!
        let weekday = RecurrenceSpec.Weekday.codes[madridDay.component(.weekday, from: meeting) - 1]
        meeting = madridDay.date(bySettingHour: 18, minute: 0, second: 0, of: meeting)!
        let event = call(.createEvent, [
            "calendarID": calendar.calendarIdentifier, "title": "EKB phone check: Madrid meeting",
            "start": seconds(meeting), "end": seconds(meeting) + 3_600, "timeZone": "Europe/Madrid",
            "notes": "Synthetic. Check the time zone, map, link and alerts.",
            "structuredLocation": park, "url": "https://example.com/meeting",
            "alarms": [["kind": "relative", "offset": -900],
                       ["kind": "location", "location": park, "proximity": "arrive"]],
            "recurrence": ["kind": "rule", "frequency": "weekly", "weekdays": [weekday],
                           "end": ["kind": "count", "count": 3]]])
        items["event"] = error(event) == "none" ? "created" : error(event)
        let daily = call(.createReminder, [
            "listID": list.calendarIdentifier, "title": "EKB phone check: daily (one completed)",
            "due": ["kind": "timed", "at": seconds(due), "timeZone": zone, "alarmAt": NSNull()],
            "recurrence": ["kind": "rule", "frequency": "daily"]])
        let dailyID = item(daily)["id"] as? String ?? ""
        let row = item(call(.getReminder, ["listID": list.calendarIdentifier, "itemID": dailyID]))
        if let candidate = row["completionCandidate"] as? [String: Any] {
            let completed = call(.completeReminder, [
                "listID": list.calendarIdentifier, "itemID": dailyID, "expectedVersion": row["version"] ?? "",
                "recurrenceScope": "occurrence", "occurrenceDue": candidate["occurrenceDue"] ?? 0,
                "occurrenceFingerprint": candidate["occurrenceFingerprint"] ?? ""])
            items["dailyCompletion"] = completed["completedOccurrence"] != nil ? "verified on this Mac" : error(completed)
        } else {
            items["dailyCompletion"] = "no completion candidate"
        }
        return items
    }

    /// Writes a few shapes straight through EventKit and reports what reads back.
    static func diagnose() {
        let probe = SyntheticFieldsProbe()
        var result: [String: Any] = ["outcome": "diagnosed"]
        do {
            try probe.createCollections(source: "iCloud")
            result["checks"] = probe.rawChecks()
        } catch let error as ProbeError {
            result["outcome"] = error.code
        } catch {}
        result["cleanup"] = probe.cleanup()
        report(result)
    }

    private func partsOf(_ c: DateComponents?) -> Any {
        guard let c else { return "nil" }
        return ["y": c.year ?? -1, "m": c.month ?? -1, "d": c.day ?? -1, "h": c.hour ?? -1, "min": c.minute ?? -1,
                "s": c.second ?? -1, "tz": c.timeZone?.identifier ?? "nil"]
    }

    private func rawChecks() -> [[String: Any]] {
        var rows = [[String: Any]]()
        let start = nextTuesday(hour: 10, zone: TimeZone(identifier: "Europe/Madrid")!)
        func place(_ location: EKStructuredLocation?) -> Any {
            guard let location else { return "nil" }
            return ["title": location.title ?? "nil",
                    "lat": location.geoLocation?.coordinate.latitude ?? -999,
                    "lon": location.geoLocation?.coordinate.longitude ?? -999, "radius": location.radius]
        }
        for (label, text, title, radius) in [] as [(String, String, String, Double)] {
            for order in ["pin then text", "text then pin", "pin only"] {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = "EventKit Bridge Synthetic Pin"
                event.startDate = start
                event.endDate = start.addingTimeInterval(3_600)
                event.timeZone = TimeZone(identifier: "Europe/Madrid")
                let pin = EKStructuredLocation(title: title)
                pin.geoLocation = CLLocation(latitude: 40.4168, longitude: -3.7038)
                if radius > 0 { pin.radius = radius }
                switch order {
                case "pin then text": event.structuredLocation = pin; event.location = text
                case "text then pin": event.location = text; event.structuredLocation = pin
                default: event.structuredLocation = pin
                }
                let before = place(event.structuredLocation)
                do { try store.save(event, span: .thisEvent, commit: true) } catch {
                    rows.append(["check": "pin \(label), \(order)", "error": "\(error)"]); continue
                }
                let back = event.eventIdentifier.flatMap(store.event(withIdentifier:))
                rows.append(["check": "pin \(label), \(order)", "inMemory": before,
                             "saved": place(back?.structuredLocation), "location": back?.location ?? "nil"])
                try? store.remove(event, span: .thisEvent, commit: true)
            }
        }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let dueDate = local.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(10 * 86_400))!
        // All-day dates as midnights in the Mac's zone.
        do {
            let first = local.startOfDay(for: start.addingTimeInterval(3 * 86_400))
            let end = local.date(byAdding: .day, value: 3, to: first)!
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = "EventKit Bridge Synthetic All Day"
            event.timeZone = nil
            event.isAllDay = true
            event.startDate = first
            event.endDate = end
            let memory = [event.startDate.timeIntervalSince1970, event.endDate.timeIntervalSince1970]
            try store.save(event, span: .thisEvent, commit: true)
            let back = event.eventIdentifier.flatMap(store.event(withIdentifier:))
            var row: [String: Any] = ["check": "all-day floating"]
            row["requested"] = [first.timeIntervalSince1970, end.timeIntervalSince1970]
            row["inMemory"] = memory
            row["saved"] = [back?.startDate.timeIntervalSince1970 ?? -1, back?.endDate.timeIntervalSince1970 ?? -1]
            row["allDay"] = back?.isAllDay ?? false
            rows.append(row)
            try? store.remove(event, span: .thisEvent, commit: true)
        } catch { rows.append(["check": "all-day floating", "error": "\(error)"]) }
        // A repeating reminder with a due day.
        for rule in [true, false] {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = "EventKit Bridge Synthetic Due Day"
            var due = local.dateComponents([.year, .month, .day], from: dueDate)
            due.calendar = local
            due.timeZone = local.timeZone
            reminder.startDateComponents = due
            reminder.dueDateComponents = due
            if rule { reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)] }
            do {
                try store.save(reminder, commit: true)
                let back = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder
                rows.append(["check": rule ? "due day, repeating" : "due day", "requested": partsOf(due),
                             "savedDue": partsOf(back?.dueDateComponents), "savedStart": partsOf(back?.startDateComponents)])
                try? store.remove(reminder, commit: true)
            } catch { rows.append(["check": "due day", "error": "\(error)"]) }
        }
        return rows
    }

    static func cleanupOnly() {
        let probe = SyntheticFieldsProbe()
        report(["outcome": "cleanup_checked", "cleanup": probe.cleanup()])
    }

    struct ProbeError: Error { let code: String }

    // MARK: Collections

    private func createCollections(source name: String) throws {
        // Calendars and reminder lists of one account can live in different sources.
        func source(_ type: EKEntityType) -> EKSource? {
            name == "local"
                ? store.sources.first { $0.sourceType == .local }
                : store.sources.first {
                    $0.title == "iCloud" && $0.sourceType == .calDAV && !$0.isDelegate &&
                        !$0.calendars(for: type).isEmpty
                }
        }
        guard let eventSource = source(.event), let reminderSource = source(.reminder) else {
            throw ProbeError(code: "source_unavailable")
        }
        let existing = store.calendars(for: .event) + store.calendars(for: .reminder)
        guard !existing.contains(where: { $0.title.hasPrefix(Self.prefix) }) else {
            throw ProbeError(code: "name_collision")
        }
        var ids = [String]()
        func make(_ type: EKEntityType, _ suffix: String) throws -> EKCalendar {
            let collection = EKCalendar(for: type, eventStore: store)
            collection.title = "\(Self.prefix)\(suffix)"
            collection.source = type == .event ? eventSource : reminderSource
            do { try store.saveCalendar(collection, commit: true) } catch {
                let value = error as NSError
                throw ProbeError(code: "collection_create_failed: \(type == .event ? "calendar" : "list") "
                    + "\(value.domain) \(value.code)")
            }
            ids.append(collection.calendarIdentifier)
            UserDefaults.standard.set(ids, forKey: Self.idsKey)
            _ = UserDefaults.standard.synchronize()
            return collection
        }
        calendar = try make(.event, "")
        calendar2 = try make(.event, " 2")
        list = try make(.reminder, "")
        list2 = try make(.reminder, " 2")
        observations["separate_reminder_source"] = eventSource.sourceIdentifier != reminderSource.sourceIdentifier
        observations["availabilities"] = EventAvailabilityMapping.supported(calendar).map(\.rawValue).sorted()
    }

    /// Removes only collections this probe created and recorded, then checks.
    private func cleanup() -> [String: Any] {
        let ids = UserDefaults.standard.array(forKey: Self.idsKey) as? [String] ?? []
        var removed = 0, failed = 0
        for id in ids {
            guard let collection = (store.calendars(for: .event) + store.calendars(for: .reminder))
                    .first(where: { $0.calendarIdentifier == id }) else { continue }
            guard collection.title.hasPrefix(Self.prefix) else { failed += 1; continue }
            do { try store.removeCalendar(collection, commit: true); removed += 1 } catch { failed += 1 }
        }
        store.refreshSourcesIfNecessary()
        let left = (store.calendars(for: .event) + store.calendars(for: .reminder))
            .filter { ids.contains($0.calendarIdentifier) || $0.title.hasPrefix(Self.prefix) }.count
        if failed == 0 && left == 0 {
            UserDefaults.standard.removeObject(forKey: Self.idsKey)
            _ = UserDefaults.standard.synchronize()
        }
        return ["removed": removed, "failed": failed, "remaining": left]
    }

    // MARK: Calls

    private func call(_ command: BridgeCommand, _ parameters: [String: Any], move: String? = nil) -> [String: Any] {
        var p = parameters
        if command.isWrite { p["idempotencyKey"] = WriteIdempotencyKey.make() }
        let request = BridgeRequest(id: UUID().uuidString.lowercased(), command: command, parameters: p)
        let scope = BridgeScope(calendarID: calendar.calendarIdentifier, reminderListID: list.calendarIdentifier,
                                generation: 0, moveTargetID: move)
        var result: [String: Any]?
        commands.runAuthorized(request, clientID: "synthetic-fields-probe", selected: scope,
                               stillAuthorized: { true }, isCancelled: { false }) { result = $0 }
        let deadline = Date().addingTimeInterval(30)
        while result == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result ?? ["error": "probe_timeout"]
    }

    @discardableResult
    private func step(_ name: String, _ ok: Bool, _ detail: [String: Any] = [:]) -> Bool {
        var entry = detail
        entry["step"] = name
        entry["ok"] = ok
        steps.append(entry)
        if !ok { failures += 1 }
        return ok
    }

    private func item(_ result: [String: Any]) -> [String: Any] { result["item"] as? [String: Any] ?? [:] }
    private func error(_ result: [String: Any]) -> String { result["error"] as? String ?? "none" }

    // MARK: Times

    /// The first Tuesday at least a week away, 10:00 in Madrid.
    private func nextTuesday(hour: Int, zone: TimeZone) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        var day = local.startOfDay(for: Date().addingTimeInterval(7 * 86_400))
        while local.component(.weekday, from: day) != 3 { day = local.date(byAdding: .day, value: 1, to: day)! }
        return local.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    // MARK: Events

    private func events() {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let start = nextTuesday(hour: 10, zone: madrid)
        let place: [String: Any] = ["title": "Synthetic Place", "latitude": 40.4168, "longitude": -3.7038,
                                    "radius": 150]
        let calendarID = calendar.calendarIdentifier
        var create: [String: Any] = [
            "calendarID": calendarID, "title": "EventKit Bridge Synthetic Weekly",
            "start": seconds(start), "end": seconds(start) + 3_600, "timeZone": "Europe/Madrid",
            "notes": "Synthetic notes\nSecond line", "location": "Synthetic Place",
            "structuredLocation": place, "url": "https://example.com/synthetic?x=1",
            "alarms": [["kind": "relative", "offset": -900], ["kind": "absolute", "at": seconds(start) - 3_600],
                       ["kind": "location", "location": place, "proximity": "arrive"]],
            "recurrence": ["kind": "rule", "frequency": "weekly", "weekdays": ["TU"],
                           "end": ["kind": "count", "count": 5]],
        ]
        if (observations["availabilities"] as? [String])?.contains("free") == true { create["availability"] = "free" }
        let created = call(.createEvent, create)
        let id = item(created)["id"] as? String ?? ""
        guard step("event: create recurring with every field in Europe/Madrid", !id.isEmpty,
                   ["error": error(created), "verified": item(created)["verified"] ?? []]) else { return }
        // S1: does the account keep the zone?
        let full = item(call(.getEvent, ["calendarID": calendarID, "itemID": id]))
        observations["S1_saved_time_zone_for_Europe/Madrid"] = full["timeZone"] ?? "missing"
        observations["Q3_structured_location_kept"] = !(full["structuredLocation"] is NSNull)
        observations["S5_event_location_alarm_stored"] = (full["alarms"] as? [[String: Any]] ?? [])
            .contains { $0["kind"] as? String == "location" }
        step("event: get_event reads every field back",
             full["notes"] as? String == "Synthetic notes\nSecond line" && full["url"] as? String ==
                "https://example.com/synthetic?x=1" && (full["alarms"] as? [Any])?.count == 3,
             ["timeZone": full["timeZone"] ?? "", "alarmKinds": (full["alarms"] as? [[String: Any]] ?? [])
                .map { $0["kind"] ?? "" }, "recurrence": (full["recurrence"] as? [String: Any])?["rrule"] ?? ""])

        // Occurrences.
        func occurrences() -> [[String: Any]] {
            let rows = call(.readEvents, ["calendarID": calendarID, "start": seconds(start) - 86_400,
                                          "end": seconds(start) + 30 * 86_400, "limit": 100])
            return (rows["items"] as? [[String: Any]] ?? []).filter { ($0["title"] as? String)?.contains("Weekly") == true }
        }
        let first = occurrences()
        step("event: five occurrences with occurrence starts", first.count == 5 &&
             first.allSatisfy { !($0["occurrenceStart"] is NSNull) }, ["count": first.count])
        guard first.count == 5 else { return }
        func occurrence(_ index: Int, _ rows: [[String: Any]]) -> Int {
            Int((rows[index]["occurrenceStart"] as? Double) ?? 0)
        }
        func version(_ id: String, _ occurrenceStart: Int?) -> String {
            var p: [String: Any] = ["calendarID": calendarID, "itemID": id]
            if let occurrenceStart { p["occurrenceStart"] = occurrenceStart }
            return item(call(.getEvent, p))["version"] as? String ?? ""
        }
        let second = occurrence(1, first)
        let this = call(.updateEvent, ["calendarID": calendarID, "itemID": id, "occurrenceStart": second,
                                       "expectedVersion": version(id, second), "notes": "Only this occurrence"])
        let detached = item(call(.getEvent, ["calendarID": calendarID, "itemID": id, "occurrenceStart": second]))
        step("event: span this changes one occurrence", error(this) == "none" &&
             detached["detached"] as? Bool == true && detached["notes"] as? String == "Only this occurrence" &&
             detached["id"] as? String == id,
             ["error": error(this), "detached": detached["detached"] ?? "missing", "sameID": detached["id"] as? String == id])
        let third = occurrence(2, first)
        let future = call(.updateEvent, ["calendarID": calendarID, "itemID": id, "occurrenceStart": third,
                                         "expectedVersion": version(id, third), "span": "future",
                                         "start": third + 3_600, "end": third + 7_200])
        let futureID = item(future)["id"] as? String ?? ""
        observations["S2_future_split_keeps_identifier"] = futureID == id
        step("event: span future moves this and later occurrences", error(future) == "none",
             ["error": error(future), "newID": futureID == id ? "same" : "new"])
        let afterSplit = occurrences()
        step("event: occurrences after the split", afterSplit.count == 5,
             ["count": afterSplit.count, "detached": afterSplit.filter { $0["detached"] as? Bool == true }.count])
        let deleted = call(.deleteEvent, ["calendarID": calendarID, "itemID": id, "occurrenceStart": second,
                                          "expectedVersion": version(id, second)])
        step("event: delete one occurrence", error(deleted) == "none" && occurrences().count == 4,
             ["error": error(deleted)])
        // The new series: an occurrence moved two days is still found by its
        // original start, and a series can't move off its rule's weekday.
        let newSeries = occurrences().filter { $0["id"] as? String == futureID }
        if newSeries.count >= 2 {
            let occ = occurrence(1, newSeries)
            let movedTwoDays = call(.updateEvent, ["calendarID": calendarID, "itemID": futureID, "occurrenceStart": occ,
                                                   "expectedVersion": version(futureID, occ),
                                                   "start": occ + 2 * 86_400, "end": occ + 2 * 86_400 + 3_600])
            let found = item(call(.getEvent, ["calendarID": calendarID, "itemID": futureID, "occurrenceStart": occ]))
            step("event: an occurrence moved two days is found by its original start",
                 error(movedTwoDays) == "none" && (found["start"] as? Double).map(Int.init) == occ + 2 * 86_400,
                 ["error": error(movedTwoDays)])
            let head = occurrence(0, newSeries)
            let offRule = call(.updateEvent, ["calendarID": calendarID, "itemID": futureID, "occurrenceStart": head,
                                              "expectedVersion": version(futureID, head), "span": "future",
                                              "start": head + 86_400, "end": head + 86_400 + 3_600])
            step("event: a series can't move off its weekday", error(offRule) == "recurrence_anchor_mismatch",
                 ["error": error(offRule)])
        } else {
            step("event: the new series has occurrences", false, ["count": newSeries.count])
        }
        let firstStart = occurrence(0, first)
        let all = call(.updateEvent, ["calendarID": calendarID, "itemID": id, "occurrenceStart": firstStart,
                                      "expectedVersion": version(id, firstStart), "span": "all",
                                      "title": "EventKit Bridge Synthetic Weekly (renamed)"])
        step("event: span all renames the series", error(all) == "none", ["error": error(all)])
        let noOccurrence = call(.updateEvent, ["calendarID": calendarID, "itemID": id,
                                               "expectedVersion": version(id, nil), "title": "x"])
        step("event: a recurring event needs occurrenceStart", error(noOccurrence) == "occurrence_required")

        // A timed event in Kolkata: alias handling, partial updates, zone move, nulls.
        let kolkataStart = seconds(start) + 2 * 86_400
        let timed = call(.createEvent, ["calendarID": calendarID, "title": "EventKit Bridge Synthetic Timed",
                                        "start": kolkataStart, "end": kolkataStart + 1_800,
                                        "timeZone": "Asia/Calcutta", "notes": "n", "location": "l",
                                        "url": "mailto:synthetic@example.com",
                                        "alarms": [["kind": "relative", "offset": -300]]])
        let timedID = item(timed)["id"] as? String ?? ""
        observations["S1_saved_time_zone_for_Asia/Calcutta"] = item(timed)["timeZone"] ?? "missing"
        step("event: create in Asia/Calcutta", !timedID.isEmpty, ["error": error(timed)])
        let titled = call(.updateEvent, ["calendarID": calendarID, "itemID": timedID,
                                         "expectedVersion": version(timedID, nil), "title": "EventKit Bridge Synthetic Timed 2"])
        step("event: a title-only update", (item(titled)["verified"] as? [String]) == ["title"],
             ["error": error(titled)])
        let rezoned = call(.updateEvent, ["calendarID": calendarID, "itemID": timedID,
                                          "expectedVersion": version(timedID, nil), "timeZone": "UTC"])
        step("event: move to UTC keeping the instants", error(rezoned) == "none" &&
             (item(rezoned)["start"] as? Double).map(Int.init) == kolkataStart, ["error": error(rezoned)])
        let cleared = call(.updateEvent, ["calendarID": calendarID, "itemID": timedID,
                                          "expectedVersion": version(timedID, nil), "notes": NSNull(),
                                          "location": NSNull(), "url": NSNull(), "alarms": NSNull()])
        let afterClear = item(call(.getEvent, ["calendarID": calendarID, "itemID": timedID]))
        step("event: null clears notes, location, URL and alarms", error(cleared) == "none" &&
             afterClear["notes"] is NSNull && afterClear["url"] is NSNull &&
             (afterClear["alarms"] as? [Any])?.isEmpty == true, ["error": error(cleared)])

        // All-day: create in Madrid, convert to timed and back.
        var madridDay = Calendar(identifier: .gregorian)
        madridDay.timeZone = madrid
        let dayStart = madridDay.startOfDay(for: start.addingTimeInterval(3 * 86_400))
        let dayEnd = madridDay.date(byAdding: .day, value: 3, to: dayStart)!
        let allDay = call(.createEvent, ["calendarID": calendarID, "title": "EventKit Bridge Synthetic All Day",
                                         "start": seconds(dayStart), "end": seconds(dayEnd), "allDay": true,
                                         "timeZone": "Europe/Madrid"])
        let allDayID = item(allDay)["id"] as? String ?? ""
        observations["S1_all_day_time_zone_for_Europe/Madrid"] = item(allDay)["timeZone"] ?? "missing"
        step("event: a three-day all-day event", !allDayID.isEmpty, ["error": error(allDay)])
        let toTimed = call(.updateEvent, ["calendarID": calendarID, "itemID": allDayID,
                                          "expectedVersion": version(allDayID, nil), "allDay": false,
                                          "start": seconds(dayStart) + 36_000, "end": seconds(dayStart) + 39_600,
                                          "timeZone": "Europe/Madrid"])
        step("event: all-day → timed", error(toTimed) == "none" && item(toTimed)["allDay"] as? Bool == false,
             ["error": error(toTimed)])
        let toAllDay = call(.updateEvent, ["calendarID": calendarID, "itemID": allDayID,
                                           "expectedVersion": version(allDayID, nil), "allDay": true,
                                           "start": seconds(dayStart), "end": seconds(dayEnd),
                                           "timeZone": "Europe/Madrid"])
        step("event: timed → all-day", error(toAllDay) == "none" && item(toAllDay)["allDay"] as? Bool == true,
             ["error": error(toAllDay)])
        let long = call(.createEvent, ["calendarID": calendarID, "title": "EventKit Bridge Synthetic 31 Days",
                                       "start": seconds(start), "end": seconds(start) + 31 * 86_400])
        step("event: a 31-day timed event", error(long) == "none", ["error": error(long)])

        // A move within the account (S2: does the ID survive?).
        let moved = call(.updateEvent, ["calendarID": calendarID, "itemID": timedID,
                                        "expectedVersion": version(timedID, nil),
                                        "targetCalendarID": calendar2.calendarIdentifier],
                         move: calendar2.calendarIdentifier)
        observations["S2_move_keeps_identifier"] = (item(moved)["id"] as? String) == timedID
        step("event: move to another calendar in the account", error(moved) == "none" &&
             item(moved)["calendarID"] as? String == calendar2.calendarIdentifier, ["error": error(moved)])

        // Shapes the bridge leaves alone: floating times, alarms it can't express.
        let floating = EKEvent(eventStore: store)
        floating.calendar = calendar
        floating.title = "EventKit Bridge Synthetic Floating"
        floating.startDate = start.addingTimeInterval(5 * 86_400)
        floating.endDate = floating.startDate.addingTimeInterval(3_600)
        floating.timeZone = nil
        let sound = EKAlarm(relativeOffset: -600)
        sound.soundName = "Basso"
        floating.alarms = [sound]
        do { try store.save(floating, span: .thisEvent, commit: true) } catch {}
        if let floatingID = floating.eventIdentifier {
            let times = call(.updateEvent, ["calendarID": calendarID, "itemID": floatingID,
                                            "expectedVersion": version(floatingID, nil),
                                            "start": seconds(floating.startDate) + 600])
            step("event: floating times are read only", error(times) == "floating_time_read_only")
            let notes = call(.updateEvent, ["calendarID": calendarID, "itemID": floatingID,
                                            "expectedVersion": version(floatingID, nil), "notes": "fine"])
            step("event: a floating event's notes can change", error(notes) == "none", ["error": error(notes)])
            // Some accounts drop the sound; only a kept sound blocks replacing it.
            let kept = (item(call(.getEvent, ["calendarID": calendarID, "itemID": floatingID]))["alarms"]
                        as? [[String: Any]] ?? []).contains { $0["kind"] as? String == "unsupported" }
            observations["alarm_sound_kept"] = kept
            let alarms = call(.updateEvent, ["calendarID": calendarID, "itemID": floatingID,
                                             "expectedVersion": version(floatingID, nil),
                                             "alarms": [["kind": "relative", "offset": -60]]])
            step("event: alarms the bridge can't express aren't replaced silently",
                 kept ? error(alarms) == "alarms_unsupported" : error(alarms) == "none", ["error": error(alarms)])
        }
        let deleteSeries = call(.deleteEvent, ["calendarID": calendarID, "itemID": id, "occurrenceStart": firstStart,
                                               "expectedVersion": version(id, firstStart), "span": "all"])
        step("event: delete the whole series", error(deleteSeries) == "none", ["error": error(deleteSeries)])
    }

    // MARK: Reminders

    private func reminders() {
        let listID = list.calendarIdentifier
        let zone = TimeZone.current
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let dueDate = local.date(bySettingHour: 9, minute: 0, second: 0,
                                 of: Date().addingTimeInterval(10 * 86_400))!
        let due: [String: Any] = ["kind": "timed", "at": seconds(dueDate), "timeZone": zone.identifier]
        let place: [String: Any] = ["title": "Synthetic Home", "latitude": 40.7, "longitude": -74.0, "radius": 200]
        let created = call(.createReminder, [
            "listID": listID, "title": "EventKit Bridge Synthetic Reminder", "due": due,
            "start": ["kind": "all_day", "date": dayString(dueDate.addingTimeInterval(-86_400), local),
                      "timeZone": zone.identifier],
            "notes": "Synthetic reminder notes", "url": "https://example.com/reminder",
            "priority": "high",
            "alarms": [["kind": "relative", "offset": -3_600], ["kind": "absolute", "at": seconds(dueDate) - 7_200],
                       ["kind": "location", "location": place, "proximity": "leave"]]])
        let id = item(created)["id"] as? String ?? ""
        guard step("reminder: create with every field", !id.isEmpty,
                   ["error": error(created), "verified": item(created)["verified"] ?? []]) else { return }
        let full = item(call(.getReminder, ["listID": listID, "itemID": id]))
        observations["S4_reminder_url_stored"] = full["url"] as? String == "https://example.com/reminder"
        observations["S4_reminder_location_text"] = "not writable: EKReminder ignores location"
        observations["S4_reminder_priority_raw"] = full["priorityRaw"] ?? "missing"
        observations["S5_reminder_location_alarm_stored"] = (full["alarms"] as? [[String: Any]] ?? [])
            .contains { $0["kind"] as? String == "location" }
        observations["Q5_relative_alarm_kept_relative"] = (full["alarms"] as? [[String: Any]] ?? [])
            .contains { $0["kind"] as? String == "relative" }
        step("reminder: get_reminder reads every field back", full["notes"] as? String == "Synthetic reminder notes")
        func version() -> String { item(call(.getReminder, ["listID": listID, "itemID": id]))["version"] as? String ?? "" }
        let notes = call(.updateReminder, ["listID": listID, "itemID": id, "expectedVersion": version(),
                                           "notes": "Changed notes"])
        step("reminder: a notes-only update", (item(notes)["verified"] as? [String]) == ["notes"],
             ["error": error(notes)])
        let later: [String: Any] = ["kind": "timed", "at": seconds(dueDate) + 86_400, "timeZone": zone.identifier]
        let moved = call(.updateReminder, ["listID": listID, "itemID": id, "expectedVersion": version(), "due": later])
        step("reminder: moving the due date keeps the alarms", error(moved) == "none" &&
             (item(moved)["alarms"] as? [Any])?.count == 3, ["error": error(moved)])
        let done = call(.updateReminder, ["listID": listID, "itemID": id, "expectedVersion": version(),
                                          "completed": true])
        let reopened = call(.updateReminder, ["listID": listID, "itemID": id, "expectedVersion": version(),
                                              "completed": false])
        step("reminder: complete and reopen", error(done) == "none" && error(reopened) == "none" &&
             item(reopened)["completed"] as? Bool == false, ["error": error(reopened)])
        let incomplete = call(.readReminders, ["listID": listID, "limit": 100, "status": "incomplete",
                                               "dueAfter": seconds(dueDate), "dueBefore": seconds(dueDate) + 2 * 86_400])
        step("reminder: filters by status and due range", (incomplete["items"] as? [Any])?.count == 1)
        let movedList = call(.updateReminder, ["listID": listID, "itemID": id, "expectedVersion": version(),
                                               "targetListID": list2.calendarIdentifier],
                             move: list2.calendarIdentifier)
        observations["S2_reminder_move_keeps_identifier"] = (item(movedList)["id"] as? String) == id
        step("reminder: move to another list", error(movedList) == "none", ["error": error(movedList)])

        // A repeating reminder: series delete needs scope.
        var monday = local.startOfDay(for: Date().addingTimeInterval(14 * 86_400))
        while local.component(.weekday, from: monday) != 2 || local.component(.day, from: monday) > 7 {
            monday = local.date(byAdding: .day, value: 1, to: monday)!
        }
        let repeating = call(.createReminder, [
            "listID": listID, "title": "EventKit Bridge Synthetic Monthly",
            "due": ["kind": "all_day", "date": dayString(monday, local), "timeZone": zone.identifier],
            "recurrence": ["kind": "rule", "frequency": "monthly", "weekdays": ["1MO"]]])
        let repeatingID = item(repeating)["id"] as? String ?? ""
        step("reminder: monthly on the first Monday", !repeatingID.isEmpty, ["error": error(repeating)])
        let repeatingVersion = item(call(.getReminder, ["listID": listID, "itemID": repeatingID]))["version"] as? String ?? ""
        let refused = call(.deleteReminder, ["listID": listID, "itemID": repeatingID, "expectedVersion": repeatingVersion])
        let series = call(.deleteReminder, ["listID": listID, "itemID": repeatingID, "expectedVersion": repeatingVersion,
                                            "recurrenceScope": "series"])
        step("reminder: series delete needs scope", error(refused) == "recurrence_scope_required" &&
             error(series) == "none", ["error": error(series)])

        // S6 on this Mac: the verified shape through the bridge, when this account is allowlisted.
        let daily = call(.createReminder, [
            "listID": listID, "title": "EventKit Bridge Synthetic Daily",
            "due": ["kind": "timed", "at": seconds(dueDate), "timeZone": zone.identifier, "alarmAt": NSNull()],
            "recurrence": ["kind": "rule", "frequency": "daily"]])
        let dailyID = item(daily)["id"] as? String ?? ""
        let row = item(call(.getReminder, ["listID": listID, "itemID": dailyID]))
        if let candidate = row["completionCandidate"] as? [String: Any] {
            let completed = call(.completeReminder, [
                "listID": listID, "itemID": dailyID, "expectedVersion": row["version"] as? String ?? "",
                "recurrenceScope": "occurrence", "occurrenceDue": candidate["occurrenceDue"] ?? 0,
                "occurrenceFingerprint": candidate["occurrenceFingerprint"] ?? ""])
            observations["S6_daily_completion_verified"] = completed["completedOccurrence"] != nil
            step("reminder: complete one daily occurrence", completed["completedOccurrence"] != nil,
                 ["error": error(completed)])
        } else {
            observations["S6_daily_completion_verified"] = "not allowlisted for this account type"
        }
    }

    private func dayString(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func report(_ fields: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
#endif

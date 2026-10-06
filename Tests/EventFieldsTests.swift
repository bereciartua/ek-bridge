import EventKit
import Foundation

// Event writes as values (plan 03 §5, §6, §9–§11, §14): text rules, places,
// alarms, the resolver that merges a partial update with the current event,
// and the readback verifier with good and bad readbacks. No event store.
@main
struct EventFieldsTests {
    nonisolated(unsafe) static var checks = 0
    static let ny = TimeZone(identifier: "America/New_York")!
    static let now = Date(timeIntervalSince1970: 1_791_216_000)  // 2026-10-05T12:00:00-04:00

    static func main() {
        text()
        places()
        alarms()
        parsing()
        timesAndZones()
        fields()
        verifier()
        paging()
        print("Event fields: \(checks) checks of text, URL, place, alarm, parse, resolve (zones, all-day, "
              + "floating, conversions, recurrence anchors) and readback verification passed")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        checks += 1
        if !condition {
            print("FAIL line \(line): \(message())")
            exit(1)
        }
    }

    // MARK: Text (§9)

    static func text() {
        check(ItemText.normalized("e\u{301}") == "é", "NFC")
        check(ItemText.normalized("a\r\nb\tc") == "a\nb\tc", "CR LF becomes LF, tab kept")
        check(ItemText.normalized("a\rb") == nil, "lone CR refused")
        check(ItemText.normalized("a\u{0}") == nil && ItemText.normalized("\u{1b}[0m") == nil, "controls refused")
        func notes(_ raw: Any?, creating: Bool = false) -> Result<ItemText.Change<String>, FieldError> {
            ItemText.notes(raw, present: raw != nil, creating: creating)
        }
        check(notes(nil) == .success(.keep), "absent keeps")
        check(notes(NSNull()) == .success(.clear), "null clears")
        check(notes("   ") == .success(.clear), "blank clears on update")
        check(notes("   ", creating: true) == .failure(FieldError("invalid_notes")), "blank refused on create")
        check(notes("  keep spaces  ") == .success(.set("  keep spaces  ")), "notes keep whitespace")
        check(notes(String(repeating: "€", count: 2_666) + "ab") == .success(.set(String(repeating: "€", count: 2_666) + "ab")),
              "8,000 bytes")
        check(notes(String(repeating: "€", count: 2_667)) == .failure(FieldError("notes_too_long")), "8,001 bytes")
        check(notes(5) == .failure(FieldError("invalid_notes")), "not a string")
        let location = { (raw: Any) in ItemText.location(raw, present: true, creating: false) }
        check(location("  Room 4  ") == .success(.set("Room 4")), "location trimmed")
        check(location("Room\n4") == .failure(FieldError("invalid_location")), "one line")
        check(location(String(repeating: "x", count: 501)) == .failure(FieldError("location_too_long")), "501 bytes")
        let urls: [(String, String?)] = [
            ("https://example.com", nil), ("http://example.com/a?b=c", nil), ("HTTPS://EXAMPLE.COM", nil),
            ("mailto:ana@example.com", nil), ("tel:+1-555-0100", nil), ("https://example.com/%20space", nil),
            ("ftp://example.com", "url_scheme_not_allowed"), ("javascript:alert(1)", "url_scheme_not_allowed"),
            ("data:text/html,hi", "url_scheme_not_allowed"), ("x-apple-reminder://1", "url_scheme_not_allowed"),
            ("https:///path", "invalid_url"), ("mailto:", "invalid_url"), ("example.com", "invalid_url"),
            ("https://exa mple.com", "invalid_url"), (" https://example.com", "invalid_url"),
            ("https://example.com/\u{7}", "invalid_url"),
        ]
        for (url, problem) in urls { check(ItemText.urlProblem(url) == problem, "\(url): \(ItemText.urlProblem(url) ?? "ok")") }
        check(ItemText.schemeAllowed("https://x.test") && !ItemText.schemeAllowed("file:///x"), "scheme flag")
        let (preview, cut) = ItemText.prefix(String(repeating: "é", count: 200), maxBytes: 301)
        check(preview.utf8.count == 300 && cut, "preview cuts at a character boundary")
        check(ItemText.prefix("short", maxBytes: 300) == ("short", false), "short notes not cut")
    }

    static func places() {
        let place = PlaceSpec.parse(["title": " Office ", "latitude": 40.75, "longitude": -73.99, "radius": 150])
        check(place == PlaceSpec(title: "Office", latitude: 40.75, longitude: -73.99, radius: 150), "place")
        check(PlaceSpec.parse(["title": "x", "latitude": 90, "longitude": 180]) != nil, "edges")
        for bad in [["title": "x", "latitude": 91, "longitude": 0], ["title": "x", "latitude": 0, "longitude": -181],
                    ["title": "", "latitude": 0, "longitude": 0], ["title": "x", "latitude": 0],
                    ["title": "x", "latitude": 0, "longitude": 0, "radius": 0.5],
                    ["title": "x", "latitude": true, "longitude": 0]] as [[String: Any]] {
            check(PlaceSpec.parse(bad) == nil, "bad place \(bad)")
        }
        let saved = PlaceSpec(title: "Office", latitude: 40.7500004, longitude: -73.9899996, radius: 150.4)
        check(place!.matches(saved), "within 1e-6° and 1 m")
        check(!place!.matches(PlaceSpec(title: "Office", latitude: 40.751, longitude: -73.99, radius: 150)), "moved")
        check(PlaceSpec(title: "Office", latitude: 1, longitude: 2, radius: nil)
              .matches(PlaceSpec(title: "Office", latitude: 1, longitude: 2, radius: 70)), "default radius")
        let location = place!.makeLocation()
        check(PlaceSpec.read(location) == place, "EKStructuredLocation round trip")
        check(PlaceSpec.read(EKStructuredLocation(title: "No pin")) == nil, "no coordinates")
    }

    static func alarms() {
        let place = PlaceSpec(title: "Home", latitude: 1, longitude: 2, radius: 100)
        let specs: [AlarmSpec] = [.relative(-900), .relative(86_400), .absolute(1_800_000_000),
                                  .location(place, .arrive), .location(place, .leave)]
        for spec in specs {
            check(AlarmSpec.parse(spec.core) == spec, "core round trip \(spec)")
            check(AlarmSpec.read(spec.makeAlarm()).map { AlarmSpec.sameSet([spec], [$0]) } == true,
                  "EKAlarm round trip \(spec)")
        }
        check(AlarmSpec.parse(["kind": "relative", "offset": 86_401]) == nil, "more than a day after")
        check(AlarmSpec.parse(["kind": "relative", "offset": -40_320 * 60 - 1]) == nil, "more than 4 weeks before")
        check(AlarmSpec.parse(["kind": "relative", "offset": -900.5]) == nil, "fractional")
        check(AlarmSpec.parse(["kind": "location", "location": place.core]) == nil, "proximity required")
        check(AlarmSpec.parseList(["alarms": NSNull()], creating: false) == .clear, "null clears")
        check(AlarmSpec.parseList(["alarms": NSNull()], creating: true) == nil, "null refused on create")
        check(AlarmSpec.parseList([:], creating: false) == .keep, "absent keeps")
        check(AlarmSpec.parseList(["alarms": []], creating: true) == .set([]), "empty list")
        check(AlarmSpec.parseList(["alarms": [specs[0].core, specs[0].core]], creating: true) == nil, "duplicate")
        let sound = EKAlarm(relativeOffset: -600)
        sound.soundName = "Basso"
        check(AlarmSpec.read(sound) == nil, "a sound is unsupported")
        let (rows, truncated) = AlarmSpec.readback([sound, specs[0].makeAlarm()])
        check(rows.count == 2 && rows[0]["kind"] as? String == "unsupported" &&
              rows[0]["summary"] as? String == "alarm with a sound" && !truncated, "unsupported row")
        check(AlarmSpec.readback(Array(repeating: specs[0].makeAlarm(), count: 21)).truncated, "20 rows at most")
        check(AlarmSpec.sameSet([.relative(-900), .absolute(5)], [.absolute(5), .relative(-900)]), "any order")
        check(!AlarmSpec.sameSet([.relative(-900)], [.relative(-900), .relative(-60)]), "extra alarm")
        check(!AlarmSpec.sameSet([.relative(-900)], [nil]), "unsupported doesn't match")
    }

    // MARK: Parse and resolve (§5, §6, §11)

    static func parse(_ p: [String: Any], creating: Bool = false) -> Result<EventChange, FieldError> {
        EventChange.parse(p, creating: creating)
    }

    static func parsing() {
        check(parse([:]) == .failure(FieldError("nothing_to_change")), "nothing to change")
        check(parse(["occurrenceStart": 1, "span": "all"]) == .failure(FieldError("nothing_to_change")),
              "span alone changes nothing")
        guard case .success(let change) = parse(["title": "x", "notes": NSNull(), "alarms": NSNull(),
                                                  "availability": NSNull(), "url": NSNull()]) else {
            check(false, "nulls"); return
        }
        check(change.notes == .clear && change.alarms == .clear && change.availability == .clear &&
              change.url == .clear && change.location == .keep, "null clears, absent keeps")
        check(parse(["location": NSNull(), "structuredLocation": ["title": "x", "latitude": 1, "longitude": 2]])
              == .failure(FieldError("invalid_location")), "clear location while setting a pin")
        check(parse(["title": "x"], creating: true) == .failure(FieldError("invalid_parameters_or_target")),
              "create needs times")
        check(parse(["title": "x", "start": 10, "end": 20, "allDay": true], creating: true)
              == .failure(FieldError("invalid_parameters_or_target")), "all-day create needs a zone")
        check(EventChange.occurrenceTarget(["occurrenceStart": 5, "span": "future"])?.span == .future, "delete target")
        check(EventChange.occurrenceTarget(["span": "sometimes"]) == nil, "bad span")
    }

    static func current(_ changes: (inout EventFields) -> Void = { _ in }) -> EventFields {
        var fields = EventFields(calendarID: "CAL", title: "Design review", start: 1_791_295_200,
                                 end: 1_791_298_800, allDay: false, timeZone: "America/New_York",
                                 notes: "Agenda", location: "Room 4", place: nil, url: nil, alarms: [.relative(-900)],
                                 availability: .busy, recurrence: .none)
        changes(&fields)
        return fields
    }

    static func resolve(_ p: [String: Any], current: EventFields? = current(),
                        supported: Set<EventAvailability>? = [.busy, .free]) -> Result<(target: EventFields, touched: Set<EventField>), FieldError> {
        parse(p, creating: current == nil).flatMap {
            EventFields.resolve($0, current: current, calendarID: "CAL", supportedAvailability: supported,
                                macZone: ny, now: now)
        }
    }

    static func target(_ p: [String: Any], current: EventFields? = current(),
                       line: Int = #line) -> (target: EventFields, touched: Set<EventField>) {
        switch resolve(p, current: current) {
        case .success(let value): return value
        case .failure(let error):
            print("FAIL line \(line): \(error.code)")
            exit(1)
        }
    }

    static func timesAndZones() {
        // Create: the requested zone, or the Mac's — never UTC by default (F1).
        let created = target(["title": "T", "start": 1_791_295_200, "end": 1_791_298_800], current: nil)
        check(created.target.timeZone == "America/New_York" && !created.target.allDay, "Mac zone by default")
        check(created.touched.isSuperset(of: [.title, .start, .end, .timeZone, .calendar]), "create touches")
        let madrid = target(["title": "T", "start": 1_791_295_200, "end": 1_791_298_800,
                             "timeZone": "Europe/Madrid"], current: nil)
        check(madrid.target.timeZone == "Europe/Madrid", "requested zone")
        // Update: a title alone leaves the times alone.
        let titled = target(["title": "Renamed"])
        check(titled.touched == [.title] && titled.target.start == current().start, "partial update")
        // Only start: keeps end.
        let earlier = target(["start": 1_791_291_600])
        check(earlier.target.start == 1_791_291_600 && earlier.target.end == current().end, "start only")
        check(resolve(["start": 1_791_300_000]) == .failure(FieldError("invalid_event_schedule")),
              "start after the kept end")
        // Moving zones keeps the instants.
        let moved = target(["timeZone": "Europe/Madrid"])
        check(moved.target.timeZone == "Europe/Madrid" && moved.target.start == current().start, "zone move")
        // Timed spans: 31 days.
        check(resolve(["end": 1_791_295_200 + 31 * 86_400]) != .failure(FieldError("invalid_event_schedule")),
              "31 days")
        check(resolve(["end": 1_791_295_201 + 31 * 86_400]) == .failure(FieldError("invalid_event_schedule")),
              "31 days and a second")
        // All-day: midnights in the zone, 1–366 days; conversions need both times.
        let oct6 = 1_791_259_200, oct8 = 1_791_432_000
        let toAllDay = target(["allDay": true, "start": oct6, "end": oct8, "timeZone": "America/New_York"])
        // EventKit keeps all-day events floating, with the dates as midnights in the Mac's zone.
        check(toAllDay.target.allDay && toAllDay.target.timeZone == nil && toAllDay.target.start == Double(oct6),
              "timed → all-day")
        check(resolve(["allDay": true, "start": oct6 + 3_600, "end": oct8, "timeZone": "America/New_York"])
              == .failure(FieldError("invalid_event_schedule")), "not a midnight")
        check(resolve(["allDay": true]) == .failure(FieldError("invalid_event_schedule")), "conversion needs times")
        let allDay = current { $0.allDay = true; $0.timeZone = nil; $0.start = Double(oct6); $0.end = Double(oct8) }
        let floatingAllDay = target(["start": oct6, "end": oct8 + 86_400, "timeZone": "America/New_York",
                                     "allDay": true], current: allDay)
        check(floatingAllDay.target.timeZone == nil, "a floating all-day event stays floating in the Mac's zone")
        // Madrid dates are saved as the same dates in the Mac's zone (New York here).
        let zonedAllDay = target(["start": oct6 - 21_600, "end": oct8 - 21_600, "timeZone": "Europe/Madrid",
                                  "allDay": true], current: allDay)
        check(zonedAllDay.target.timeZone == nil && zonedAllDay.target.start == Double(oct6) &&
              zonedAllDay.target.end == Double(oct8), "Madrid dates kept as dates")
        let kolkata = target(["start": 1_791_225_000, "end": 1_791_397_800, "timeZone": "Asia/Calcutta",
                              "allDay": true], current: allDay)
        check(kolkata.target.start == Double(oct6) && kolkata.target.end == Double(oct8),
              "Kolkata Oct 6–7 is Oct 6–7, not a day early")
        // A saved all-day event ends at 23:59:59 on its last day; a new first day keeps that last day.
        let stored = current { $0.allDay = true; $0.timeZone = nil; $0.start = Double(oct6); $0.end = Double(oct8) - 1 }
        let newFirst = target(["allDay": true, "start": oct6 - 86_400, "timeZone": "America/New_York"], current: stored)
        check(newFirst.target.start == Double(oct6 - 86_400) && newFirst.target.end == Double(oct8),
              "inclusive end kept")
        let toTimed = target(["allDay": false, "start": 1_791_295_200, "end": 1_791_298_800], current: allDay)
        check(!toTimed.target.allDay && toTimed.target.timeZone == "America/New_York", "all-day → timed")
        check(EventFields.allDayLength(start: Double(oct6), end: Double(oct6) + 366 * 86_400 + 3_600, zone: ny) == nil,
              "DST-shifted end isn't a midnight")
        // Floating timed events: everything but their times (F2).
        let floating = current { $0.timeZone = nil }
        check(resolve(["start": 1_791_291_600], current: floating) == .failure(FieldError("floating_time_read_only")),
              "floating times")
        check(resolve(["timeZone": "UTC"], current: floating) == .failure(FieldError("floating_time_read_only")),
              "floating zone")
        check(target(["notes": "ok"], current: floating).touched == [.notes], "floating notes")
    }

    static func fields() {
        // Notes, location and pins.
        check(target(["notes": NSNull()]).target.notes == nil, "notes cleared")
        let pinned = target(["structuredLocation": ["title": "HQ", "latitude": 1, "longitude": 2]])
        check(pinned.target.location == "HQ" && pinned.target.place?.title == "HQ" &&
              pinned.touched.isSuperset(of: [.location, .structuredLocation]), "a pin sets the location text")
        // EventKit keeps one value: the text is the pin's title.
        check(resolve(["location": "Lobby", "structuredLocation": ["title": "HQ", "latitude": 1, "longitude": 2]])
              == .failure(FieldError("invalid_location")), "text that differs from the pin")
        check(target(["location": "HQ", "structuredLocation": ["title": "HQ", "latitude": 1, "longitude": 2]])
              .target.location == "HQ", "text equal to the pin")
        let withPin = current { $0.place = PlaceSpec(title: "HQ", latitude: 1, longitude: 2, radius: nil) }
        check(target(["location": "Elsewhere"], current: withPin).target.place == nil, "new text drops the old pin")
        check(target(["location": NSNull()], current: withPin).target.place == nil, "clearing location clears the pin")
        // Alarms.
        check(target(["alarms": NSNull()]).target.alarms.isEmpty, "alarms cleared")
        check(resolve(["alarms": [["kind": "absolute", "at": Int(now.timeIntervalSince1970)]]])
              == .failure(FieldError("alarm_in_past")), "alarm in the past")
        // Availability (§11.1).
        check(target(["availability": "free"]).target.availability == .free, "free")
        check(resolve(["availability": "tentative"]) == .failure(FieldError("availability_unsupported")),
              "tentative not supported")
        check(resolve(["availability": "busy"], supported: nil) == .failure(FieldError("availability_unsupported")),
              "no availability at all")
        check(target(["availability": NSNull()]).target.availability == .busy, "null is busy")
        if case .success(let plan) = resolve(["availability": NSNull(), "title": "x"],
                                             current: current { $0.availability = nil }, supported: nil) {
            check(plan.touched == [.title], "null on a calendar without availability")
        } else { check(false, "null on a calendar without availability") }
        // Recurrence: the start must match the rule (§7.3).
        let tuesdays = ["kind": "rule", "frequency": "weekly", "weekdays": ["TU"]] as [String: Any]
        check(target(["recurrence": tuesdays]).target.recurrence.spec?.weekdays.first?.day == 3,
              "Tuesday rule on a Tuesday event")  // 2026-10-06 is a Tuesday.
        check(resolve(["recurrence": ["kind": "rule", "frequency": "weekly", "weekdays": ["WE"]]])
              == .failure(FieldError("recurrence_anchor_mismatch")), "Wednesday rule on a Tuesday")
        check(resolve(["recurrence": tuesdays, "start": 1_791_381_600, "end": 1_791_385_200])
              == .failure(FieldError("recurrence_anchor_mismatch")), "moved to Wednesday")
        check(target(["recurrence": ["kind": "none"]]).touched == [.recurrence], "clear")
        // Moving a series start off its rule's days (span future/all) is refused even without a new rule.
        let tuesdaySeries = current { $0.recurrence = .rule(RecurrenceSpec(frequency: .weekly, weekdays: [.init(day: 3)])) }
        let wednesday = parse(["start": 1_791_381_600, "end": 1_791_385_200], creating: false).flatMap {
            EventFields.resolve($0, current: tuesdaySeries, calendarID: "CAL", supportedAvailability: nil, macZone: ny,
                                now: now, seriesMoves: true)
        }
        check(wednesday == .failure(FieldError("recurrence_anchor_mismatch")), "series moved off its weekday")
        check(resolve(["start": 1_791_381_600, "end": 1_791_385_200], current: tuesdaySeries) != .failure(
            FieldError("recurrence_anchor_mismatch")), "one occurrence may move anywhere")
        // span all across a DST change keeps the wall time (Berlin: series from Jan 5, 09:00).
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let shifted = EventFields.shiftedSeriesTime(requested: 1_793_088_000 /* Oct 27 2026 09:00 CET */,
                                                    occurrence: 1_792_393_200 /* Oct 19 09:00 CEST */,
                                                    base: 1_767_600_000 /* Jan 5 09:00 CET */,
                                                    requestZone: berlin, eventZone: berlin)
        check(shifted == 1_767_600_000 + 8 * 86_400, "Jan 13 09:00, not 10:00: \(shifted)")
        // Moves.
        check(target(["targetCalendarID": "OTHER"]).target.calendarID == "OTHER", "move")
        check(target(["targetCalendarID": "CAL", "title": "x"]).touched == [.title], "same calendar isn't a move")
    }

    // MARK: Verifier (§14)

    static func verifier() {
        let plan = target(["title": "New", "notes": "N", "alarms": [["kind": "relative", "offset": -600]],
                           "timeZone": "Asia/Calcutta", "structuredLocation": ["title": "HQ", "latitude": 1,
                                                                             "longitude": 2]])
        var saved = plan.target
        check(EventWriteVerifier.mismatches(plan.target, saved, touched: plan.touched, macZone: ny).isEmpty, "match")
        saved.timeZone = "Asia/Kolkata"
        check(EventWriteVerifier.mismatches(plan.target, saved, touched: plan.touched, macZone: ny).isEmpty,
              "zone alias")
        saved.timeZone = "UTC"
        check(EventWriteVerifier.mismatches(plan.target, saved, touched: plan.touched, macZone: ny) == [.timeZone],
              "zone mismatch")
        check(EventWriteVerifier.code([.timeZone], "rolled_back") == "time_zone_readback_failed_rolled_back", "code")
        saved = plan.target
        saved.notes = "N "
        saved.alarms = [.relative(-600), .relative(0)]
        saved.place = PlaceSpec(title: "HQ", latitude: 1.00001, longitude: 2, radius: nil)
        check(EventWriteVerifier.mismatches(plan.target, saved, touched: plan.touched, macZone: ny)
              == [.notes, .structuredLocation, .alarms], "three mismatches in field order")
        saved = plan.target
        saved.title = "Changed elsewhere"
        check(EventWriteVerifier.mismatches(plan.target, saved, touched: [.notes], macZone: ny).isEmpty,
              "untouched fields aren't compared")
        // All-day ends: iCloud's 23:59:59.
        let allDay = target(["allDay": true, "start": 1_791_259_200, "end": 1_791_432_000,
                             "timeZone": "America/New_York"])
        saved = allDay.target
        saved.end -= 1
        check(EventWriteVerifier.mismatches(allDay.target, saved, touched: allDay.touched, macZone: ny).isEmpty,
              "exclusive end minus a second")
        saved.end -= 86_400
        check(EventWriteVerifier.mismatches(allDay.target, saved, touched: allDay.touched, macZone: ny) == [.end],
              "a day short")
        saved = allDay.target
        saved.timeZone = nil
        check(EventWriteVerifier.mismatches(allDay.target, saved, touched: allDay.touched, macZone: ny).isEmpty,
              "saved floating in the Mac's zone")
        // Madrid dates saved floating on a New York Mac: same calendar days, different instants.
        let madrid = target(["allDay": true, "start": 1_791_237_600, "end": 1_791_410_400,
                             "timeZone": "Europe/Madrid"])
        saved = madrid.target
        saved.timeZone = nil
        saved.start = 1_791_259_200
        saved.end = 1_791_431_999
        check(EventWriteVerifier.mismatches(madrid.target, saved, touched: madrid.touched, macZone: ny).isEmpty,
              "floating all-day dates match by day")
        saved.start += 86_400
        check(EventWriteVerifier.mismatches(madrid.target, saved, touched: madrid.touched, macZone: ny) == [.start],
              "a different first day")
        // Recurrence: equivalent rules pass.
        let weekly = target(["recurrence": ["kind": "rule", "frequency": "weekly"]])
        saved = weekly.target
        saved.recurrence = .rule(RecurrenceSpec(frequency: .weekly, weekdays: [.init(day: 3)]))
        check(EventWriteVerifier.mismatches(weekly.target, saved, touched: weekly.touched, macZone: ny).isEmpty,
              "provider added the weekday")
        saved.recurrence = .rule(RecurrenceSpec(frequency: .weekly, interval: 2))
        check(EventWriteVerifier.mismatches(weekly.target, saved, touched: weekly.touched, macZone: ny) == [.recurrence],
              "different interval")
    }

    static func paging() {
        // iCloud's ID for an occurrence changed on its own (live probe, Oct 2026).
        check(EventSeries.id("ABC:1D2E/RID=814176000") == "ABC:1D2E" && EventSeries.id("ABC:1D2E") == "ABC:1D2E",
              "series ID")
        let key = EventPageKey((1_791_295_200.5, "A:B:C", 1_791_295_200))
        check(key.cursor == "v1:1791295200:1791295200:A:B:C", "cursor text")
        check(EventPageKey(cursor: key.cursor) == key, "cursor round trip, IDs with colons")
        check(EventPageKey(cursor: "v2:1:2:x") == nil && EventPageKey(cursor: "v1:x:2:id") == nil &&
              EventPageKey(cursor: "v1:1:2:") == nil, "bad cursors")
        let a = EventPageKey((10, "B", 0)), b = EventPageKey((10, "C", 0)), c = EventPageKey((11, "A", 0))
        check(a < b && b < c, "start, then ID")
        check(EventPageKey((10, "B", 5)) < EventPageKey((10, "B", 6)), "then occurrence")
    }
}

extension EventChange: CustomStringConvertible {
    public var description: String { "EventChange" }
}

extension Result where Success == EventChange, Failure == FieldError {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a), .success(let b)): a == b
        case (.failure(let a), .failure(let b)): a == b
        default: false
        }
    }
}

extension Result where Success == (target: EventFields, touched: Set<EventField>), Failure == FieldError {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a), .success(let b)): a.target == b.target && a.touched == b.touched
        case (.failure(let a), .failure(let b)): a == b
        default: false
        }
    }

    static func != (lhs: Self, rhs: Self) -> Bool { !(lhs == rhs) }
}

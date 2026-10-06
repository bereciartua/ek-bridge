import EventKit
import Foundation

// Event reads and writes (plan 03 §6, §8–§11, §13, §14).
extension EventKitCommands {
    // MARK: Reads

    func readEvents(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        guard let calendar = calendar(p["calendarID"], .event) else {
            completion(["error": "target_unavailable"]); return
        }
        let start = Date(timeIntervalSince1970: (p["start"] as! NSNumber).doubleValue)
        let end = Date(timeIntervalSince1970: (p["end"] as! NSNumber).doubleValue)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let limit = (p["limit"] as! NSNumber).intValue
        var events = [EKEvent]()
        var overflow = false
        store.enumerateEvents(matching: predicate) { event, stop in
            if events.count >= EventPageKey.maxScanned {
                overflow = true
                stop.pointee = true
            } else {
                events.append(event)
            }
        }
        guard CommandPolicy.scopeStillSelected(
                id: calendar.calendarIdentifier, generation: call.selected.generation,
                scope: call.selected, reminders: false),
              call.stillAuthorized(),
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            completion(["error": "scope_changed"]); return
        }
        if overflow { completion(["error": "too_many_events_narrow_range"]); return }
        let after = (p["afterKey"] as? String).flatMap(EventPageKey.init(cursor:))
        let sorted = events.map { (key: EventPageKey(self.occurrenceKey($0)), event: $0) }
            .sorted { $0.key < $1.key }
            .filter { after == nil || after! < $0.key }
        var rows = [[String: Any]]()
        var used = 0
        var last: EventPageKey?
        var truncated = false
        for item in sorted {
            let row = eventRow(item.event, full: false)
            let size = Self.rowSize(row)
            if rows.count >= limit || (!rows.isEmpty && used + size > Self.rowBudget) {
                truncated = true
                break
            }
            rows.append(row)
            used += size
            last = item.key
        }
        var result: [String: Any] = ["items": rows, "truncated": truncated]
        if truncated, let last { result["nextCursor"] = last.cursor }
        completion(result)
    }

    func getEvent(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        guard let calendar = calendar(p["calendarID"], .event) else {
            completion(["error": "target_unavailable"]); return
        }
        switch findEvent(p["itemID"] as! String, in: calendar,
                         occurrenceStart: ReminderDueSpec.timestamp(p["occurrenceStart"]).map(Int.init)) {
        case .success(let event): completion(["item": eventRow(event, full: true)])
        case .failure(let error): completion(["error": error.code])
        }
    }

    // MARK: Create

    func createEvent(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        guard let calendar = writableCalendar(p["calendarID"], .event) else {
            completion(["error": "target_not_writable"]); return
        }
        let macZone = TimeZone.current
        let plan: (target: EventFields, touched: Set<EventField>)
        switch EventChange.parse(p, creating: true).flatMap({ change in
            EventFields.resolve(change, current: nil, calendarID: calendar.calendarIdentifier,
                                supportedAvailability: EventAvailabilityMapping.supported(calendar),
                                macZone: macZone, now: Date())
        }) {
        case .success(let value): plan = value
        case .failure(let error): completion(["error": error.code]); return
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(plan.target, plan.touched, to: event, calendar: calendar)
        guard reserveWrite(call, completion) else { return }
        let span: EKSpan = plan.target.recurrence == .none ? .thisEvent : .futureEvents
        do { try store.save(event, span: span, commit: true) } catch {
            completion(["error": "save_failed"]); return
        }
        let saved = event.eventIdentifier.flatMap(store.event(withIdentifier:))
        let bad = saved.map {
            EventWriteVerifier.mismatches(plan.target, eventFields($0), touched: plan.touched, macZone: macZone)
        } ?? []
        guard let saved, bad.isEmpty else {
            do {
                try store.remove(event, span: .futureEvents, commit: true)
                finishWrite(["error": EventWriteVerifier.code(bad, "rolled_back")], call.request, completion)
            } catch {
                finishWrite(["error": EventWriteVerifier.code(bad, "cleanup_needed"),
                             "itemID": event.eventIdentifier ?? ""], call.request, completion)
            }
            return
        }
        finishWrite(["item": eventReceipt(saved, verified: plan.touched)], call.request, completion)
    }

    // MARK: Update and delete

    func changeEvent(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        let deleting = call.request.command == .deleteEvent
        // A detached occurrence's own ID leads to its series.
        guard let calendar = writableCalendar(p["calendarID"], .event),
              let base = store.event(withIdentifier: Self.seriesID(p["itemID"] as! String))
                ?? store.event(withIdentifier: p["itemID"] as! String),
              base.refresh(),
              base.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            completion(["error": "item_unavailable"]); return
        }
        let change: EventChange
        if deleting {
            guard let target = EventChange.occurrenceTarget(p) else {
                completion(["error": "invalid_parameters_or_target"]); return
            }
            change = target
        } else {
            switch EventChange.parse(p, creating: false) {
            case .success(let value): change = value
            case .failure(let error): completion(["error": error.code]); return
            }
        }
        let recurring = isRecurring(base)
        if let error = MutationPolicy.eventError(
            hasAttendees: base.hasAttendees, recurring: recurring,
            occurrenceGiven: change.occurrenceStart != nil, span: change.span,
            changesRecurrence: !change.recurrence.isKeep,
            moving: change.targetCalendarID.map { $0 != calendar.calendarIdentifier } ?? false) {
            completion(["error": error]); return
        }
        let occurrence: EKEvent
        switch findEvent(Self.seriesID(base), in: calendar, occurrenceStart: change.occurrenceStart) {
        case .success(let event): occurrence = event
        case .failure(let error): completion(["error": error.code]); return
        }
        guard matchesVersion(occurrence.lastModifiedDate, p["expectedVersion"]) else {
            completion(["error": "conflict"]); return
        }
        let span = recurring ? (change.span ?? .this) : .this
        let ekSpan: EKSpan = span == .this ? .thisEvent : .futureEvents
        // `all` acts on the first occurrence, which carries the series.
        let subject = span == .all ? base : occurrence
        let current = eventFields(subject)
        if !current.recurrence.isSupported, !change.recurrence.isKeep || span == .future {
            completion(["error": "recurrence_unsupported"]); return
        }
        if deleting {
            guard reserveWrite(call, completion) else { return }
            do {
                try store.remove(subject, span: ekSpan, commit: true)
                finishWrite(["deleted": true], call.request, completion)
            } catch { completion(["error": "save_failed"]) }
            return
        }
        var targetCalendar = calendar
        if let targetID = change.targetCalendarID, targetID != calendar.calendarIdentifier {
            switch moveTarget(targetID, .event, from: calendar) {
            case .success(let target): targetCalendar = target
            case .failure(let error): completion(["error": error.code]); return
            }
        }
        if !change.alarms.isKeep, current.alarms.contains(where: { $0 == nil }), !change.replaceUnsupportedAlarms {
            completion(["error": "alarms_unsupported"]); return
        }
        var adjusted = change
        if span == .all, subject !== occurrence {
            // Moving every occurrence: shift the series by the requested change.
            let startShift = subject.startDate.timeIntervalSince(occurrence.startDate)
            let endShift = subject.endDate.timeIntervalSince(occurrence.endDate)
            if let start = change.start { adjusted.start = start + Int(startShift) }
            if let end = change.end {
                adjusted.end = change.start.map { end - $0 + adjusted.start! } ?? end + Int(endShift)
            }
        }
        let macZone = TimeZone.current
        let plan: (target: EventFields, touched: Set<EventField>)
        switch EventFields.resolve(adjusted, current: current, calendarID: calendar.calendarIdentifier,
                                   supportedAvailability: EventAvailabilityMapping.supported(targetCalendar),
                                   macZone: macZone, now: Date()) {
        case .success(let value): plan = value
        case .failure(let error): completion(["error": error.code]); return
        }
        guard reserveWrite(call, completion) else { return }
        let snapshot = EventSnapshot(subject)
        apply(plan.target, plan.touched, to: subject, calendar: targetCalendar)
        do { try store.save(subject, span: ekSpan, commit: true) } catch {
            snapshot.restore(to: subject)
            completion(["error": "save_failed"]); return
        }
        let saved = reread(subject, span: span)
        let bad = saved.map {
            EventWriteVerifier.mismatches(plan.target, eventFields($0), touched: plan.touched, macZone: macZone)
        } ?? []
        guard let saved, bad.isEmpty else {
            snapshot.restore(to: subject)
            do {
                try store.save(subject, span: ekSpan, commit: true)
                finishWrite(["error": EventWriteVerifier.code(bad, "restored")], call.request, completion)
            } catch {
                finishWrite(["error": EventWriteVerifier.code(bad, "restore_failed"),
                             "itemID": subject.eventIdentifier ?? ""], call.request, completion)
            }
            return
        }
        finishWrite(["item": eventReceipt(saved, verified: plan.touched)], call.request, completion)
    }

    // MARK: Lookups

    /// The event, or with `occurrenceStart` the one occurrence that started
    /// then (§8.1).
    func findEvent(_ id: String, in calendar: EKCalendar, occurrenceStart: Int?) -> Result<EKEvent, FieldError> {
        guard let event = store.event(withIdentifier: id) ?? store.event(withIdentifier: Self.seriesID(id)),
              event.refresh(),
              event.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            return .failure(FieldError("item_unavailable"))
        }
        guard let occurrenceStart else { return .success(event) }
        let at = Date(timeIntervalSince1970: TimeInterval(occurrenceStart))
        if !isRecurring(event) {
            return abs(event.startDate.timeIntervalSince(at)) < 0.5
                ? .success(event) : .failure(FieldError("occurrence_not_found"))
        }
        let predicate = store.predicateForEvents(withStart: at.addingTimeInterval(-86_401),
                                                 end: at.addingTimeInterval(86_401), calendars: [calendar])
        let series = Self.seriesID(id)
        let matches = store.events(matching: predicate).filter {
            Self.seriesID($0) == series && $0.occurrenceDate.map { abs($0.timeIntervalSince(at)) < 0.5 } == true
        }
        return matches.count == 1 ? .success(matches[0]) : .failure(FieldError("occurrence_not_found"))
    }

    /// The saved event, read fresh from the store.
    private func reread(_ subject: EKEvent, span: EventSpan) -> EKEvent? {
        guard let id = subject.eventIdentifier else { return nil }
        if span == .all || !isRecurring(subject) { return store.event(withIdentifier: id) }
        let predicate = store.predicateForEvents(withStart: subject.startDate.addingTimeInterval(-1),
                                                 end: subject.endDate.addingTimeInterval(1),
                                                 calendars: [subject.calendar])
        return store.events(matching: predicate).first {
            Self.seriesID($0) == Self.seriesID(id) && abs($0.startDate.timeIntervalSince(subject.startDate)) < 0.5
        }
    }

    /// The series' ID. iCloud gives an occurrence changed on its own its own
    /// ID, "<series>/RID=<n>"; rows and lookups use the series'.
    static func seriesID(_ event: EKEvent) -> String {
        seriesID(event.eventIdentifier ?? "")
    }

    static func seriesID(_ id: String) -> String { EventSeries.id(id) }

    // Some providers populate occurrenceDate for a one-off event. Use recurrence
    // rules and detachment to decide whether mutations need series handling.
    func isRecurring(_ event: EKEvent) -> Bool {
        event.hasRecurrenceRules || event.isDetached
    }

    private func occurrenceKey(_ event: EKEvent) -> (Double, String, Double) {
        (event.startDate.timeIntervalSince1970, Self.seriesID(event),
         isRecurring(event) ? event.occurrenceDate?.timeIntervalSince1970 ?? 0 : 0)
    }

    // MARK: Values

    func eventFields(_ event: EKEvent) -> EventFields { EventFields.read(event) }

    private func apply(_ target: EventFields, _ touched: Set<EventField>, to event: EKEvent,
                       calendar: EKCalendar) {
        if touched.contains(.calendar) { event.calendar = calendar }
        if touched.contains(.title) { event.title = target.title }
        if touched.contains(.start) || touched.contains(.end) {
            // In EventKit an all-day event has no zone: isAllDay clears it, and
            // setting a zone afterwards makes the event timed again.
            if target.allDay {
                event.timeZone = nil
                event.isAllDay = true
            } else {
                event.isAllDay = false
                event.timeZone = target.timeZone.flatMap(TimeZone.init(identifier:))
            }
            event.startDate = Date(timeIntervalSince1970: target.start)
            // EventKit reads an all-day end as a moment in the last day; the
            // exclusive midnight would add a day.
            event.endDate = Date(timeIntervalSince1970: target.allDay ? target.end - 1 : target.end)
        }
        if touched.contains(.notes) { event.notes = target.notes }
        if touched.contains(.structuredLocation) || touched.contains(.location) {
            // A pin sets the location text to its title; text alone replaces the pin.
            if let place = target.place {
                event.structuredLocation = place.makeLocation()
            } else {
                event.structuredLocation = nil
                event.location = target.location
            }
        }
        if touched.contains(.url) {
            event.url = target.url.flatMap { URL(string: $0, encodingInvalidCharacters: false) }
        }
        if touched.contains(.alarms) { event.alarms = target.alarms.compactMap { $0?.makeAlarm() } }
        if touched.contains(.availability), let value = target.availability {
            event.availability = EventAvailabilityMapping.write(value)
        }
        if touched.contains(.recurrence) {
            event.recurrenceRules = target.recurrence.spec.map { [$0.makeRule()] }
        }
    }

    func eventReceipt(_ event: EKEvent, verified: Set<EventField>) -> [String: Any] {
        var receipt: [String: Any] = [
            "id": Self.seriesID(event),
            "calendarID": event.calendar.calendarIdentifier,
            "start": event.startDate.timeIntervalSince1970,
            "end": event.endDate.timeIntervalSince1970,
            "allDay": event.isAllDay,
            "timeZone": event.timeZone?.identifier ?? "",
            "recurring": isRecurring(event),
            "verified": EventField.allCases.filter(verified.contains).map(\.name),
        ]
        if isRecurring(event), let occurrence = event.occurrenceDate {
            receipt["occurrenceStart"] = occurrence.timeIntervalSince1970
        }
        if event.isAllDay { receipt["allDayVerified"] = verified.contains(.allDay) }
        if let version = version(event.lastModifiedDate) { receipt["version"] = version }
        return receipt
    }

    /// One event as read results show it (§15.2). List rows carry a notes
    /// preview and attendee counts; `full` rows the notes and attendees.
    func eventRow(_ event: EKEvent, full: Bool) -> [String: Any] {
        let (title, titleTruncated) = boundedTitle(event.title)
        let recurring = isRecurring(event)
        let zone = event.timeZone
        let recurrence = RecurrenceRead(event.recurrenceRules)
        var row: [String: Any] = [
            "id": Self.seriesID(event),
            "title": title,
            "titleTruncated": titleTruncated,
            "start": event.startDate.timeIntervalSince1970,
            "end": event.endDate.timeIntervalSince1970,
            "recurring": recurring,
            "allDay": event.isAllDay,
            "timeZone": zone?.identifier ?? "",
            "hasAttendees": event.hasAttendees,
            "occurrenceStart": recurring ? seconds(event.occurrenceDate) : NSNull(),
            "detached": event.isDetached,
            "recurrence": recurrence.core(zone: zone ?? .current),
            "status": Self.status(event.status),
            "created": seconds(event.creationDate),
            "modified": seconds(event.lastModifiedDate),
            "externalID": event.calendarItemExternalIdentifier as Any? ?? NSNull(),
        ]
        let notes = EventKitText.text(event.notes) ?? ""
        if full {
            let (text, truncated) = ItemText.prefix(notes, maxBytes: ItemText.maxReadNotesBytes)
            row["notes"] = notes.isEmpty ? NSNull() : text
            row["notesTruncated"] = truncated
        } else {
            let (text, truncated) = ItemText.prefix(notes, maxBytes: ItemText.notesPreviewBytes)
            row["notesPreview"] = notes.isEmpty ? NSNull() : text
            row["hasNotes"] = !notes.isEmpty
            row["notesTruncated"] = truncated
        }
        let location = EventKitText.text(event.location) ?? ""
        let (place, locationTruncated) = ItemText.prefix(location, maxBytes: ItemText.maxLocationBytes)
        row["location"] = location.isEmpty ? NSNull() : place
        row["locationTruncated"] = locationTruncated
        row["structuredLocation"] = event.structuredLocation.flatMap(PlaceSpec.read).map { $0.core } ?? NSNull()
        if let url = event.url?.absoluteString {
            row["url"] = url
            row["urlSchemeAllowed"] = ItemText.schemeAllowed(url)
        } else {
            row["url"] = NSNull()
        }
        let (alarms, alarmsTruncated) = AlarmSpec.readback(event.alarms)
        row["alarms"] = alarms
        row["alarmsTruncated"] = alarmsTruncated
        row["availability"] = EventAvailabilityMapping.supported(event.calendar).isEmpty
            ? NSNull() : (EventAvailabilityMapping.read(event.availability)?.rawValue as Any? ?? NSNull())
        let attendees = event.attendees ?? []
        let you = attendees.first { $0.isCurrentUser }
        row["attendeeCount"] = attendees.count
        row["organizerIsYou"] = event.organizer?.isCurrentUser ?? false
        row["yourStatus"] = you.map { Self.participantStatus($0.participantStatus) } ?? NSNull()
        if full {
            row["organizer"] = event.organizer.map(participant) ?? NSNull()
            row["attendees"] = attendees.prefix(200).map(participant)
            row["attendeesTruncated"] = attendees.count > 200
        }
        row["editable"] = editable(event, recurrence: recurrence)
        if let version = version(event.lastModifiedDate) { row["version"] = version }
        return row
    }

    /// What an agent may change (§15.2).
    private func editable(_ event: EKEvent, recurrence: RecurrenceRead) -> [String: Any] {
        func result(_ fields: Bool, _ times: Bool, _ rule: Bool, _ reason: String?) -> [String: Any] {
            ["fields": fields, "times": times, "recurrence": rule, "reason": reason as Any? ?? NSNull()]
        }
        if !event.calendar.allowsContentModifications { return result(false, false, false, "read_only_calendar") }
        if event.hasAttendees { return result(false, false, false, "invitation") }
        if event.timeZone == nil && !event.isAllDay { return result(true, false, false, "floating_time") }
        if !recurrence.isSupported { return result(true, true, false, "unsupported_recurrence") }
        return result(true, true, true, nil)
    }

    private func participant(_ person: EKParticipant) -> [String: Any] {
        var email: Any = NSNull()
        let url = person.url
        if url.scheme?.lowercased() == "mailto" {
            let address = String(url.absoluteString.dropFirst("mailto:".count))
                .split(separator: "?").first.map(String.init) ?? ""
            let decoded = address.removingPercentEncoding ?? address
            if !decoded.isEmpty { email = ItemText.prefix(decoded, maxBytes: 320).text }
        }
        let name = person.name.map { ItemText.prefix($0, maxBytes: 200).text }
        return ["name": name as Any? ?? NSNull(), "email": email,
                "role": Self.participantRole(person.participantRole),
                "status": Self.participantStatus(person.participantStatus),
                "type": Self.participantType(person.participantType),
                "isYou": person.isCurrentUser]
    }

    static func status(_ status: EKEventStatus) -> String {
        switch status {
        case .confirmed: "confirmed"
        case .tentative: "tentative"
        case .canceled: "canceled"
        default: "none"
        }
    }

    static func participantRole(_ role: EKParticipantRole) -> String {
        switch role {
        case .required: "required"
        case .optional: "optional"
        case .chair: "chair"
        case .nonParticipant: "non_participant"
        default: "unknown"
        }
    }

    static func participantStatus(_ status: EKParticipantStatus) -> String {
        switch status {
        case .pending: "pending"
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .delegated: "delegated"
        case .completed: "completed"
        case .inProcess: "in_process"
        default: "unknown"
        }
    }

    static func participantType(_ type: EKParticipantType) -> String {
        switch type {
        case .person: "person"
        case .room: "room"
        case .resource: "resource"
        case .group: "group"
        default: "unknown"
        }
    }
}

/// Everything a write may change on an event, as EventKit objects, so a
/// failed readback can put it back (§14). Held in memory only.
@MainActor
struct EventSnapshot {
    let calendar: EKCalendar
    let title: String?
    let start: Date
    let end: Date
    let allDay: Bool
    let timeZone: TimeZone?
    let notes: String?
    let location: String?
    let structuredLocation: EKStructuredLocation?
    let url: URL?
    let alarms: [EKAlarm]
    let availability: EKEventAvailability
    let rules: [EKRecurrenceRule]?

    init(_ event: EKEvent) {
        calendar = event.calendar
        title = event.title
        start = event.startDate
        end = event.endDate
        allDay = event.isAllDay
        timeZone = event.timeZone
        notes = event.notes
        location = event.location
        // The objects themselves: a copy loses parts such as an alarm's sound.
        structuredLocation = event.structuredLocation
        url = event.url
        alarms = event.alarms ?? []
        availability = event.availability
        rules = event.recurrenceRules
    }

    func restore(to event: EKEvent) {
        event.calendar = calendar
        event.title = title
        event.timeZone = timeZone
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.location = location
        event.structuredLocation = structuredLocation
        event.url = url
        event.alarms = alarms
        if availability != .notSupported { event.availability = availability }
        event.recurrenceRules = rules
    }
}

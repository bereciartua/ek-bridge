import AppKit
import EventKit

/// Names an Activity row's item by looking it up in EventKit now (P6). Only
/// the item's ID is stored; the title and time are read when shown and kept
/// in memory only.
enum ItemLookup {
    static func snapshot(_ ref: ItemRef, store: EKEventStore, zone: TimeZone = .current) -> ItemSnapshot {
        switch ref.kind {
        case "event": event(ref, store: store, zone: zone)
        case "reminder": reminder(ref, store: store)
        default: .deleted
        }
    }

    private static func event(_ ref: ItemRef, store: EKEventStore, zone: TimeZone) -> ItemSnapshot {
        let found = store.event(withIdentifier: EventSeries.id(ref.id)) ?? store.event(withIdentifier: ref.id)
            ?? ref.externalID.flatMap { store.calendarItems(withExternalIdentifier: $0).first as? EKEvent }
        guard let base = found else { return .deleted }
        var subject = base
        // A repeating event: the occurrence the change named, within a day
        // either side (as the approval panel finds it).
        if base.hasRecurrenceRules || base.isDetached, let occurrence = ref.occurrence, ref.span != "all" {
            let at = Date(timeIntervalSince1970: occurrence)
            let predicate = store.predicateForEvents(withStart: at.addingTimeInterval(-86_401),
                                                     end: at.addingTimeInterval(86_401), calendars: [base.calendar])
            let series = EventSeries.id(base.eventIdentifier ?? ref.id)
            let matches = store.events(matching: predicate).filter {
                EventSeries.id($0.eventIdentifier ?? "") == series &&
                    $0.occurrenceDate.map { abs($0.timeIntervalSince(at)) < 0.5 } == true
            }
            guard let match = matches.first else { return .deleted }
            subject = match
        }
        return ItemSnapshot(title: displayTitle(subject.title),
                            when: ApprovalSummaries.when(EventFields.read(subject), zone: zone),
                            collectionID: subject.calendar?.calendarIdentifier)
    }

    private static func reminder(_ ref: ItemRef, store: EKEventStore) -> ItemSnapshot {
        let found = store.calendarItem(withIdentifier: ref.id) as? EKReminder
            ?? ref.externalID.flatMap { store.calendarItems(withExternalIdentifier: $0).first as? EKReminder }
        guard let reminder = found else { return .deleted }
        let when: String?
        if reminder.isCompleted {
            when = reminder.completionDate.map {
                String(localized: "Completed \($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
            } ?? String(localized: "Completed")
        } else {
            when = reminder.dueDateComponents.flatMap(ApprovalSummaries.dueText).map { String(localized: "Due \($0)") }
        }
        return ItemSnapshot(title: displayTitle(reminder.title), when: when,
                            collectionID: reminder.calendar?.calendarIdentifier)
    }

    /// One line, at most 200 characters: titles come from other people too.
    static func displayTitle(_ raw: String?) -> String {
        let line = (raw ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return String(localized: "Untitled") }
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// Calendar's and Reminders' own links to an item. Calendar opens the
    /// event; Reminders opens the app on the reminder (verified on macOS
    /// 27, docs/TESTING.md ▸ Live-test copy).
    static func showURL(_ ref: ItemRef) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let id = ref.id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        switch ref.kind {
        case "event": return URL(string: "ical://ekevent/\(id)?method=show&options=more")
        case "reminder": return URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")
        default: return nil
        }
    }

    /// Opens the item in Calendar or Reminders, or the app when the link
    /// doesn't open.
    @MainActor
    static func show(_ ref: ItemRef) -> Bool {
        if let url = showURL(ref), NSWorkspace.shared.open(url) { return true }
        let bundleID = ref.kind == "event" ? "com.apple.iCal" : "com.apple.reminders"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

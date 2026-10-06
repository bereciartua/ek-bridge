import EventKit
import Foundation

// Reminder reads and writes (plan 03 §9, §10, §12–§14).
extension EventKitCommands {
    // MARK: Reads

    func readReminders(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        guard let list = calendar(p["listID"], .reminder) else {
            completion(["error": "target_unavailable"]); return
        }
        let predicate: NSPredicate
        switch p["status"] as? String ?? "all" {
        case "incomplete":
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                              calendars: [list])
        case "completed":
            predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil,
                                                             calendars: [list])
        default:
            predicate = store.predicateForReminders(in: [list])
        }
        let limit = (p["limit"] as! NSNumber).intValue
        let dueAfter = ReminderDueSpec.timestamp(p["dueAfter"]).map(TimeInterval.init)
        let dueBefore = ReminderDueSpec.timestamp(p["dueBefore"]).map(TimeInterval.init)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            DispatchQueue.main.async {
                guard let self else { completion(["error": "app_unavailable"]); return }
                guard !call.isCancelled() else { completion(["error": "cancelled"]); return }
                guard CommandPolicy.scopeStillSelected(
                        id: list.calendarIdentifier, generation: call.selected.generation,
                        scope: call.selected, reminders: true),
                      call.stillAuthorized(),
                      EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                    completion(["error": "scope_changed"]); return
                }
                guard let reminders else { completion(["error": "fetch_failed"]); return }
                let safe = reminders
                    .filter { $0.calendar.calendarIdentifier == list.calendarIdentifier }
                    .filter { reminder in
                        guard dueAfter != nil || dueBefore != nil else { return true }
                        // A due range leaves out reminders without a due date.
                        guard let due = ReminderFields.instant(reminder.dueDateComponents)?
                            .timeIntervalSince1970 else { return false }
                        return (dueAfter.map { due >= $0 } ?? true) && (dueBefore.map { due < $0 } ?? true)
                    }
                    .sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }
                let after = p["afterID"] as? String
                let remaining = after.map { cursor in
                    safe.filter { $0.calendarItemIdentifier > cursor }
                } ?? safe
                var rows = [[String: Any]]()
                var used = 0
                var truncated = false
                for reminder in remaining {
                    let row = self.reminderRow(reminder)
                    let size = Self.rowSize(row)
                    if rows.count >= limit || (!rows.isEmpty && used + size > Self.rowBudget) {
                        truncated = true
                        break
                    }
                    rows.append(row)
                    used += size
                }
                var result: [String: Any] = ["items": rows, "truncated": truncated]
                if truncated, let last = rows.last?["id"] as? String { result["nextCursor"] = last }
                completion(result)
            }
        }
    }

    func getReminder(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        guard calendar(p["listID"], .reminder) != nil else {
            completion(["error": "target_unavailable"]); return
        }
        guard let reminder = store.calendarItem(withIdentifier: p["itemID"] as! String) as? EKReminder,
              reminder.refresh(), reminder.calendar.calendarIdentifier == p["listID"] as? String else {
            completion(["error": "item_unavailable"]); return
        }
        completion(["item": reminderRow(reminder, full: true)])
    }

    // MARK: Create

    func createReminder(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        guard let list = writableCalendar(p["listID"], .reminder) else {
            completion(["error": "target_not_writable"]); return
        }
        let plan: (target: ReminderFields, touched: Set<ReminderField>)
        switch ReminderChange.parse(p, creating: true).flatMap({
            ReminderPlan.resolve($0, current: nil, listID: list.calendarIdentifier, now: Date())
        }) {
        case .success(let value): plan = value
        case .failure(let error): completion(["error": error.code]); return
        }
        guard reserveWrite(call, completion) else { return }
        let reminder = EKReminder(eventStore: store)
        ReminderSchedule.apply(plan.target, plan.touched, to: reminder, list: list)
        do { try store.save(reminder, commit: true) } catch {
            completion(["error": "save_failed"]); return
        }
        let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder
        let bad = saved.map {
            ReminderWriteVerifier.mismatches(plan.target, ReminderSchedule.fields($0), touched: plan.touched)
        } ?? []
        guard let saved, bad.isEmpty else {
            do {
                try store.remove(reminder, commit: true)
                finishWrite(["error": ReminderWriteVerifier.code(bad, "rolled_back")], call.request, completion)
            } catch {
                finishWrite(["error": ReminderWriteVerifier.code(bad, "cleanup_needed"),
                             "itemID": reminder.calendarItemIdentifier], call.request, completion)
            }
            return
        }
        finishWrite(["item": reminderReceipt(saved, verified: plan.touched)], call.request, completion)
    }

    // MARK: Update, complete and delete

    func changeReminder(_ call: Call, _ completion: @escaping ([String: Any]) -> Void) {
        let p = call.p
        let command = call.request.command
        guard let list = writableCalendar(p["listID"], .reminder),
              let reminder = store.calendarItem(withIdentifier: p["itemID"] as! String) as? EKReminder,
              reminder.refresh(),
              reminder.calendar.calendarIdentifier == p["listID"] as? String else {
            completion(["error": "item_unavailable"]); return
        }
        if command != .updateReminder {
            if let error = MutationPolicy.reminderError(
                recurring: reminder.hasRecurrenceRules,
                completed: reminder.isCompleted,
                completing: command == .completeReminder,
                recurrenceScope: ReminderRecurrenceScope.parse(p["recurrenceScope"])
            ) {
                completion(["error": error]); return
            }
        }
        guard matchesVersion(reminder.lastModifiedDate, p["expectedVersion"]) else {
            completion(["error": "conflict"]); return
        }
        if command == .completeReminder && reminder.hasRecurrenceRules {
            completeRecurringOccurrence(call, list: list, completion: completion)
            return
        }
        if command == .deleteReminder {
            guard reserveWrite(call, completion) else { return }
            do {
                try store.remove(reminder, commit: true)
                finishWrite(["deleted": true], call.request, completion)
            } catch { completion(["error": "save_failed"]) }
            return
        }
        var change: ReminderChange
        if command == .completeReminder {
            change = ReminderChange()
            change.completed = true
        } else {
            switch ReminderChange.parse(p, creating: false) {
            case .success(let value): change = value
            case .failure(let error): completion(["error": error.code]); return
            }
        }
        var targetList = list
        if let targetID = change.targetListID, targetID != list.calendarIdentifier {
            switch moveTarget(targetID, .reminder, from: list) {
            case .success(let target): targetList = target
            case .failure(let error): completion(["error": error.code]); return
            }
        }
        let plan: (target: ReminderFields, touched: Set<ReminderField>)
        switch ReminderPlan.resolve(change, current: ReminderSchedule.fields(reminder),
                                    listID: list.calendarIdentifier, now: Date()) {
        case .success(let value): plan = value
        case .failure(let error): completion(["error": error.code]); return
        }
        guard reserveWrite(call, completion) else { return }
        let snapshot = ReminderSnapshot(reminder)
        ReminderSchedule.apply(plan.target, plan.touched, to: reminder, list: targetList)
        do { try store.save(reminder, commit: true) } catch {
            snapshot.restore(to: reminder)
            completion(["error": "save_failed"]); return
        }
        let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder
        let bad = saved.map {
            ReminderWriteVerifier.mismatches(plan.target, ReminderSchedule.fields($0), touched: plan.touched)
        } ?? []
        guard let saved, bad.isEmpty else {
            snapshot.restore(to: reminder)
            do {
                try store.save(reminder, commit: true)
                finishWrite(["error": ReminderWriteVerifier.code(bad, "restored")], call.request, completion)
            } catch {
                finishWrite(["error": ReminderWriteVerifier.code(bad, "restore_failed"),
                             "itemID": reminder.calendarItemIdentifier], call.request, completion)
            }
            return
        }
        finishWrite(["item": reminderReceipt(saved, verified: plan.touched)], call.request, completion)
    }

    private func completeRecurringOccurrence(_ call: Call, list: EKCalendar,
                                             completion: @escaping ([String: Any]) -> Void) {
        let request = call.request
        let p = request.parameters
        let selected = call.selected
        let stillAuthorized = call.stillAuthorized
        let listID = list.calendarIdentifier
        let itemID = p["itemID"] as! String
        let generation = selected.generation
        store.fetchReminders(matching: store.predicateForReminders(in: [list])) {
            [weak self] fetched in
            DispatchQueue.main.async {
                guard let self else { completion(["error": "app_unavailable"]); return }
                guard !call.isCancelled() else { completion(["error": "cancelled"]); return }
                guard CommandPolicy.scopeStillSelected(id: listID, generation: generation,
                            scope: selected, reminders: true), stillAuthorized(),
                      EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                    completion(["error": "scope_changed"]); return
                }
                guard let fetched else { completion(["error": "fetch_failed"]); return }
                let before = fetched.filter { $0.calendar.calendarIdentifier == listID }
                let preExistingIDs = Set(before.map(\.calendarItemIdentifier))
                guard preExistingIDs.count == before.count,
                      before.filter({ $0.calendarItemIdentifier == itemID }).count == 1,
                      let target = self.store.calendarItem(withIdentifier: itemID) as? EKReminder,
                      target.refresh(), target.calendar.calendarIdentifier == listID,
                      self.matchesVersion(target.lastModifiedDate, p["expectedVersion"]) else {
                    completion(["error": "conflict"]); return
                }
                guard let candidate = RecurringReminderCompletion.candidate(target) else {
                    completion(["error": "recurrence_shape_unsupported"]); return
                }
                guard let due = ReminderDueSpec.timestamp(p["occurrenceDue"]),
                      Double(due) == candidate.due.timeIntervalSince1970,
                      p["occurrenceFingerprint"] as? String == candidate.fingerprint else {
                    completion(["error": "occurrence_conflict"]); return
                }
                guard !RecurringReminderCompletion.ambiguousExistingCompletion(
                    candidate, records: before.map(RecurringReminderCompletion.record)) else {
                    completion(["error": "ambiguous_occurrence"]); return
                }
                guard self.reserveWrite(call, completion) else { return }
                target.isCompleted = true
                do { try self.store.save(target, commit: true) }
                catch { completion(["error": "completion_pending_reconciliation"]); return }
                self.store.fetchReminders(matching: self.store.predicateForReminders(in: [list])) {
                    [weak self] fetchedAfter in
                    DispatchQueue.main.async {
                        guard let self else { completion(["error": "app_unavailable"]); return }
                        guard CommandPolicy.scopeStillSelected(id: listID, generation: generation,
                                    scope: selected, reminders: true), stillAuthorized(),
                              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                            self.finishWrite(["error": "scope_changed_after_write"],
                                             request, completion)
                            return
                        }
                        guard let fetchedAfter else {
                            self.finishWrite(["error": "completion_readback_uncertain"],
                                             request, completion)
                            return
                        }
                        let rows = fetchedAfter.filter { $0.calendar.calendarIdentifier == listID }
                        guard let transition = RecurringReminderCompletion.verifiedTransition(
                                candidate, preExistingIDs: preExistingIDs,
                                records: rows.map(RecurringReminderCompletion.record)),
                              let completed = rows.first(where: {
                                  $0.calendarItemIdentifier == transition.completedID
                              }),
                              let next = rows.first(where: {
                                  $0.calendarItemIdentifier == transition.nextID
                              }) else {
                            self.finishWrite(["error": "completion_readback_uncertain"],
                                             request, completion)
                            return
                        }
                        self.finishWrite([
                            "completedOccurrence": self.reminderReceipt(completed, verified: [.completed]),
                            "nextOccurrence": self.reminderReceipt(next, verified: []),
                            "completedDue": candidate.due.timeIntervalSince1970,
                            "nextDue": candidate.nextDue.timeIntervalSince1970,
                        ], request, completion)
                    }
                }
            }
        }
    }

    // MARK: Rows

    func reminderRow(_ reminder: EKReminder, full: Bool = false) -> [String: Any] {
        var row = ReminderSchedule.describe(reminder, full: full)
        if let candidate = RecurringReminderCompletion.candidate(reminder) {
            row["completionCandidate"] = [
                "recurrenceScope": "occurrence",
                "occurrenceDue": candidate.due.timeIntervalSince1970,
                "occurrenceFingerprint": candidate.fingerprint,
            ] as [String: Any]
        }
        if let version = version(reminder.lastModifiedDate) { row["version"] = version }
        return row
    }

    /// A list row without the notes preview: receipts are journaled (§3 invariant 8).
    func reminderReceipt(_ reminder: EKReminder, verified: Set<ReminderField>) -> [String: Any] {
        var receipt = reminderRow(reminder)
        receipt["notesPreview"] = nil
        receipt["verified"] = ReminderField.allCases.filter(verified.contains).map(\.rawValue)
        receipt["listID"] = reminder.calendar?.calendarIdentifier ?? ""
        return receipt
    }
}

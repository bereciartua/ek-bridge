# Testing, evidence, and troubleshooting

## Repeatable checks

| Check | Command | What it establishes |
| --- | --- | --- |
| Offline Swift/Python suite | `sh test.sh` | Command shape, grant/signature/replay policy, due/recurrence guards, journal behavior, credential files, timer, and an ad hoc signed XPC requirement **candidate**. No live EventKit data is required. |
| Ordinary app and CLI build | `sh build.sh` | Source compiles, emits an ad hoc signed app and matching CLI. Does not install or launch the app. |
| Native window fixture | `sh ui_test.sh` from a logged-in GUI session | Eight real AppKit close/reopen cycles for Controls, Clients & Permissions, and Activity, including repeated Activity opens. Uses fake clients and collections; no EventKit permission request or live bridge. |

The shell scripts currently name the Command Line Tools macOS 26.5 SDK directly. A different SDK requires a deliberate build-script update and fresh validation. Run the UI fixture in a logged-in graphical session; a headless or restricted process can fail before its window assertions run. `build/` is ignored by source control.

## Bounded live observations

These observations were made with explicit local approval and synthetic items, then checked by readback. They are not a compatibility guarantee for other accounts or future macOS releases. No private event names, source IDs, credentials, or raw logs are included here.

| Area | Observed result | Limit |
| --- | --- | --- |
| macOS privacy and signed updates | One locally signed installation retained Full Calendar and Reminders access across same-identity updates. | A different identity or bundle ID needs its own TCC test. |
| Grants and local transport | Scoped Calendar/Reminders reads and synthetic create/edit/complete/delete worked; reads outside the grant returned `forbidden`. Key rotation and revocation were exercised. | Same-user malicious processes remain outside the protection boundary. |
| UI | User visually confirmed Controls and Clients & Permissions closed/reopened with readable real collection rows after the window ownership fix. The fake-data AppKit fixture also exercised Activity. | Activity's real-data window was not separately user-verified. |
| Events | Timed synthetic writes and an all-day iCloud creation/readback passed; one provider returned all-day end as one second before the requested exclusive end. | Other providers and existing all-day mutation are unverified or blocked. |
| Reminders | Synthetic timed/all-day due, alarm, daily/weekly recurrence creation and edits, nonrecurring complete/delete, and local readback passed. A one-shot synthetic alert was observed on an iPhone and its item removed. | Future recurring notification delivery is unverified. |
| Narrow recurring completion | An app-owned daily iCloud reminder was completed once through the signed bridge; local readback found one completed instance and the next incomplete instance. Same-key replay and distinct-key rejection passed after an app restart. | This used a locally verified source pin. Cross-device sync and alert delivery for this bridge command remain unverified. The repository build has no pin. |
| Availability | A locked, awake Mac answered read-only bridge requests; a sleep/wake/unlock test preserved access. After an actual Mac reboot and login, the installed app process, bridge, Full Access, saved grants, bounded reads, and denial of an ungranted target were observed without a manual app launch or repair. | Operation while asleep or logged out is not established. A logout/login **without** a reboot and longer background runs remain separate checks. |

The ordinary source build has no persistent installation, privacy grants, login registration, or client credential. The installed Mac's local configuration is evidence for that machine only. The historical XPC candidate has only offline requirement tests and is not a deployed transport.

### Test-run manifest

The bounded live observations above were recorded on **October 4, 2026 (America/New_York)** on macOS **27.0.1 (26A434)**. The recurring-completion source and synthetic bridge test were uploaded in commit `a64880623ff120f536117b5717bc840d0b5b2013`. The later window-ownership source and isolated UI fixture were uploaded through commit `bc1746d36ae54662fae671644fcaf1c664eca874`. The final locally installed app tested after login was version **0.2.0**, executable SHA-256 `aede6adf60eecb52fcce31e22b80eb96f86803f300d5e3ae1feb23e2f2f86ed9`; its signed bundle has a local source pin absent from the repository default. The Mac rebooted at **10:45 p.m. EDT** and logged in at **10:46 p.m. EDT**. Subsequent read-only checks found the app process, active bridge, Full Access, unchanged client grants, authorized bounded reads, and denial of an ungranted read.

This is a redacted session record, **not** a checked-in raw test log or a claim that all observations were on the final binary. The earlier phone alert and synthetic write checks were supervised on preceding signed builds. Preserve that distinction when adding future evidence. Collection IDs, client credentials, certificate identity, private titles, and raw response files are intentionally excluded.

## Troubleshooting

| Symptom | Read-only checks and next step |
| --- | --- |
| No ◷ icon | Check whether the installed app launched in the current logged-in GUI session. Inspect macOS Login Items status if Launch at Login was expected. Do not start a second copy while one is running. |
| `Bridge request failed or session is unavailable` | Check ◷ → **Bridge:** and Controls → **Local bridge**; confirm the app is running and enabled. Check that `client.py` uses the matching `bridge-client` and the app-managed credential path. A stale `/tmp` descriptor after a crash is not proof that the bridge is active. |
| `forbidden` | Confirm the exact Calendar or Reminders ID and the client's saved action boxes. Names can repeat; a Read grant does not imply Create, and vice versa. |
| `full_access_required` | Check both the app status and macOS Privacy & Security settings for the installed signed app. A differently signed or relocated build may be treated differently. Do not reset TCC blindly. |
| `conflict`, `item_unavailable`, or `occurrence_conflict` | Read the item again and use its current ID, version, due instant, and fingerprint. Provider sync can change them. |
| `idempotency_pending_review`, `completion_readback_uncertain`, `journal_clock_rollback`, or timeout after a write | Stop automatic retries. Inspect the exact item and journal state locally with appropriate authorization; reconcile whether the write happened before sending any new key. Never delete the journal merely to clear a failure. |
| Recurring completion is `recurrence_shape_unsupported` | Check the [exact supported shape](API.md#reminder-schedules) and whether a verified local source pin exists. The repository default intentionally disables this path. Do not clear a real item's recurrence to bypass the guard. |
| Controls or Clients window behaves oddly | Use the installed build with retained `NSWindowController` owners; the eight-cycle GUI fixture covers close/reopen in isolation. If a new crash appears, compare the crash report's executable UUID with the installed binary before attributing a fixture crash to the installed app. Avoid publishing raw crash reports containing local paths. |

When investigating, prefer a disposable client and app-owned empty test collections. A user must approve any live Calendar or Reminders mutation. Keep credentials, personal titles, full activity records, and raw response files out of issues and commits.

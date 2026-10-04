# EventKit Bridge

A local macOS menu bar app holds Apple Calendar and Reminders permission. A task **running on the same Mac** can submit narrowly scoped JSON commands through a temporary private file exchange. There is no network listener or cloud-to-localhost route. An offline, sleeping, or logged-out Mac cannot be assumed to run a local task.

## Source and deployment

This repository contains the source and offline tests. `build.sh` produces an app and a local client without installing either. A separately authorized, consistently signed installation is needed for macOS Calendar and Reminders grants to persist. The current installed app, client grants, credentials, and bridge availability are local state, not tracked here.

A same-identity signed update was installed after offline tests. In a bounded live test, an app-created temporary reminder list and separate client passed timed due and alarm create/read/edit/delete, all-day date readback, daily recurrence create/read, title-edit preservation, weekly recurrence edit, and the expected recurring-completion rejection. The temporary items, client credential, and empty app-created collections were removed. The existing client policy and saved bridge setting were preserved. Recurring notification delivery was not observed because the future test items were removed before their alert times.

## Durable-grant policy

- The local user creates a named client in **Clients & Permissions…**. The app generates a 32-byte Ed25519 signing seed, formatted as `ekb_v1_` followed by lowercase hex, and saves it directly to `~/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json`. This is an **asymmetric signing credential**, not a bearer token sent to the bridge. Possession of its file still permits signing requests. The app stores only the corresponding public verifier, name, ID, revision, grants, and limited activity history in `client-registry.json`. The secret is never displayed or copied to the clipboard. Both directories are mode 0700 and the credential file is mode 0600. A future Keychain-backed provider could replace this file storage.
- A new client starts with **zero grants**. The user grants any combination of read, create, edit, delete, and (for reminder lists) complete on each named Calendar or Reminders collection. The Clients & Permissions window shows collections by account and lets the user review draft checkbox changes before saving; grants for collections unavailable from EventKit are retained. Rotation first confirms replacing only that client's safe credential file, then replaces its public verifier and file. Revocation invalidates the verifier and removes the local credential file. Both actions invalidate in-flight requests by revision. If saving or replacement fails after a verifier change, the UI attempts to revoke and remove the file, reporting incomplete cleanup. Cancel before confirmation changes nothing; creation never overwrites an existing file.
- The UI groups controls in scrollable windows and shows a client ID, collection name, account, exact collection ID, and writable status beside each grant. It disables write choices for read-only collections. Isolated native AppKit screenshots and frame reports confirmed readable Controls and Clients & Permissions windows after fixing zero-size scroll documents and an early constraint activation. Visual QA of real collection rows in the installed build remains pending.
- Every request is signed over the entire canonical payload, including the bridge process's session name, UUID, command, parameters, client ID, and timestamp. The app rejects expired requests and repeated UUIDs, verifies the signature, checks the current grant for that exact collection and action, checks strict parameter shape, and checks current macOS Full Access before data access. The app rechecks grant revision and bridge availability after asynchronous reads. Individual request timestamps expire after 30 seconds; the client grant does not expire.
- A saved grant authorizes its listed read/create/edit/delete/complete actions until changed or revoked. Normal granted CRUD runs without a second app approval sheet or write arm. The local client is created with zero grants; choosing scopes in the app is the configuration approval boundary. Existing idempotency, expected-version, and conservative mutation safeguards still apply. Agent-side authorization to perform a particular user task remains a separate requirement.
- Activity retains at most 500 time/client ID/command/outcome entries. It omits keys, request parameters, titles, and item details. The UI shows the latest 100 entries. A policy-store failure causes the bridge to fail closed.
- The bridge is **off by default on migration**. The user can enable it locally, which saves the choice; while the app is running it stays available until disabled or quit, and a later app launch, including Launch at Login, restores the saved choice. Disabling saves off. Grant creation alone does not turn it on. There is no network listener or Mach service. A logged-out, sleeping, or offline Mac cannot answer a local task; wake and login behavior still require live testing.

The private file exchange and credential file protect against other macOS user accounts. They **do not isolate another process running as Martin's same macOS user**: that process can read a mode-0600 signing seed or alter the same-user policy store. The signature authenticates possession of the credential, not an individual process. The older [signed XPC candidate](Candidate/ARCHITECTURE.md) also cannot solve this alone if a same-user process can invoke its signed CLI. A stronger per-process boundary needs a separate design and approval.

## Build and offline tests

On the Air with Command Line Tools and the macOS 26.5 SDK:

```sh
sh test.sh
sh build.sh
```

`build.sh` produces `build/EventKitBridge.app` and `build/bridge-client`, using **ad hoc signing** for source validation by default. It does not install, launch, register, create a certificate, or request permissions. Use the approved stable signing identity only in a separately authorized deployment; ad hoc builds can be treated as different TCC identities.
The durable bridge's `current.json` descriptor no longer has an expiry field; use the matching newly built `bridge-client`. The older V2 client expects the old descriptor.

For a separately authorized bounded synthetic test, `EVENTKIT_SYNTHETIC_TEST=1 sh build.sh` compiles a test-only control route. It can report authorization and test IDs, create only app-owned test collections and one separately scoped client while the bridge process is stopped, or remove the empty collections and revoke that client after the bridge stops. Existing unrelated clients and the saved bridge-enabled choice are preserved. Launch this variant through LaunchServices so macOS evaluates the installed app identity. The ordinary build omits these controls; it is the build to retain after test cleanup.

The offline tests cover reminder due dates, recurrence parsing, schedule guards, command shape and mutation guards, idempotency, private timer scheduling, signature and client-scope checks, default deny, durable scoped write authorization after a registry reload, unsupported action denial, cross-client keys, tampering, replay, grant revision changes, key rotation, revocation, and private credential create/replace/remove and unsafe-path rejection. They do not establish live TCC, lock, sleep, logout, or user-interface behavior.

## Local client

For a separately approved client enrollment, the app creates the client and saves the credential itself at the path shown in its confirmation. The file has this shape; the signing seed must never be pasted into chat, shell arguments, logs, or screenshots:

```json
{"clientID":"<issued UUID>","key":"<issued ekb_v1_ key>"}
```

For a read, put parameters in another mode-0600 JSON file and run **on Air**:

```sh
python3 client.py read_events --credentials-file "$HOME/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json" --params-file /private/path/params.json
```

`client.py` invokes the Swift signing client. For a custom build directory set `EVENTKIT_CLIENT_BINARY` to its `bridge-client` path. The local task passes only the credential **path**; the client reads and signs locally, and neither the secret nor a bearer key appears in process arguments or bridge request files. The client prints the response; invoke it only for data the task is authorized to receive. A local write request times out after 60 seconds without a response; this is not a grant expiry. Revocation blocks signatures, and the app removes its known local credential file; any copies made elsewhere require separate cleanup.

| Command | Required parameters |
| --- | --- |
| `authorization_status`, `calendar_count`, `reminder_list_count`, `scope_status` | none |
| `read_events` | `calendarID`, `start`, `end` (Unix seconds), `limit` |
| `read_reminders` | `listID`, `limit`, optional `afterID` |
| `create_event` | `calendarID`, `title`, `start`, `end`, `idempotencyKey` |
| `update_event` | create fields plus `itemID`, `expectedVersion` |
| `delete_event` | `calendarID`, `itemID`, `expectedVersion`, `idempotencyKey` |
| `create_reminder` | `listID`, `title`, `idempotencyKey`; optional `due`, `recurrence` |
| `update_reminder` | `listID`, `itemID`, `expectedVersion`, `title`, `idempotencyKey`; optional `due`, `recurrence` |
| `complete_reminder`, `delete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey` |

The event write surface is title and UTC start/end plus delete. Reminder writes can set a title, a due date, a common recurrence rule, completion, or delete. The `due` parameter is optional on create and update; omission on update preserves the existing schedule, and `{"kind":"none"}` clears due and its bridge-managed alarm. A timed due is `{"kind":"timed","at":<integer Unix seconds>,"timeZone":"America/New_York"}`. An all-day due is `{"kind":"all_day","date":"YYYY-MM-DD","timeZone":"America/New_York"}`. Timed due defaults to one alarm at due time; all-day due defaults to no alarm. Set `alarmAt` to an integer Unix second for a specific alert time or to `null` for no alarm. A new alarm must be in the future. The bridge sets the start date to the same components as the due date for syncing. Due and alarm readback describes what EventKit returns, including floating or ambiguous times that the bridge cannot safely round-trip. In the live synthetic test, the provider retained the all-day date but removed its timezone; the bridge reported `floating_all_day` and no alarm.

`recurrence` is optional; omission on update preserves the rule and `{"kind":"none"}` clears it. A rule is `{"kind":"rule","frequency":"daily|weekly|monthly|yearly","interval":1}`. Weekly rules can add `"weekdays":["MO","WE"]`; monthly rules can add `"dayOfMonth":15`. An optional `end` may be `{"kind":"count","count":10}` or `{"kind":"until","at":<integer Unix seconds>}`. Create requires a due date when setting recurrence. For an existing reminder with an absolute alarm, adding recurrence requires resending the due date so the bridge can replace that one-shot alarm with a relative alarm. Updating a due date that would replace a custom alarm or nonmatching start is rejected. Persisted synthetic tests confirmed daily/weekly rule and relative-alarm readback, title-edit preservation, and rule editing. Repeated notifications on the Mac or other devices are **unverified**. Recurring completion and deletion remain blocked, so the bridge cannot yet advance a recurring series by marking its current occurrence complete.

No notes, attendees, locations, subtasks, or tags. Reads return bounded titles, times/status, IDs, versions, due/recurrence/alarm summaries, and limited flags. Event reads are limited to 31-day windows and at most 100 results; reminder pages are at most 100 and are not stable snapshots. EventKit still fetches a whole reminder list internally before paging. Existing events with recurrence, all-day status, attendees, or floating time retain conservative mutation restrictions. Sync races and EventKit/journal non-atomicity remain possible.

For each new write, generate a key in the form `ekb3_<Unix-seconds>_<lowercase-UUID>` and reuse that **exact key and parameters** for retries. For example, a local task can generate one with `python3 -c 'import time,uuid; print(f"ekb3_{int(time.time())}_{uuid.uuid4()}")'`. A key is valid for seven days from its embedded timestamp, with five seconds of future clock skew. After that it is rejected even if its completed journal entry has been pruned. Completed expired entries are pruned when a later write is inspected, so routine long-running use does not fill the journal. Up to 1,000 unexpired or uncertain entries are retained; a burst beyond that fails closed with `journal_full`. Pending writes are never auto-pruned or silently retried, because their EventKit outcome may be uncertain. If the clock moves backward after pruning, new writes fail closed with `journal_clock_rollback` until the previous high-water time is reached or the situation is reconciled. The older UUID-only journal entries remain as tombstones during migration, and old-format keys are rejected by this version.

## Remaining live checks

The installed build still needs a visual check of the Controls and Clients & Permissions windows with real collection rows. Isolated native AppKit screenshots confirmed both windows' headings, text, buttons, and scroll layout; those fixtures had no Calendar or Reminders permission, so they could not display real rows. The live synthetic test covered one-shot timed and all-day reminders and daily/weekly recurrence, including readback and cleanup. The provider omitted timezone from an all-day reminder; its date was retained. Completion and deletion of an active recurring series remain blocked by design. A separate bounded test is needed before enabling series completion or claiming repeated alert delivery; test on-device notifications and sync behavior explicitly. Wake, logout/relogin, and longer-running background behavior also remain untested.

A same-user process can still read a client's private credential file. Keep enrollment limited to the collections and actions that process needs, and revoke its client if that access is no longer wanted. The cloud agent has no direct localhost route, and an offline, sleeping, or logged-out Mac cannot run a local task.

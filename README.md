# EventKit Bridge

A local macOS menu bar app holds Apple Calendar and Reminders permission. A task **running on the same Mac** can submit narrowly scoped JSON commands through a temporary private file exchange. There is no network listener or cloud-to-localhost route. An offline, sleeping, or logged-out Mac cannot be assumed to run a local task.

## Source and installed state

The installed signed app is the supervised version 2 pilot. Its synthetic scoped CRUD, rotation, revocation, and cleanup were live-tested; the bridge was last disabled, its temporary client was revoked, and its test collections were removed. Launch at Login reports enabled and Calendar and Reminders had Full Access. **This source now proposes a durable-grant update and has not been installed or enabled.** The new `DurableLocalBridgeEnabled` setting is absent from the installed pilot and defaults to off after an update, so the source change alone cannot activate ongoing access.

Previous version 1 testing used only synthetic iCloud collections and items, then removed them. Counts worked with the Mac manually locked and awake. V2 locked item access, actual login startup, sleep/wake, logout/relogin, and sync conflict behavior remain untested. Permission grants persisted across signed pilot updates. A prior poll stall could not be attributed definitively; the common-mode timer change passed an awake test and an offline tracking-mode test.

## Proposed durable-grant policy

- The local user creates a named client in **Manage Clients…**. The app generates a 32-byte Ed25519 signing seed, formatted as `ekb_v1_` followed by lowercase hex, and saves it directly to `~/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json`. This is an **asymmetric signing credential**, not a bearer token sent to the bridge. Possession of its file still permits signing requests. The app stores only the corresponding public verifier, name, ID, revision, grants, and limited activity history in `client-registry.json`. The secret is never displayed or copied to the clipboard. Both directories are mode 0700 and the credential file is mode 0600. A future Keychain-backed provider could replace this file storage.
- A new client starts with **zero grants**. The user grants any combination of read, create, edit, delete, and (for reminder lists) complete on each named Calendar or Reminders collection. The UI can change or clear one collection grant at a time; all other grants are retained. Rotation first confirms replacing only that client's safe credential file, then replaces its public verifier and file. Revocation invalidates the verifier and removes the local credential file. Both actions invalidate in-flight requests by revision. If saving or replacement fails after a verifier change, the UI attempts to revoke and remove the file, reporting incomplete cleanup. Cancel before confirmation changes nothing; creation never overwrites an existing file.
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
The durable bridge's `current.json` descriptor no longer has an expiry field; its newly built `bridge-client` must be used with the updated app. The installed V2 client expects the old descriptor.

The offline tests cover command shape and mutation guards, idempotency, private timer scheduling, signature and client-scope checks, default deny, durable scoped write authorization after a registry reload, unsupported action denial, cross-client keys, tampering, replay, grant revision changes, key rotation, revocation, and private credential create/replace/remove and unsafe-path rejection. They do not establish live TCC, lock, sleep, logout, or user-interface behavior.

## Local client

After a separately approved deployment, the app creates the client and saves the credential itself at the path shown in its confirmation. The file has this shape; the signing seed must never be pasted into chat, shell arguments, logs, or screenshots:

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
| `create_reminder` | `listID`, `title`, `idempotencyKey` |
| `update_reminder` | create fields plus `itemID`, `expectedVersion` |
| `complete_reminder`, `delete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey` |

The event write surface is title and UTC start/end plus delete; reminder writes cover title, completion, and delete. No notes, attendees, alarms, locations, recurrence edits, due dates, subtasks, or tags. Reads return bounded titles, times/status, IDs, versions, and limited flags. Event reads are limited to 31-day windows and at most 100 results; reminder pages are at most 100 and are not stable snapshots. EventKit still fetches a whole reminder list internally before paging. Existing events with recurrence, all-day status, attendees, or floating time, and recurring reminders, have conservative mutation restrictions. Sync races and EventKit/journal non-atomicity remain possible.

For each new write, generate a key in the form `ekb3_<Unix-seconds>_<lowercase-UUID>` and reuse that **exact key and parameters** for retries. For example, a local task can generate one with `python3 -c 'import time,uuid; print(f"ekb3_{int(time.time())}_{uuid.uuid4()}")'`. A key is valid for seven days from its embedded timestamp, with five seconds of future clock skew. After that it is rejected even if its completed journal entry has been pruned. Completed expired entries are pruned when a later write is inspected, so routine long-running use does not fill the journal. Up to 1,000 unexpired or uncertain entries are retained; a burst beyond that fails closed with `journal_full`. Pending writes are never auto-pruned or silently retried, because their EventKit outcome may be uncertain. If the clock moves backward after pruning, new writes fail closed with `journal_clock_rollback` until the previous high-water time is reached or the situation is reconciled. The older UUID-only journal entries remain as tombstones during migration, and old-format keys are rejected by this version.

## Deployment approval and remaining live checks

The next approval can be bounded to one signed app and matching local-client update, one temporary synthetic client scoped only to fresh app-created test collections, and enabling the persistent bridge only for a supervised restart and beyond-15-minute synthetic check. The app should then be disabled, the client revoked, and all synthetic items and collections removed. This approval need not include real collection grants. Installing the update alone leaves the new bridge setting off and creates no client. Verify TCC grants survive, a granted write works without an app sheet, an ungranted action fails, removal/revocation blocks a client, and the bridge-off switch blocks requests. Separately test locked-awake reads/writes, sleep/wake, and logout/relogin with Martin performing those device actions. Credential creation cancellation/error and grant-edit UI remain untested live.

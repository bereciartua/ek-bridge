# EventKit Bridge

A local macOS menu bar app holds Apple Calendar and Reminders permission. A task **running on the same Mac** can submit narrowly scoped JSON commands through a temporary private file exchange. There is no network listener or cloud-to-localhost route. An offline, sleeping, or logged-out Mac cannot be assumed to run a local task.

## Source and installed state

This repository contains a **new, source-only version 2** named-client design. It has been compiled and tested offline; it has **not** replaced or launched the installed pilot, been signed with Martin's Keychain identity, received live credentials, or been tested with EventKit data. The installed signed pilot remains the older supervised version 1: Launch at Login reports enabled, Calendar and Reminders Full Access were granted, and the bridge was last disabled. The version 2 client is incompatible with the installed pilot.

Previous version 1 testing used only synthetic iCloud collections and items, then removed them. Counts worked with the Mac manually locked and awake; a signed-build locked item test, actual login startup, sleep/wake, logout/relogin, and sync conflict behavior remain untested. Permission grants persisted across signed pilot updates. A prior poll stall could not be attributed definitively; the common-mode timer change passed an awake test and an offline tracking-mode test.

## Version 2 policy

- The local user creates a named client in **Manage Clients…**. The app generates a 32-byte Ed25519 signing seed, formatted as `ekb_v1_` followed by lowercase hex, and saves it directly to `~/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json`. This is an **asymmetric signing credential**, not a bearer token sent to the bridge. Possession of its file still permits signing requests. The app stores only the corresponding public verifier, name, ID, revision, grants, and limited activity history in `client-registry.json`. The secret is never displayed or copied to the clipboard. Both directories are mode 0700 and the credential file is mode 0600. A future Keychain-backed provider could replace this file storage.
- A new client starts with **zero grants**. The user grants any combination of read, create, edit, delete, and (for reminder lists) complete on each named Calendar or Reminders collection. The UI can change or clear one collection grant at a time; all other grants are retained. Rotation first confirms replacing only that client's safe credential file, then replaces its public verifier and file. Revocation invalidates the verifier and removes the local credential file. Both actions invalidate in-flight requests by revision. If saving or replacement fails after a verifier change, the UI attempts to revoke and remove the file, reporting incomplete cleanup. Cancel before confirmation changes nothing; creation never overwrites an existing file.
- Every request is signed over the entire canonical payload, including the short-lived bridge session name, UUID, command, parameters, client ID, and timestamp. The app rejects expired requests and repeated UUIDs, verifies the signature, checks the current grant for that exact collection and action, checks strict parameter shape, and checks current macOS Full Access before data access. The app rechecks grant revision and bridge availability after asynchronous reads and after a write review.
- Each write needs a separate local approval sheet showing the named client, action, target, existing item summary for edit/delete/complete, proposed title and time, and request digest. Approval is consumed once, expires, and is cancelled if the bridge stops. The default build rejects all writes; `EVENTKIT_LIVE_WRITES=1` is an explicit build flag for a later approved deployment. Existing idempotency and expected-version safeguards still apply.
- Activity retains at most 500 time/client ID/command/outcome entries. It omits keys, request parameters, titles, and item details. The UI shows the latest 100 entries. A policy-store failure causes the bridge to fail closed.
- The bridge still starts **off**, even at login, and must be enabled locally for 15 minutes. Creating a client or grant does not turn it on. No persistent service, Mach listener, or unattended access is added by this version.

The private file exchange and credential file protect against other macOS user accounts. They **do not isolate another process running as Martin's same macOS user**: that process can read a mode-0600 signing seed or alter the same-user policy store. The signature authenticates possession of the credential, not an individual process. The older [signed XPC candidate](Candidate/ARCHITECTURE.md) also cannot solve this alone if a same-user process can invoke its signed CLI. A stronger per-process boundary needs a separate design and approval.

## Build and offline tests

On the Air with Command Line Tools and the macOS 26.5 SDK:

```sh
sh test.sh
sh build.sh
EVENTKIT_LIVE_WRITES=1 EVENTKIT_OUTPUT_DIR="$PWD/build/review-live" sh build.sh
```

`build.sh` produces `build/EventKitBridge.app` and `build/bridge-client`, using **ad hoc signing** for source validation by default. It does not install, launch, register, create a certificate, or request permissions. The live-write build command above is also only a build. Use the approved stable signing identity only in a separately authorized deployment; ad hoc builds can be treated as different TCC identities.

The offline tests cover command shape and mutation guards, idempotency, private timer scheduling, signature and client-scope checks, default deny, cross-client keys, tampering, replay, grant revision changes, key rotation, revocation, private credential create/replace/remove and unsafe-path rejection, and exact-write approval cancellation/expiry. They do not establish live TCC, lock, sleep, logout, or user-interface behavior.

## Local client

After a separately approved deployment, the app creates the client and saves the credential itself at the path shown in its confirmation. The file has this shape; the signing seed must never be pasted into chat, shell arguments, logs, or screenshots:

```json
{"clientID":"<issued UUID>","key":"<issued ekb_v1_ key>"}
```

For a read, put parameters in another mode-0600 JSON file and run **on Air**:

```sh
python3 client.py read_events --credentials-file "$HOME/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json" --params-file /private/path/params.json
```

`client.py` invokes the Swift signing client. For a custom build directory set `EVENTKIT_CLIENT_BINARY` to its `bridge-client` path. The local task passes only the credential **path**; the client reads and signs locally, and neither the secret nor a bearer key appears in process arguments or bridge request files. The client prints the response; invoke it only for data the task is authorized to receive. A write request can wait up to six minutes for local approval, capped by bridge expiry. Revocation blocks signatures, and the app removes its known local credential file; any copies made elsewhere require separate cleanup.

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

## Next supervised step

Before deploying version 2, review the diff and explicitly authorize replacing the installed signed app while keeping its bundle ID and signing identity, creating one or more real client keys, saving the credentials, and running a supervised synthetic test. Verify TCC grants survive the update; test correct and wrong client keys, grant removal, key rotation/revocation, cancelled approval, bridge expiry, and cleanup. Separately test locked-awake reads, sleep/wake, and logout/relogin with Martin performing those device actions. Do not assume a locked screen permits a new on-screen write approval.

# EventKit Bridge

A local macOS menu bar app that owns Apple Calendar and Reminders permission.
It exposes a short-lived, narrowly scoped file bridge to a task running **on
the same Mac**. There is no internet listener, daemon, or cloud-to-localhost
path.

## Current validation

The earlier counts-only build was launched with the user's approval. macOS
reported Full access to both EventKit types. Its local task client returned
permission status, 23 calendar count, and 12 reminder-list count while
unlocked and again while the screen was manually locked with the Mac awake.
No item was read or changed.

The current menu bar build compiles and its isolated protocol, policy, journal,
and client tests pass. **It has not been launched or tested with real items.**
Its ad hoc signature is not a durable TCC identity. Sleep, logout, offline,
login item startup, synchronization conflicts, and actual reads/writes remain
untested. Do not infer locked-screen operation after sleep or logout.

## Build and tests

This Mac has Command Line Tools with a working macOS 26.5 SDK:

```sh
sh test.sh
EVENTKIT_OUTPUT_DIR="$PWD/build/next" sh build.sh
codesign --verify --verbose=2 build/next/EventKitBridge.app
```

The build uses ad hoc signing by default. A user-approved stable signing
identity can be supplied through `EVENTKIT_SIGN_IDENTITY`; the script does
not create or fetch a certificate. Preserve the bundle identifier and
signing identity across versions. Do not treat an ad hoc rebuild as retaining
the prior macOS permission grant.

## App controls

The status menu shows Calendar and Reminders permission state, bridge state,
Open Controls, Enable/Disable Bridge, Launch at Login, and Quit. Launch at
Login uses `SMAppService.mainApp` when the user clicks that menu item; it has
not been enabled or tested. The controls window requests each permission,
lists calendar or list metadata, lets the user select at most one target of
each type, clears targets, and has a separate write arm checkbox. The app
starts with no item targets, bridge off, and writes unarmed. The bridge
expires after 15 minutes and disarms writes.

## Local commands

`client.py` sends one JSON command to an active session. For item commands,
put a JSON parameter object in a private mode-0600 file and pass
`--params-file /path/to/params.json`. Keep titles out of process arguments
and logs. The client prints the response, so invoke it only when the task is
authorized to receive that item data.

| Command | Required parameters |
| --- | --- |
| `authorization_status`, `calendar_count`, `reminder_list_count` | none |
| `read_events` | `calendarID`, `start`, `end` (Unix seconds), `limit` |
| `read_reminders` | `listID`, `limit` |
| `create_event` | `calendarID`, `title`, `start`, `end`, `idempotencyKey` |
| `update_event` | create fields plus `itemID`, `expectedVersion` |
| `delete_event` | `calendarID`, `itemID`, `expectedVersion`, `idempotencyKey` |
| `create_reminder` | `listID`, `title`, `idempotencyKey` |
| `update_reminder` | create fields plus `itemID`, `expectedVersion` |
| `complete_reminder`, `delete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey` |

Each request requires an active random session token, recent timestamp, and
unique request UUID. The app rejects extra fields, unselected targets,
unarmed writes, event ranges over 31 days, reads over 100 results, titles over
200 UTF-8 bytes, event durations over 7 days, stale versions, and changes to
recurring or detached events and recurring reminders. It returns only title,
time/status, identifier, version, and recurrence flag for reads. It never
returns notes, attendees, locations, or reminder notes. EventKit's
`lastModifiedDate` supplies a best-effort version; items without one cannot
be updated or deleted.

Writes use a private journal in Application Support. An idempotency key is
recorded before EventKit is called. Repeating a completed request returns
its small receipt (identifier/version or deleted flag); a changed payload
with the same key is rejected. An interrupted pending write is rejected until
manually reconciled, because EventKit might have committed it. The journal
stores a payload hash and small receipts, not titles. It is not an atomic
transaction with EventKit. Calendar sync can change identifiers or records
between fetch, version check, and save; the app cannot guarantee conflict-free
remote synchronization.

## Boundaries and next live steps

The `/tmp/eventkit-bridge-<uid>` exchange is mode 0700 with mode 0600 files.
It authenticates a local same-user task with a short-lived token, but another
process running as that user could read that token. This is **not** strong
isolation from same-user software. An XPC or peer-verified socket design
would need a stable signed client and its own local-task connectivity test.

Before real item access, review the built app and obtain approval to launch
it, handle any fresh macOS permission prompt, select a disposable test
calendar and reminder list, and read only test items. Obtain separate approval
before creating, updating, completing, or deleting disposable items. Review
signing and same-user threat assumptions before enabling live writes. Login
item registration and installation need separate approval. Cloud tasks cannot
call this bridge directly, and an offline, sleeping, or logged-out Mac cannot
be assumed reachable.

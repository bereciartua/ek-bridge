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
The read-only `security find-identity -v -p codesigning` check found no valid
local signing identity. Options for a later approved test are to use an
existing Apple Developer signing identity if one is supplied, or deliberately
test ad hoc signing with the expectation of fresh TCC prompts after a rebuild.
This project does not create certificates or install software.

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
The default build rejects every write command and disables the write arm
control. Only a separately reviewed build with `EVENTKIT_LIVE_WRITES=1`
permits live writes. That variant was compiled for a static check only; it
has not been launched or used.

## App controls

The status menu shows Calendar and Reminders permission state, bridge state,
selected targets, write state, login registration state, Open Controls,
Enable/Disable Bridge, Launch at Login, and Quit. Launch at
Login uses `SMAppService.mainApp` when the user clicks that menu item; it has
not been enabled or tested. The menu disables registration until the app is
in an Applications folder and distinguishes enabled from needing System
Settings approval. The controls window requests each permission,
lists calendar or list metadata, lets the user select at most one target of
each type, clears targets, and has a separate write arm checkbox. The app
starts with no item targets, bridge off, and writes unarmed. The bridge
expires after 15 minutes and disarms writes.
Login startup alone does not enable the bridge or restore targets. This is a
deliberate attended prototype; it does not yet offer unattended access after
restart or after session expiry.

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
| `read_reminders` | `listID`, `limit`, optional `afterID` cursor |
| `create_event` | `calendarID`, `title`, `start`, `end`, `idempotencyKey` |
| `update_event` | create fields plus `itemID`, `expectedVersion` |
| `delete_event` | `calendarID`, `itemID`, `expectedVersion`, `idempotencyKey` |
| `create_reminder` | `listID`, `title`, `idempotencyKey` |
| `update_reminder` | create fields plus `itemID`, `expectedVersion` |
| `complete_reminder`, `delete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey` |

Each request requires an active random session token, recent timestamp, and
unique request UUID. The app rejects extra fields, unselected targets,
unarmed writes, event ranges over 31 days, times outside 1900–2100,
read pages over 100 results, write titles over 200 UTF-8 bytes, event
durations over 7 days, stale versions, and changes to recurring or detached
events, all-day events, events with attendees, floating-time event updates,
and recurring reminders. Completing an already-completed reminder is
rejected. New timed events use UTC instants; all-day creation is unsupported.
Read titles are truncated at 200 UTF-8 bytes with a `titleTruncated` flag.
Reads return only title, time/status, identifier, version, all-day/timezone,
and recurrence flags. It never
returns notes, attendees, locations, or reminder notes. EventKit's
`lastModifiedDate` supplies a best-effort version; items without one cannot
be updated or deleted.

Event reads return a complete result only for a selected calendar and a
window containing at most the requested limit; otherwise they return
`too_many_events_narrow_range` and the caller must split the time range.
Reminder reads sort by item ID and provide `nextCursor` when another page
exists. Pages are not a stable snapshot if Reminders changes between calls.
EventKit still fetches the complete reminder list internally before paging;
this has not been load-tested on large lists.

Writes use a private journal in Application Support. An idempotency key is
recorded before EventKit is called. Repeating a completed request returns
its small receipt (identifier/version or deleted flag); a changed payload
with the same key is rejected. An interrupted pending write is rejected until
manually reconciled, because EventKit might have committed it. The journal
stores a payload hash and small receipts, not titles. Pending entries have
no automatic recovery workflow; the journal stops accepting new keys at
1,000 entries until reviewed maintenance is implemented. It is not an atomic
transaction with EventKit. Calendar sync can change identifiers or records
between fetch, version check, and save; EventKit can even recreate a deleted
event during a race. The app cannot guarantee conflict-free remote
synchronization.

## Implementation status

| Capability | State |
| --- | --- |
| Permission and count bridge while locked and awake | Tested on previous build |
| Menu bar UI, target selection, login control | Compiled; not launched |
| Bounded item reads | Implemented; no real-item validation |
| Calendar and Reminders mutations | Implemented and statically built; disabled in default build |
| Idempotency and stale-version checks | Isolated tests; no EventKit transaction guarantee |
| Launch at login | UI path implemented; not registered or tested |
| Persistent unattended access | Not implemented |
| Stable signing identity | None available on this Mac |

## Boundaries and next live steps

The `/tmp/eventkit-bridge-<uid>` exchange is mode 0700 with mode 0600 files.
It authenticates a local same-user task with a short-lived token, but another
process running as that user could read that token. This is **not** strong
isolation from same-user software. An XPC or peer-verified socket design
would need a stable signed client and its own local-task connectivity test.

The minimum live sequence needs bundled action-time approval from the user:

1. Launch the new default read-only build, handle fresh macOS permission
   prompts, select a disposable test calendar and reminder list, and read
   their test items through the local task route.
2. Review the same-user token threat model, the signed identity to use, and
   the exact disposable create/update/complete/delete cases. Obtain separate
   approval before launching a write-enabled build or mutating those items.
3. Only after successful live tests, approve any app installation and
   `SMAppService` login registration. Verify the status is enabled, then test
   restart, awake lock, sleep/wake, and logout separately without changing
   power or lock settings on the user's behalf.

Cloud tasks cannot call this bridge directly, and an offline, sleeping, or
logged-out Mac cannot be assumed reachable.

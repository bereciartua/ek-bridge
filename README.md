# EventKit Bridge

A local macOS menu bar app that owns Apple Calendar and Reminders permission.
It exposes a short-lived, narrowly scoped file bridge to a task running **on
the same Mac**. There is no internet listener, daemon, or cloud-to-localhost
path.

## Current validation

The earlier counts-only build returned Full access, 23 calendars, and 12
reminder lists both unlocked and manually locked with the Mac awake. The
later supervised test used only an app-created `EventKit Bridge Test` calendar
and reminder list in iCloud. Bounded reads, event and reminder create/edit/
delete, and reminder completion passed. The synthetic items and both empty
collections were removed. A one-off iCloud event exposed a false recurrence
classification; the corrected build passed event edit/delete. The bridge was
disabled and the app quit after testing. No existing user items were read.

The latest source also disarms writes when targets change; it compiles and its
isolated tests pass, but that final UI change has not been retested live.
Sleep/wake, logout/relogin, login item startup, stable-signature TCC grants,
sync conflicts, and live item commands while locked remain untested. The
locked-awake count result does not establish those behaviors.

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
signing identity across versions. The test app's ad hoc designated requirement
is a build-specific code hash, and each launched build needed fresh macOS
Calendar and Reminders grants.
The default build rejects every write command and disables the write arm
control. Only a separately reviewed build with `EVENTKIT_LIVE_WRITES=1`
permits live writes. A temporary write-enabled variant was used only for
the approved synthetic test and then quit. No write build is installed.

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
For a supervised synthetic test, the controls can preview the Calendar and
Reminders account sources, create an empty calendar and list named
`EventKit Bridge Test`, and remove only those app-created collections after
they are verified empty. The app records their IDs to avoid deleting an
unrelated collection with the same name. It prefers a local source when one
already has collections of that type; otherwise it uses the default source,
which may sync to an account. The supervised test used iCloud with approval.
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
| `authorization_status`, `calendar_count`, `reminder_list_count`, `scope_status` | none |
| `read_events` | `calendarID`, `start`, `end` (Unix seconds), `limit` |
| `read_reminders` | `listID`, `limit`, optional `afterID` cursor |
| `create_event` | `calendarID`, `title`, `start`, `end`, `idempotencyKey` |
| `update_event` | create fields plus `itemID`, `expectedVersion` |
| `delete_event` | `calendarID`, `itemID`, `expectedVersion`, `idempotencyKey` |
| `create_reminder` | `listID`, `title`, `idempotencyKey` |
| `update_reminder` | create fields plus `itemID`, `expectedVersion` |
| `complete_reminder`, `delete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey` |

The implemented event write surface is title and UTC start/end time, plus
delete. All-day creation, location, notes, alarms, attendees, and recurrence
edits are not implemented. The implemented reminder write surface is title,
completion, and delete; due dates, priority, notes, subtasks, and tags are
not implemented. The command set is deliberately narrower than EventKit.

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
| Menu bar UI and target selection | Tested; final target-change disarm fix compiled only |
| App-created synthetic test collection controls | Tested with iCloud; collections removed |
| Bounded item reads | Tested on synthetic collections only |
| Calendar and Reminders mutations | Synthetic create/edit/delete and reminder completion passed; disabled in default build |
| Idempotency and stale-version checks | Isolated tests; no EventKit transaction guarantee |
| Launch at login | UI path implemented; not registered or tested |
| Persistent unattended access | Not implemented |
| Stable signing identity | None available on this Mac |

## Signing and everyday operation

This Mac has only Command Line Tools, no full Xcode, and
`security find-identity -v -p codesigning` returns zero identities. The
current app is ad hoc signed, with a designated requirement tied to its code
hash. For a single-Mac pilot, the smallest no-fee route is a user-approved
self-signed code-signing identity in the login Keychain, used consistently
with the existing bundle identifier. Apple documents this for local code
signing, but it is not a Developer ID distribution signature and TCC grant
persistence across updates must be tested. Avoid changing system trust
settings merely to test TCC. If Martin already has Apple Developer Program
membership, a Developer ID Application identity is the stronger distribution
route; new membership is currently USD 99/year. Xcode Personal Team signing
is free but needs Xcode and has periodic provisioning limits, so it is not the
smallest path on this Mac. See [Apple's code-signing technote](https://developer.apple.com/library/archive/technotes/tn2206/_index.html),
[account overview](https://developer.apple.com/help/account/basics/about-your-developer-account),
and [membership pricing](https://developer.apple.com/programs/enroll/).

The app already has an `SMAppService.mainApp` Launch at Login control, but
it has not been registered. Apple says registration launches subject to user
approval. The app's current policy still starts with no selected targets,
bridge off, and writes unarmed, and its 15-minute bridge expires. Signing and
login registration alone therefore do not make it an everyday integration.
See [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

An everyday mode needs a separately reviewed policy for remembered target
IDs, bridge availability while the user is logged in and the Mac awake, and
write authorization. The current random token in a same-user private `/tmp`
directory does not isolate the bridge from other software running as that
user. Before unattended writes, strengthen local caller authentication or
accept this same-user risk explicitly, and retain strict target and operation
bounds. The supported route demonstrated so far is `client.py` in a **local
task on Air**. Cloud tasks do not directly reach localhost, and an offline or
sleeping Mac cannot be assumed to run a local task.

## Boundaries and next live steps

The `/tmp/eventkit-bridge-<uid>` exchange is mode 0700 with mode 0600 files.
It authenticates a local same-user task with a short-lived token, but another
process running as that user could read that token. This is **not** strong
isolation from same-user software. An XPC or peer-verified socket design
would need a stable signed client and its own local-task connectivity test.

The next live pilot needs approval to create/use one local signing identity,
install one reviewed build at a stable path in `~/Applications`, grant its
Calendar and Reminders prompts, and optionally register Launch at Login.
First check that grants survive a rebuild signed by the same identity. Then
retest the target-change write disarm, local read/write flow while locked and
awake, sleep/wake, and logout/relogin as separate cases. Keep the bridge off
after login until the everyday access policy is explicitly approved. Martin
must perform any lock, sleep, logout, Keychain, and macOS privacy approvals.

Cloud tasks cannot call this bridge directly, and an offline, sleeping, or
logged-out Mac cannot be assumed reachable.

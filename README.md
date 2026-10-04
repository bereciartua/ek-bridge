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

The target-change disarm fix was also tested live: changing the selected test
targets and removing the empty test collections each disarmed writes, and a
synthetic event create was rejected with `writes_disabled`.

A self-signed local code-signing identity in the login Keychain was used for
four successive builds at the same installed path. Calendar and
Reminders Full Access persisted after all three updates without another prompt.
The installed app's menu reported `Login: enabled` after the user registered
Launch at Login. This is a local development signature, not a Developer ID
distribution signature; Gatekeeper assessment rejected it without any trust
change. Actual login startup, sleep/wake, logout/relogin, sync conflicts, and
live item commands while locked remain untested. The locked-awake count
result does not establish those behaviors.

During a signed-build diagnostic, the app remained active but its file bridge
stopped answering client requests. The empty iCloud test collections were
removed and the bridge disabled. The next signed build added the timer to
common run-loop modes; its awake local read and synthetic create/delete
checks passed, including after several minutes. The restart and timer change
were not isolated, so the cause of the earlier stall remains uncertain. A
second pair of synthetic iCloud test collections and their items was removed,
writes disarmed, and the bridge disabled. No locked item test was completed
in this run.

The source now routes the poll timer through a small common-mode scheduling
helper. An offline regression test drives a synthetic tracking run-loop mode:
the helper's timer fires there while a default-mode timer stays queued. This
matches [Apple's run-loop guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html):
Cocoa common modes include modal and event tracking modes, and timers in other
modes wait. The helper refactor has not been installed or tested live.

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
was a build-specific code hash, and each launched build needed fresh macOS
Calendar and Reminders grants. The installed pilot uses a self-signed identity
kept in the login Keychain.
The default build rejects every write command and disables the write arm
control. Only a separately reviewed build with `EVENTKIT_LIVE_WRITES=1`
permits live writes. The installed supervised pilot was built with this flag;
its bridge starts off and its write arm control starts off. It does not run
an unattended write session at login.

## App controls

The status menu shows Calendar and Reminders permission state, bridge state,
selected targets, write state, login registration state, Open Controls,
Enable/Disable Bridge, Launch at Login, and Quit. Launch at
Login uses `SMAppService.mainApp` when the user clicks that menu item; the
installed app reports registration enabled, but relogin startup is untested.
The menu disables registration until the app is
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
already has collections of that type; otherwise it prefers iCloud and then
the default source, which may sync to another account. The supervised test
used iCloud with approval.
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
| Permission and count bridge while locked and awake | Tested on previous build; signed-build locked item test pending |
| Menu bar UI and target selection | Tested, including target-change write disarm |
| App-created synthetic test collection controls | Tested with iCloud; collections removed |
| Bounded item reads | Tested on synthetic collections only, including installed signed build while awake |
| Calendar and Reminders mutations | Synthetic operations passed while awake; disabled in default build |
| Idempotency and stale-version checks | Isolated tests; no EventKit transaction guarantee |
| Launch at login | Registration reports enabled; actual login startup untested |
| Persistent unattended access | Not implemented |
| Stable signing identity | Self-signed in login Keychain; TCC grants persisted across two changed builds |

## Signing and everyday operation

This Mac has only Command Line Tools, no full Xcode. The installed app is
signed with `EventKit Bridge Local Signing`, a self-signed code-signing
identity in the login Keychain, and keeps the same bundle identifier across
updates. Apple documents self-signed identities for local code signing, but
this is not a Developer ID distribution signature. On this Mac, TCC Full
Access persisted across two changed signed builds at the stable installed
path. Gatekeeper still rejects the self-signed bundle for distribution; no
system trust settings were changed. If Martin already has Apple Developer Program
membership, a Developer ID Application identity is the stronger distribution
route; new membership is currently USD 99/year. Xcode Personal Team signing
is free but needs Xcode and has periodic provisioning limits, so it is not the
smallest path on this Mac. See [Apple's code-signing technote](https://developer.apple.com/library/archive/technotes/tn2206/_index.html),
[account overview](https://developer.apple.com/help/account/basics/about-your-developer-account),
and [membership pricing](https://developer.apple.com/programs/enroll/).

The app has an `SMAppService.mainApp` Launch at Login control and currently
reports registration enabled. Actual login startup has not been tested.
Apple says registration launches subject to user approval. The app's current
policy still starts with no selected targets,
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

### Proposed daily access policy (not implemented or approved)

The smallest useful extension is a remembered **read-only** scope: Martin
chooses one calendar and/or one reminder list in the app, approves exactly
which bounded fields and time windows the local task may read, and chooses
whether read availability starts after login and resumes after wake. The app
would display that state and provide an immediate off switch. It should mint
a fresh session token after each launch or wake rather than store a durable
credential. This still grants any process running as the same macOS user the
ability to copy the private `/tmp` token and read the selected scope while it
is active. Token rotation limits lifetime; it does not identify the caller.
If that same-user exposure is unacceptable, use a signed client with XPC peer
verification before enabling remembered reads. The current unsigned Python
client cannot be safely allowlisted by code signature.

For writes, replace the broad session-wide arm switch in a daily mode with
an approval for each fully parsed operation (or an explicitly approved small
batch). The app should show the target, action, title/time or current item,
and proposed change; hold the exact request in memory; expire approval
quickly; and execute it once. A chat request does not prove which same-user
process submitted a bridge command. Existing target checks, idempotency keys,
and expected versions should remain, but they do not substitute for this
approval boundary. No write approval should survive a restart or wake.

Enabling remembered reads requires new, explicit authorization for the
selected collections, returned fields, availability schedule, and same-user
token risk. The earlier approval for a supervised 15-minute test and Launch
at Login does not cover that expansion. Approval for each real write must
also be tied to its exact action and target.

An offline [signed XPC candidate](Candidate/ARCHITECTURE.md) now contains
peer-requirement construction, an immutable per-action approval policy, and
an AppKit review sheet. It is source only: the installed app has not changed,
there is no registered Mach service or signed client executable, and
remembered reads remain unimplemented and off. A signed CLI can still be
launched by another same-user process, so peer verification alone does not
resolve the remembered-read decision.

## Boundaries and next live steps

The `/tmp/eventkit-bridge-<uid>` exchange is mode 0700 with mode 0600 files.
It authenticates a local same-user task with a short-lived token, but another
process running as that user could read that token. This is **not** strong
isolation from same-user software. An XPC or peer-verified socket design
would need a stable signed client and its own local-task connectivity test.

The local signing identity, stable-path installation, permission grant,
grant-persistence check, and login registration are complete. When Martin is
available for another supervised session, test these cases separately:

1. Open and hold the status menu while an authorized local read-only request
   is queued; confirm the revised poll timer answers it and the 15-minute
   expiry still closes the session.
2. Create only synthetic items in app-created iCloud test collections, then
   have Martin lock the awake Mac. From a local task, read and perform the
   specifically approved synthetic edit/completion; unlock, delete the items
   and collections, and disable the bridge.
3. Have Martin sleep and wake the Mac; verify session expiration or rotation,
   permission state, and whether the local task route is available after wake.
4. Have Martin log out and back in; verify the login item starts, Calendar and
   Reminders grants persist, and bridge, targets, and writes start off.

Keep the bridge off after login until the everyday access policy is explicitly
approved. Martin must perform any lock, sleep, logout, Keychain, and macOS
privacy approvals. The signed build with the timer change responded while
awake, but the earlier stall's cause is not conclusively established.

Cloud tasks cannot call this bridge directly, and an offline, sleeping, or
logged-out Mac cannot be assumed reachable.

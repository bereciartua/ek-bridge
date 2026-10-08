# Local CLI and command reference

The command-line client, `bridge-client`, runs on the **same Mac and macOS user** as the app. It ships inside the app (`Contents/MacOS/bridge-client`); **Settings ▸ Developer ▸ Install Command-Line Tool** links it into `~/.local/bin`, and from a source checkout `python3 client.py` runs it. The examples use `python3 client.py`; `bridge-client` takes the same arguments. It reads a private credential file, signs a version-2 request, writes it to the bridge's private local file exchange, waits for a JSON response, and prints that response. AI agents use the same commands through the app's local MCP server instead; its tools, time formats and agent error texts are in [MCP](MCP.md). Cloud agents can reach that MCP server only through the optional Remote Access port and a tunnel the user runs ([MCP](MCP.md#use-from-cloud-agents)); the CLI and its file exchange have no remote route.

A *client* in the CLI and API is what the app calls a *connection*.

```sh
python3 client.py COMMAND --client 'NAME or ID' [--params-file '/private/path/parameters.json']
python3 client.py COMMAND --credentials-file '/private/path/client.json' [--params-file -]
python3 client.py --help
python3 client.py COMMAND --help
```

Brackets denote an optional argument; omit them when invoking it. Choose the key file with exactly one of:

- `--client NAME|ID` uses the app-managed key file for that client. An ID maps straight to `client-credentials/<id>.json`. A name is looked up, ignoring case and surrounding spaces, among active clients in `client-registry.json`; the client reads only IDs, names and revoked flags from it. Clients can be renamed, so scripts meant to last should use the ID or `--credentials-file`.
- `--credentials-file PATH` uses that key file.

`--params-file` must contain a JSON object under 30 KB. `--params-file -` reads it from stdin, which avoids a temporary file without putting parameters in argv. Key, parameter and registry files must be regular files owned by the current user with no group/other permissions; the client refuses unsafe files and symbolic links. The app must be running with its bridge enabled, the client must be enrolled, and macOS Full Access must be available for item operations. `--help` lists every command with the access it needs; `COMMAND --help` also lists its required and optional parameter keys. `client.py` runs `EVENTKIT_CLIENT_BINARY` when it's set, else `build/bridge-client`, else the copy inside `EKBridge.app` in `/Applications` or `~/Applications`; it exits with code 4 if there's none.

The response envelope is `{"version":2,"id":"…","ok":true,"result":{…}}` or `{"version":2,"id":"…","ok":false,"error":"code"}`. The client prints potentially private item titles and IDs; handle stdout accordingly. Reads wait up to 10 seconds and writes up to 60 seconds. A timeout is **not** proof that a write failed: read current state and reconcile before trying anything new.

Only the response JSON goes to stdout. Errors go to stderr as `error: …`, sometimes followed by an indented line that says what to do. When the bridge answers `ok:false`, stderr also gets one `hint: …` line from the same outcome map the app's Activity uses. Exit codes:

| Exit | Meaning | Example stderr |
| --- | --- | --- |
| 0 | ok | none |
| 1 | request denied or failed; JSON on stdout | `hint: Turn it on in the connection's Access, only if the tool should be able to do this.` |
| 2 | usage error | `error: unknown command "read_reminder". Did you mean read_reminders?`, `error: params must be a JSON object under 30 KB.`, `error: no active client named "…". Clients: …` |
| 3 | bridge unavailable | `error: EK Bridge isn't running, or the bridge is off. Turn it on from the menu bar.`, `error: the bridge session changed. Run the command again.` |
| 4 | missing or unsafe local file | `error: key file not found: …`, `error: … can be read by other users (mode 644).` |
| 5 | no response in time | `error: no response after 60 s. The write may still have happened.` |

The client can't tell "app not running" from "bridge off"; both print the exit 3 message. Outcome codes added in 0.4.0 are ordinary exit-1 results with a hint: `bridge_off` (EK Bridge is paused: it was turned off in the menu bar while the request was being handled), `rate_limited`, and `approval_denied` and `approval_timed_out` (the client is set to **Ask me first** and you declined or didn't answer within 45 seconds). The other new codes, `cancelled` and `timeout`, come only from MCP requests and show in Activity. 0.7.0 adds `client_paused` (exit 1): the client is paused in the app; its key still works once it's resumed. A write from a client set to Ask me first waits for the approval panel, which fits inside the client's 60-second write wait. In this reference, a **grant** is what the app calls **access**, and a **collection** is a calendar or reminder list.

## Commands

All parameter keys are case-sensitive; unknown keys are rejected. `start`, `end`, `at`, `alarmAt`, `occurrenceStart`, `occurrenceDue`, `dueAfter` and `dueBefore` are Unix seconds, not formatted date strings. Write timestamps are integers where the schema says integer. `calendarID`, `listID`, and `itemID` come from the app or an authorized read, never from a collection name alone. A request file may be up to 32 KB (30 KB of parameters); responses up to 1 MB.

| Command | Parameters | Required grant |
| --- | --- | --- |
| `authorization_status` | none | enrolled client |
| `scope_status` | none; returns this client's grants | enrolled client |
| `list_collections` | none; returns this client's granted collections with their current names and macOS access | enrolled client |
| `calendar_count`, `reminder_list_count` | none; count only granted collections visible to EventKit | enrolled client |
| `read_events` | `calendarID`, `start`, `end`, `limit`; optional `afterKey` | Calendar Read |
| `get_event` | `calendarID`, `itemID`; optional `occurrenceStart` | Calendar Read |
| `read_reminders` | `listID`, `limit`; optional `afterID`, `status`, `dueAfter`, `dueBefore` | Reminder Read |
| `get_reminder` | `listID`, `itemID` | Reminder Read |
| `create_event` | `calendarID`, `title`, `start`, `end`, `idempotencyKey`; optional `allDay`, `timeZone`, `notes`, `location`, `structuredLocation`, `url`, `alarms`, `availability`, `recurrence` | Calendar Create |
| `update_event` | `calendarID`, `itemID`, `expectedVersion`, `idempotencyKey`; at least one of `title`, `start`, `end`, `allDay`, `timeZone`, `notes`, `location`, `structuredLocation`, `url`, `alarms`, `availability`, `recurrence`, `targetCalendarID`; optional `occurrenceStart`, `span`, `replaceUnsupportedAlarms` | Calendar Edit (and Create on `targetCalendarID`) |
| `delete_event` | `calendarID`, `itemID`, `expectedVersion`, `idempotencyKey`; optional `occurrenceStart`, `span` | Calendar Delete |
| `create_reminder` | `listID`, `title`, `idempotencyKey`; optional `due`, `start`, `recurrence`, `notes`, `url`, `location`, `priority`, `alarms` | Reminder Create |
| `update_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey`; at least one of `title`, `due`, `start`, `recurrence`, `notes`, `url`, `location`, `priority`, `alarms`, `completed`, `targetListID`; optional `replaceUnsupportedAlarms` | Reminder Edit (and Create on `targetListID`) |
| `complete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey`; recurring completion adds `recurrenceScope`, `occurrenceDue`, `occurrenceFingerprint` | Reminder Complete |
| `delete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey`; `recurrenceScope:"series"` for a repeating reminder | Reminder Delete |

### Partial updates

`update_event` and `update_reminder` change only the keys present. An absent key keeps the current value; JSON `null` clears it (`notes`, `location`, `structuredLocation`, `url`, `alarms` and `availability` on events, where cleared availability is busy; `start`, `notes`, `url`, `location` and `alarms` on reminders); `{"kind":"none"}` clears a due date or a repeat rule, as before. `title`, `start`, `end`, `allDay`, `timeZone` and `recurrence` refuse `null`. An update with nothing to change returns `nothing_to_change`. Callers of 0.5 that always sent `title`, `start` and `end` keep working.

### Reads

`read_events` accepts a positive window of at most 31 days and `limit` 1–100. It returns `items` (one row per occurrence, sorted by start, then ID), `truncated`, and `nextCursor` when more rows remain; pass it back as `afterKey` with the same window. A page also stops early at about 180 KB of rows. Each row has `id`, bounded `title`, `titleTruncated`, `start`, `end`, `recurring`, `allDay`, `timeZone` (empty for a floating event), `hasAttendees`, `version`, and:

- `occurrenceStart` (the original start of this occurrence of a recurring event, else null), `detached` (changed on its own), and `recurrence` (the rule, below);
- `notesPreview` (first 300 bytes), `hasNotes`, `notesTruncated`, `location` (500 bytes), `locationTruncated`, `structuredLocation` (`{title, latitude, longitude, radius?}` or null), `url` with `urlSchemeAllowed`;
- `alarms` (up to 20, see below) and `alarmsTruncated`, `availability` (`busy`, `free`, `tentative`, `unavailable`, or null when the calendar has none), `status` (`none`, `confirmed`, `tentative`, `canceled`), `created`, `modified`, `externalID`;
- `attendeeCount`, `organizerIsYou`, `yourStatus`, and `editable`: `{"fields":…, "times":…, "recurrence":…, "reason": null | "read_only_calendar" | "invitation" | "floating_time" | "unsupported_recurrence"}`.

`get_event` returns one such row as `item`, with the full `notes` (up to 16,000 bytes), `organizer` and up to 200 `attendees` (`name`, `email`, `role`, `status`, `type`, `isYou`). Without `occurrenceStart`, a recurring event's first occurrence is returned.

`read_reminders` accepts `limit` 1–100 and returns `items`, `truncated`, and a `nextCursor` when more rows remain; `afterID` uses the previous cursor. `status` is `incomplete`, `completed` or `all` (the default for the command line; MCP agents default to `incomplete`). `dueAfter` and `dueBefore` keep reminders due in `[dueAfter, dueBefore)` and leave out reminders without a due date. Pages are not stable snapshots. Reminder rows include bounded title, `completed`, `completedAt`, `recurring`, `due`, `start`, `recurrence`, `alarms`, `alarmCount`, notes preview fields, `url`, `location`, `priority` (`none`, `low`, `medium`, `high`, or null) with `priorityRaw`, `created`, `modified`, `externalID`, and optional `version` and `completionCandidate`. `get_reminder` returns one row with the full `notes`.

`scope_status` returns `grants` rows with `resource` (`calendar` or `reminderList`), `targetID`, and integer `mask`. Mask bits are **Read=1, Create=2, Edit=4, Delete=8, Complete=16**; add the bits for the actions granted. Complete applies only to reminder lists. For example, mask 1 is read only; mask 3 is read plus create. These are this app's stored policy bits, not macOS TCC permission values.

`list_collections` returns one row per grant, in grant order, and never lists collections the client has no grant on:

```json
{"calendarsAccess":"full","remindersAccess":"denied","collections":[{"resource":"calendar","id":"…","name":"Work","account":"iCloud","writable":true,"available":true,"mask":3,"availabilities":["busy","free"]}]}
```

The access values are `full`, `not_determined`, `denied`, `write_only` and `restricted`. `name`, `account` and `writable` come from EventKit when the type has Full Access and lists the collection; otherwise the row has `available:false`, `name` and `account` null, and `writable:false`. Calendars add `availabilities`, the values events in them may use. The command needs no Full Access, like `scope_status`.

### Writes and verification

Writes require `idempotencyKey` in the form `ekb3_<current Unix seconds>_<lowercase UUID>`. Generate it once per intended write and reuse **the same key and exact parameters** for a retry. Keys expire seven days after their embedded timestamp (with five seconds of future skew). Edits, deletes, and completion require `expectedVersion` from a fresh read; a stale version returns `conflict`.

Every field a write sets is read back after saving. When the saved item doesn't match, a new item is removed (`<field>_readback_failed_rolled_back`, or `…_cleanup_needed` with `itemID` if removal fails) and an update is put back as it was (`…_readback_failed_restored`, or `…_restore_failed`, which means stop and check the item). `<field>` is the first that didn't match, such as `time_zone` or `alarms`.

A successful write returns an item receipt or `deleted:true`. Event receipts hold `id`, `version`, `calendarID`, `start`, `end`, `allDay`, `timeZone`, `recurring`, `occurrenceStart` for a recurring event, and `verified`, the fields read back and matched. Reminder receipts have the shape of a `read_reminders` row without the notes preview, plus `listID` and `verified`. A same-key retry of a completed write returns the recorded result with `"repeated":true`, so you can tell nothing was written twice. A new write can remain pending if EventKit or journal persistence is uncertain; do not replace its key merely to force another attempt. See [troubleshooting](TESTING.md#troubleshooting).

The write journal holds up to 10,000 entries in all and 2,000 live entries per client (entries expire with their key after seven days). A client over its share gets `journal_full` while others keep writing. Every client, command line or MCP, is also limited to 120 requests a minute (bursts of 30), 20 writes a minute (bursts of 10), 250 writes a day (counting only writes that were carried out, not refused or declined ones) and 8 requests in progress; past that, the result is `rate_limited`; wait before sending more. Requests from cloud agents through Remote Access have their own, stricter buckets (60 calls and 10 writes a minute) and share the daily cap and the 8 in progress with the client's other requests. (The CLI envelope carries only the code; MCP agents are told how many seconds to wait.)

## Events

### Times and time zones

For a timed event, `start` and `end` are Unix seconds (`end > start`, at most 31 days apart). The event is saved in `timeZone`, an IANA identifier macOS knows (or `UTC`); without it, the Mac's current zone. Versions before 0.6 saved every timed event in UTC; such an event can be moved to its real zone with `update_event` and `timeZone` alone, which keeps its instants. A recurring event keeps its occurrences at the same wall time in its zone across daylight saving changes.

For an all-day event, add `"allDay":true` and `timeZone`. `start` must be local midnight on the first day and `end` local midnight **after** the final day, both as Unix seconds, in `timeZone`; the range is 1–366 days. EventKit keeps every all-day event floating, without a zone, and reads its dates in the Mac's zone, so the bridge saves the same **dates** there and reads return `timeZone` empty; `timeZone` only says which zone the midnights were computed in. Reads return the end as 23:59:59 on the last day (EventKit's form); send the exclusive midnight as above. Existing all-day events can be updated and deleted, and `update_event` converts between kinds: `allDay:true` with midnight `start`/`end`, or `allDay:false` with timed `start`/`end`.

A floating event (a timed event without a zone) is readable, and every field but its times can change; `start`, `end`, `allDay` and `timeZone` return `floating_time_read_only`.

### Notes, location, URL and availability

- `notes`: at most 8,000 UTF-8 bytes; leading and trailing whitespace is kept. Text is stored in Unicode NFC; CR LF becomes LF; tab and newline are the only control characters accepted (`invalid_notes`, `notes_too_long`).
- `location`: one line, at most 500 bytes, trimmed. Setting it without `structuredLocation` removes an earlier map pin.
- `structuredLocation`: `{"title", "latitude" (−90…90), "longitude" (−180…180), "radius"?}` (meters, 1–100,000). EventKit keeps one value: the location text is the pin's title, so a `location` sent with it must equal the title (`invalid_location`). Clearing `location` clears it too.
- `url`: at most 2,048 bytes, `http`, `https`, `mailto` or `tel` only (`url_scheme_not_allowed`), and complete as given, without characters that need escaping (`invalid_url`). Reads return any URL, with `urlSchemeAllowed`.
- `availability`: `busy`, `free`, `tentative` or `unavailable`, only when `list_collections` shows it for the calendar (`availability_unsupported`).

### Alarms

`alarms` replaces every alarm with up to 5 distinct ones; there is no add-one form. Each is one of:

```json
{"kind":"relative","offset":-900}
{"kind":"absolute","at":1793887200}
{"kind":"location","location":{"title":"Home","latitude":40.7,"longitude":-74.0,"radius":150},"proximity":"arrive"}
```

A relative offset is in seconds from the event's start (from midnight for an all-day event), at most four weeks before and a day after. An absolute alarm must be in the future (`alarm_in_past`). `proximity` is `arrive` or `leave`; delivery of location alarms depends on the device (see the support matrix). Reads return every alarm, up to 20; an alarm the bridge can't express (a sound, an email, a script) reads as `{"kind":"unsupported","summary":…}` and an update that would replace it returns `alarms_unsupported` unless `replaceUnsupportedAlarms` is true.

### Recurring events

A rule (shared with reminders):

```json
{"kind":"rule","frequency":"monthly","interval":1,"weekdays":["2TU"],"end":{"kind":"count","count":10}}
```

| Key | Values | Rules |
| --- | --- | --- |
| `frequency` | `daily`, `weekly`, `monthly`, `yearly` | required |
| `interval` | 1–366 | default 1 |
| `weekdays` | 1–7 of `MO`…`SU`; monthly and yearly rules may add a number: `2TU`, `-1FR` (or `{"day":"TU","week":2}`) | not daily; weekly rules take plain codes |
| `monthDays` | 1–31 values in −31…−1, 1…31 | monthly; yearly with `months` |
| `months` | 1–12 values in 1…12 | yearly |
| `setPositions` | values in −366…−1, 1…366 | with `weekdays` or `monthDays` |
| `end` | `{"kind":"count","count":1–10000}` or `{"kind":"until","at":…}` | optional |

The first occurrence must be one of the rule's dates (`recurrence_anchor_mismatch`); for an event that's the start's date in its zone. `dayOfMonth` is still accepted for one release as `monthDays:[n]`. Reads add `rrule` (RFC 5545 text, for display) and `summary` ("Monthly on the second Tuesday, 10 times"), and `weekStart` when the rule has one (EventKit sets it; it can't be written). A rule the bridge can't represent (week numbers, days of the year, several rules) reads as `{"kind":"unsupported","supported":false,"summary":…}` and is never rewritten (`recurrence_unsupported`). Readback compares rules by their occurrences over the next 400 days, so a provider's equivalent normalization passes.

All occurrences share one `id` (iCloud gives an occurrence changed on its own an ID of its own, `<id>/RID=<n>`; rows report the series' `id`, and either form is accepted). To change or delete one, pass its `occurrenceStart` from a read (`occurrence_required` without it, `occurrence_not_found` when no occurrence started then) and a `span`:

| `span` | Effect |
| --- | --- |
| `this` (default) | Only this occurrence; it becomes detached. A rule change needs another span (`recurrence_span_invalid`). |
| `future` | This and later occurrences, split into a new series; the receipt's `id` is the new series'. |
| `all` | The whole series. A changed `start`/`end` moves every occurrence by the same amount. |

`span` on an event that doesn't repeat must be absent or `this` (`span_not_applicable`). Two different keys can't delete the same occurrence: the second gets `already_applied`.

### Invitations and moves

Events with attendees are read-only (`invitation_read_only`): changing a meeting can notify every attendee, and EventKit can't show that before saving. `update_event` with `targetCalendarID` moves an event to another calendar of the same account (`move_across_accounts_unsupported` otherwise); the client needs Edit on the source and Create on the destination, and a recurring event moves only with `span:"all"`.

## Reminder schedules

On `create_reminder`, omit `due` for an unscheduled item. EventKit keeps a due day floating (it reads back without its zone) and stores a start day as midnight; the bridge compares them by date. On `update_reminder`, omission preserves the existing due date; `{"kind":"none"}` clears it, with a start date equal to it and relative alarms. Supported due shapes:

```json
{"kind":"timed","at":1793887200,"timeZone":"America/New_York"}
{"kind":"all_day","date":"2026-11-05","timeZone":"America/New_York"}
```

`start` takes the same shapes (no alarm), or `null`/`{"kind":"none"}` to clear it. A new reminder's start defaults to its due date. When an update moves the due date, a start equal to the old due moves with it and a different start stays.

Alarms: `alarms` takes the list described for events; a relative offset counts from the due time and needs a due date (`alarm_requires_due`). The 0.5 single alarm stays for one release: on a new reminder, a timed due gets one alarm at the due time and a due day none, unless the due carries `"alarmAt":<seconds>` or `"alarmAt":null`; `alarmAt` and `alarms` can't be combined. When an update moves the due date without `alarms`, the alarms stay, and an alarm at the old due time follows it. A repeating reminder can only have relative alarms (`recurrence_requires_relative_alarm`); an alarm at the due time becomes relative when a rule is added. Ambiguous DST-fold instants are rejected rather than guessed. If EventKit returns a floating or ambiguous date, the readback reports that state; it is not silently converted to an absolute instant.

Other fields: `notes` and `url` follow the event rules. A reminder's location text can't be set through EventKit (the property is ignored), so `location` is read only; a location alarm names a place instead. `priority` is `none`, `low`, `medium` or `high`, stored as 0, 9, 5 and 1 (reads map 1–4 to high, 5 to medium, 6–9 to low). `completed:false` reopens a completed reminder; `completed:true` completes a reminder that doesn't repeat. `targetListID` moves it to another list of the same account, with Create there.

`recurrence` follows the event rule shape; a repeating reminder needs a due date matching its rule. A completed reminder's due date and rule don't change unless the same update reopens it.

A repeating reminder is deleted only as a whole series, with `recurrenceScope:"series"` (`recurrence_scope_required` without it); EventKit can't delete one occurrence of a reminder. It is completed one occurrence at a time with `complete_reminder`: read it first, and if the row has a `completionCandidate`, pass its fields (`recurrenceScope:"occurrence"`, `occurrenceDue`, `occurrenceFingerprint`) with the current `itemID` and `expectedVersion`. The bridge checks the account type and the rule's shape against the shapes a supervised probe has verified, makes one completion, and verifies one completed copy and the series advanced to the next due date. Today that's an iCloud reminder that repeats daily with a due time, no alarm and no end; other shapes and accounts return `recurrence_shape_unsupported` until the probe (`--synthetic-fields-probe`, see [Testing](TESTING.md)) verifies them. A same-key retry returns its recorded result; a second key for the same occurrence returns `occurrence_already_requested`. An uncertain result requires reconciliation, not an automatic new write. Un-completing a repeating reminder's completed occurrence returns `recurrence_uncomplete_unsupported`.

## Support matrix

| Operation | Repository default build | Observed live / limit |
| --- | --- | --- |
| Scoped reads with every field, `get_event`, `get_reminder`, paging, filters | Implemented | See [Testing](TESTING.md#bounded-live-observations) |
| Timed events in any IANA zone; all-day events up to 366 days; conversions | Implemented | Provider zone handling recorded per account (spike S1) |
| Notes, location, map pins, URL, alarms, availability on events | Implemented | iCloud live probe; map, link and location alert shown on iPhone. Location alarms firing on arrival: untested (S5) |
| Recurring events: create, read occurrences, `this`/`future`/`all` edits and deletes | Implemented | iCloud live probe: a `future` split gets a new series ID (S2) |
| Reminder notes, URL, priority, start, alarm lists, reopen, series delete | Implemented | iCloud live probe; the iPhone Reminders app shows priority, notes and location alerts, not the URL (S4) |
| Moves within an account | Implemented | iCloud live probe: IDs kept (S2) |
| Recurring reminder completion | Implemented for verified shapes (iCloud daily, timed, no alarm, no end) | Verified on this Mac and synced to an iPhone (S6); other shapes need the probe first |
| Invitation events (with attendees) | Read only | Edits as organizer: spike S3, a later release |

### Not possible through EventKit

| Item | Why |
| --- | --- |
| Adding, removing or changing attendees; inviting people | `EKParticipant` is read-only and has no public initializer. |
| Accepting or declining an invitation | No public EventKit API. |
| Attachments | Not exposed by EventKit. |
| Travel time | Calendar stores it in private properties. |
| A video-call link as a field | No property; use `url` or `notes`. |
| Event color | Belongs to the calendar, not the event. |
| Reminders: tags, subtasks, flags, sections, images, early reminders, "when messaging" | Reminders app features with no EventKit API. |
| A reminder's location text | `EKReminder` ignores it; use a location alarm. |
| A different location text and map pin on an event | EventKit keeps one value: the text is the pin's title. |
| Alarm sounds on iCloud | iCloud drops an alarm's sound; such alarms read back as plain alarms. |

## Synthetic example

Use an **empty temporary reminder list you created**, grant a disposable client only the needed actions for that list, and replace the two placeholders below. The client credential path is derived from the UUID shown by the app as described in the [user guide](USAGE.md#local-key-and-token-files). The script writes a private parameters file and creates one synthetic reminder with no due date or alarm. The test item may sync to other devices. **Run the generator once. Keep the parameters file and its exact key until the write outcome and cleanup are confirmed. A timeout may mean the item was created; do not generate a new key or repeat this recipe blindly.**

```sh
export EKB_TEST_LIST_ID='<ID of your empty temporary reminder list>'
export EKB_CREDENTIAL_FILE="$HOME/Library/Application Support/EKBridge/client-credentials/<lowercase client UUID>.json"
umask 077
EKB_PARAMS_FILE=$(mktemp /tmp/eventkit-create.XXXXXX)
export EKB_PARAMS_FILE
python3 - <<'PY'
import json, os, time, uuid
with open(os.environ['EKB_PARAMS_FILE'], 'w') as output:
    json.dump({
        'listID': os.environ['EKB_TEST_LIST_ID'],
        'title': 'EK Bridge synthetic test',
        'idempotencyKey': f'ekb3_{int(time.time())}_{uuid.uuid4()}',
    }, output)
PY
python3 client.py create_reminder \
  --credentials-file "$EKB_CREDENTIAL_FILE" \
  --params-file "$EKB_PARAMS_FILE"
```

Record `EKB_PARAMS_FILE` securely. If the client times out or reports an uncertain write, inspect the temporary list and reconcile the exact item before any retry; use the **same file and key** if a retry is appropriate. After confirmed creation, save the returned ID and version for exact-item cleanup with a separate fresh delete key. Remove the private parameters file only after the create and cleanup state are confirmed (`rm "$EKB_PARAMS_FILE"`). Do not run a broad delete. The app's **Remove Empty Test Collections** control only removes collections that it created and that are confirmed empty.

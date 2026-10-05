# Local CLI and command reference

`client.py` runs the matching Swift `build/bridge-client` on the **same Mac and macOS user** as the app. It reads a private credential file, signs a version-2 request, writes it to the bridge's private local file exchange, waits for a JSON response, and prints that response. There is no HTTP endpoint, cloud-to-localhost route, or MCP tool in this repository.

```sh
python3 client.py COMMAND --client 'NAME or ID' [--params-file '/private/path/parameters.json']
python3 client.py COMMAND --credentials-file '/private/path/client.json' [--params-file -]
python3 client.py --help
python3 client.py COMMAND --help
```

Brackets denote an optional argument; omit them when invoking it. Choose the key file with exactly one of:

- `--client NAME|ID` uses the app-managed key file for that client. An ID maps straight to `client-credentials/<id>.json`. A name is looked up, ignoring case and surrounding spaces, among active clients in `client-registry.json`; the client reads only IDs, names and revoked flags from it. Clients can be renamed, so scripts meant to last should use the ID or `--credentials-file`.
- `--credentials-file PATH` uses that key file.

`--params-file` must contain a JSON object under 8 KB. `--params-file -` reads it from stdin, which avoids a temporary file without putting parameters in argv. Key, parameter and registry files must be regular files owned by the current user with no group/other permissions; the client refuses unsafe files and symbolic links. The app must be running with its bridge enabled, the client must be enrolled, and macOS Full Access must be available for item operations. `--help` lists every command with the access it needs; `COMMAND --help` also lists its required and optional parameter keys. `EVENTKIT_CLIENT_BINARY` can point `client.py` at a matching `bridge-client` outside the default `build/` directory.

The response envelope is `{"version":2,"id":"…","ok":true,"result":{…}}` or `{"version":2,"id":"…","ok":false,"error":"code"}`. The client prints potentially private item titles and IDs; handle stdout accordingly. Reads wait up to 10 seconds and writes up to 60 seconds. A timeout is **not** proof that a write failed: read current state and reconcile before trying anything new.

Only the response JSON goes to stdout. Errors go to stderr as `error: …`, sometimes followed by an indented line that says what to do. When the bridge answers `ok:false`, stderr also gets one `hint: …` line from the same outcome map the app's Activity uses. Exit codes:

| Exit | Meaning | Example stderr |
| --- | --- | --- |
| 0 | ok | none |
| 1 | request denied or failed; JSON on stdout | `hint: Grant it in the client's Access, only if the tool should be able to do this.` |
| 2 | usage error | `error: unknown command "read_reminder". Did you mean read_reminders?`, `error: params must be a JSON object under 8 KB.`, `error: no active client named "…". Clients: …` |
| 3 | bridge unavailable | `error: EventKit Bridge isn't running, or the bridge is off. Turn it on from the menu bar.`, `error: the bridge session changed. Run the command again.` |
| 4 | missing or unsafe local file | `error: key file not found: …`, `error: … can be read by other users (mode 644).` |
| 5 | no response in time | `error: no response after 60 s. The write may still have happened.` |

The client can't tell "app not running" from "bridge off"; both print the exit 3 message. In this reference, a **grant** is what the app calls **access**, and a **collection** is a calendar or reminder list.

## Commands

All parameter keys are case-sensitive; unknown keys are rejected. `start`, `end`, `at`, `alarmAt`, and `occurrenceDue` are Unix seconds, not formatted date strings. Write timestamps are integers where the schema says integer. `calendarID`, `listID`, and `itemID` come from the app or an authorized read, never from a collection name alone.

| Command | Parameters | Required grant |
| --- | --- | --- |
| `authorization_status` | none | enrolled client |
| `scope_status` | none; returns this client's grants | enrolled client |
| `calendar_count`, `reminder_list_count` | none; count only granted collections visible to EventKit | enrolled client |
| `read_events` | `calendarID`, `start`, `end`, `limit` | Calendar Read |
| `read_reminders` | `listID`, `limit`; optional `afterID` | Reminder Read |
| `create_event` | `calendarID`, `title`, `start`, `end`, `idempotencyKey`; optional all-day fields described below | Calendar Create |
| `update_event` | `calendarID`, `itemID`, `expectedVersion`, `title`, `start`, `end`, `idempotencyKey` | Calendar Edit |
| `delete_event` | `calendarID`, `itemID`, `expectedVersion`, `idempotencyKey` | Calendar Delete |
| `create_reminder` | `listID`, `title`, `idempotencyKey`; optional `due`, `recurrence` | Reminder Create |
| `update_reminder` | `listID`, `itemID`, `expectedVersion`, `title`, `idempotencyKey`; optional `due`, `recurrence` | Reminder Edit |
| `complete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey`; narrow recurring completion adds `recurrenceScope`, `occurrenceDue`, `occurrenceFingerprint` | Reminder Complete |
| `delete_reminder` | `listID`, `itemID`, `expectedVersion`, `idempotencyKey`; optional `recurrenceScope` | Reminder Delete |

`read_events` accepts a positive window of at most 31 days and `limit` 1–100. It returns `items` with `id`, bounded `title`, `titleTruncated`, `start`, `end`, `recurring`, `allDay`, `timeZone`, and `version` when EventKit supplies one. If more than `limit` events match, it returns `too_many_events_narrow_range`; narrow the window rather than treating the partial scan as a complete result. `read_reminders` accepts `limit` 1–100 and returns `items`, `truncated`, and a `nextCursor` when more rows remain. `afterID` uses the previous cursor. Pages are not stable snapshots, and EventKit fetches the whole selected reminder list internally before this client pages it. Reminder rows include bounded title, `completed`, `recurring`, due, recurrence, alarm summary, and optional `version` and `completionCandidate`.

`scope_status` returns `grants` rows with `resource` (`calendar` or `reminderList`), `targetID`, and integer `mask`. Mask bits are **Read=1, Create=2, Edit=4, Delete=8, Complete=16**; add the bits for the actions granted. Complete applies only to reminder lists. For example, mask 1 is read only; mask 3 is read plus create. These are this app's stored policy bits, not macOS TCC permission values.

Writes require `idempotencyKey` in the form `ekb3_<current Unix seconds>_<lowercase UUID>`. Generate it once per intended write and reuse **the same key and exact parameters** for a retry. Keys expire seven days after their embedded timestamp (with five seconds of future skew). Edits, deletes, and completion require `expectedVersion` from a fresh read; a stale version returns `conflict`. A successful write returns an item receipt or `deleted:true`. A new write can remain pending if EventKit or journal persistence is uncertain; do not replace its key merely to force another attempt. See [troubleshooting](TESTING.md#troubleshooting).

## Event schedules

For a timed event, `start` and `end` are Unix seconds (`end > start`, maximum seven days). Creation sets UTC as the event time zone; the caller chooses the intended instants. `update_event` uses the same timed fields. Existing recurring, all-day, or attendee events cannot be updated or deleted here; updates also reject floating-time events.

For **all-day creation only**, add `"allDay":true`, a recognized IANA `"timeZone"`, and optionally nonempty `"notes"` (at most 2,000 UTF-8 bytes). `start` must be local midnight on the first day and `end` local midnight **after** the final day, both encoded as Unix seconds. The date range is 1–7 local days. The bridge checks saved dates, title, calendar, and notes before success. On one tested iCloud provider, EventKit read back the exclusive end as 23:59:59 on the final displayed day; the receipt also provides the requested `endExclusive`. This representation is provider-specific, not a license to subtract a second in requests.

For example, an all-day test event in a **temporary test calendar** can use this shape after calculating the two local-midnight timestamps and a fresh key. **The bridge cannot delete an existing all-day event**, including one it just created. Plan to remove that exact test event manually in Calendar or through another separately approved route, verify the calendar is empty, and only then remove the test collection:

```json
{
  "calendarID": "<temporary test calendar ID>",
  "title": "Synthetic all-day test",
  "start": 1793505600,
  "end": 1793595600,
  "allDay": true,
  "timeZone": "America/New_York",
  "notes": "Synthetic test item; safe to remove",
  "idempotencyKey": "<new ekb3 key>"
}
```

The example timestamps represent local midnight across a DST change; calculate timestamps for your actual test date instead of copying these values into a live request.

## Reminder schedules

On `create_reminder`, omit `due` for an unscheduled item. On `update_reminder`, omission preserves the existing due date and alarm; `{"kind":"none"}` explicitly clears both. Supported due shapes:

```json
{"kind":"timed","at":1793887200,"timeZone":"America/New_York"}
{"kind":"all_day","date":"2026-11-05","timeZone":"America/New_York"}
```

Timed due defaults to one alarm at due time. All-day due defaults to no alarm. Add `"alarmAt":<integer Unix seconds>` for an alert at another instant, or `"alarmAt":null` for none. A new alarm must be in the future. Due and start components are written together. Ambiguous DST-fold instants are rejected rather than guessed. If EventKit returns a floating or ambiguous date, the readback reports that state; it is not silently converted to an absolute instant. Changing a due date can be rejected when it would replace a complex alarm or unrelated start date.

On create or update, `recurrence` may be omitted (preserve existing rule on update), `{"kind":"none"}` (clear), or a rule:

```json
{"kind":"rule","frequency":"weekly","interval":1,"weekdays":["MO","WE"],"end":{"kind":"count","count":10}}
```

Frequency may be `daily`, `weekly`, `monthly`, or `yearly`; interval is 1–366. Weekly rules may specify 1–7 distinct weekday codes (`SU` through `SA`); monthly rules may specify `dayOfMonth` 1–31. Optional `end` is a count of 1–10,000 or `{"kind":"until","at":<integer Unix seconds>}`. A new recurring reminder needs a due date; weekday or month-day selectors must match its first due date. Adding recurrence to an existing reminder with an absolute alarm may require resending `due` so the bridge can establish a relative alarm. Provider notification delivery and sync remain separate from rule readback.

Nonrecurring reminders can be completed or deleted with the appropriate grant and fresh version. Recurring deletion is blocked. The **only** recurring completion path is one incomplete, timed, alarm-free, unbounded daily iCloud occurrence with a stable time zone and matching start/due components. The signed app must have a locally verified source ID pinned; the repository's `Info.plist` leaves this empty. Read an eligible reminder first, then pass its `completionCandidate` fields (`recurrenceScope:"occurrence"`, `occurrenceDue`, `occurrenceFingerprint`) plus current `itemID` and `expectedVersion`. The bridge checks the provider and fresh item/list state, makes one completion, and verifies a completed one-off item and the next incomplete daily item before success. A same-key retry returns its recorded result; a second key for the same original occurrence returns `occurrence_already_requested`. An uncertain result requires reconciliation, not an automatic new write.

## Support matrix

| Operation | Repository default build | Observed signed local build / limit |
| --- | --- | --- |
| Scoped reads; timed event CRUD | Implemented | Bounded live reads and synthetic writes exercised |
| All-day event creation with optional notes | Implemented | iCloud synthetic readback exercised; existing all-day edit/delete blocked |
| Reminder due/alarm and common recurrence create/update | Implemented | Synthetic local readback exercised; recurring notification delivery not established |
| Nonrecurring reminder complete/delete | Implemented | Synthetic operations exercised |
| One timed daily iCloud recurring occurrence completion | **Disabled** by empty source pin | Exercised only with a locally verified, signed source pin and synthetic item |
| Other recurring completion; recurring deletion | Blocked | Blocked by policy |
| Attendees, locations, subtasks, tags, arbitrary EventKit fields | Not exposed | No support claim |

## Synthetic example

Use an **empty temporary reminder list you created**, grant a disposable client only the needed actions for that list, and replace the two placeholders below. The client credential path is derived from the UUID shown by the app as described in the [user guide](USAGE.md#enroll-a-client). The script writes a private parameters file and creates one synthetic reminder with no due date or alarm. The test item may sync to other devices. **Run the generator once. Keep the parameters file and its exact key until the write outcome and cleanup are confirmed. A timeout may mean the item was created; do not generate a new key or repeat this recipe blindly.**

```sh
export EKB_TEST_LIST_ID='<ID of your empty temporary reminder list>'
export EKB_CREDENTIAL_FILE="$HOME/Library/Application Support/EventKitBridge/client-credentials/<lowercase client UUID>.json"
umask 077
EKB_PARAMS_FILE=$(mktemp /tmp/eventkit-create.XXXXXX)
export EKB_PARAMS_FILE
python3 - <<'PY'
import json, os, time, uuid
with open(os.environ['EKB_PARAMS_FILE'], 'w') as output:
    json.dump({
        'listID': os.environ['EKB_TEST_LIST_ID'],
        'title': 'EventKit Bridge synthetic test',
        'idempotencyKey': f'ekb3_{int(time.time())}_{uuid.uuid4()}',
    }, output)
PY
python3 client.py create_reminder \
  --credentials-file "$EKB_CREDENTIAL_FILE" \
  --params-file "$EKB_PARAMS_FILE"
```

Record `EKB_PARAMS_FILE` securely. If the client times out or reports an uncertain write, inspect the temporary list and reconcile the exact item before any retry; use the **same file and key** if a retry is appropriate. After confirmed creation, save the returned ID and version for exact-item cleanup with a separate fresh delete key. Remove the private parameters file only after the create and cleanup state are confirmed (`rm "$EKB_PARAMS_FILE"`). Do not run a broad delete. The app's **Remove Empty Test Collections** control only removes collections that it created and that are confirmed empty.

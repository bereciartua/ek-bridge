# Architecture and security boundary

## Components and data flow

```mermaid
flowchart LR
    U[Mac user in menu bar UI] -->|Full Access prompts; saved grants; bridge on/off| A[EventKitBridge.app]
    T[Authorized task running on this Mac] --> C[client.py and bridge-client]
    C -->|signed JSON request files| F[Private per-user /tmp session]
    F --> A
    A -->|grant, shape, TCC, version, journal checks| E[EventKit]
    E --> K[Calendar and Reminders accounts]
    A -->|bounded JSON response file| F
    F --> C
```

The app is a menu bar process in the logged-in user's session. `BridgeAppDelegate` owns the bridge and wires the UI. `BridgeAppModel` is the single source of truth for the menu bar extra (`StatusMenuController`), the main window (`MainWindowController`, SwiftUI views hosted in AppKit) and the setup checklist; it refreshes on app activation, EventKit changes, registry changes, bridge start/stop and new activity. `ClientRegistry` persists public verifiers and scopes, `LocalBridge` polls the local request directory, `EventKitCommands` performs authorized work, and `WriteJournal` records write identity and outcome. The matching Swift `bridge-client` is invoked by `client.py`. It reads a credential file locally and signs each request with Ed25519. A Python or shell task may call it **only if that task is executing on the Mac** with the user's authorization. There is no implemented MCP wrapper, cloud callback, HTTP server, network listener, or launchd Mach service.

`LocalBridge` uses `/tmp/eventkit-bridge-<uid>/`: an owned mode-0700 root, one active session with `requests/` and `responses/`, an owned lock file, and a `current.json` descriptor. Request/response files are mode 0600. The descriptor gives the local client a current session name, not an authorization secret. The bridge polls every 0.5 seconds; the client waits up to 10 seconds for reads or 60 seconds for writes. A process may be running while the Mac screen is locked, but actual reachability depends on the local task route, awake state, and logged-in session. A cloud agent cannot address this `/tmp` directory or `localhost` directly.

## Request checks

1. The client reads its private file and the current session descriptor, then signs the canonical JSON payload including session, request UUID, command, timestamp, parameters, and client ID.
2. The app validates exact envelope shape and size, the current session, timestamp lifetime (30 seconds, with five seconds of future skew), and replay UUID. The registry verifies the signature against the current public verifier and checks a saved grant for the exact collection and action.
3. `CommandPolicy` rejects unknown or malformed parameters before EventKit access. The app checks Full Calendar or Reminders access and target writability where needed. For asynchronous reads it rechecks the client revision, active bridge, and macOS access before replying.
4. Writes also pass idempotency, target, and expected-version checks. `WriteJournal` records a pending write before EventKit is asked to mutate data. A completed same-key retry may return the previous result. A pending or uncertain write needs reconciliation rather than automatic replay.

Grant edit, key rotation, or revocation changes the client's revision. Future requests and asynchronous reads that recheck it are denied; a write already committed by EventKit cannot be undone by a later policy change. A policy-store failure stops normal access. UI-created clients begin with zero grants; enabling the bridge alone grants no collection access. Once a grant exists, supported writes do **not** show a per-item approval sheet.

## Local state

| Location | Contents | Boundary |
| --- | --- | --- |
| `~/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json` | Ed25519 private signing seed and client UUID | App-managed, owned mode-0600 file in mode-0700 directory |
| `~/Library/Application Support/EventKitBridge/client-registry.json` | Schema version 3: public verifiers, names (unique among active clients), grant masks, revisions, revoke times, and the last 500 activity rows (time, client ID, command, outcome, target calendar or list ID) | Same-user local policy; no private seed |
| `~/Library/Application Support/EventKitBridge/client-registry.v2.backup.json` | One-time copy of a version 2 registry, written before the first version 3 write | Lets a user roll back to an older build; never overwritten |
| `~/Library/Application Support/EventKitBridge/write-journal.json` | Idempotency digests, high-water time, pending/completed write receipts, potentially including returned reminder titles | Reconciliation aid; not an EventKit transaction |
| `/tmp/eventkit-bridge-<uid>/` | Active session descriptor and private request/response files | Per-user local transport; no network access |
| User defaults, signed app bundle, macOS TCC | Saved bridge choice, window and Dock preferences, setup checklist and Activity "last viewed" state, optional verified source pin, privacy grants | Local installation state, not tracked source data |

Activity records omit keys, request parameters, titles, and item contents. They include the target calendar or list **ID** when the request named one; the app looks up the current name when it shows the row and never stores it. **The journal is different:** completed write receipts can include item IDs, reminder titles, and schedule summaries. Do not publish those files or raw diagnostic logs. `build/` is ignored and can contain signed binaries or local test output. The source `Info.plist` intentionally has an empty verified iCloud reminder source ID, so the special recurring-completion path fails closed in a default build.

## Threat model and limits

The file ownership checks, signatures, strict scopes, and grant revision help prevent accidental cross-client or cross-collection access through this protocol and keep other macOS user accounts out of the private exchange. They do **not** stop malicious code running as the **same macOS user**: that code can read a mode-0600 credential or alter the same-user registry. Code signing the app does not make that user account an isolated security principal. A task runner must apply its own authorization rules before invoking `client.py` on a specific user request.

The journal is not atomic with EventKit or cloud sync. A process exit after EventKit saves but before response persistence can leave an uncertain result. EventKit IDs and timestamps can change after provider sync, and different Calendar/Reminders providers can interpret all-day, due, recurrence, and alarm data differently. The app deliberately rejects shapes it cannot round-trip or safely mutate.

The [XPC design note](../Candidate/ARCHITECTURE.md) is historical source-only exploration. Its signed-peer idea is not the current transport; it does not by itself solve the same-user credential or signed-client deputy problem. Any switch to XPC, a persistent agent, an MCP adapter, Keychain storage, or per-process isolation needs a new threat review and separate implementation.

## Client registry versions

Version 3 (app 0.3.0) changes the registry in one step:

- Only active clients count toward the limit of 32. Revoked records are kept for history, capped at 200; when a revoke goes past the cap, the oldest revoked records are dropped first (records revoked before version 3 have no revoke time and go first).
- Clients can be renamed. The name isn't part of authorization, so renaming doesn't change the revision and requests in flight aren't affected. Names are unique among active clients, ignoring case and surrounding spaces, so `client.py --client NAME` is never ambiguous.
- Activity rows record the target calendar or list ID (same limits as grant targets: at most 512 bytes, no control characters).

A version 2 file loads unchanged and is written as version 3 on the next change, after a one-time backup to `client-registry.v2.backup.json` (mode 0600). **An older build fails closed on a version 3 registry** ("client settings can't be read"). To roll back, quit the app and restore the backup over `client-registry.json`; changes made since the upgrade are lost.

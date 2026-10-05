# EventKit Bridge

EventKit Bridge is a **local macOS menu bar app** that uses Apple's EventKit to work with Calendar and Reminders. A command-line client running as the same macOS user sends signed JSON requests through a private file exchange. The app checks macOS Full Access, the client's saved grant for a specific calendar or reminder list, request shape, and write safeguards before using EventKit.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.png">
  <img alt="EventKit Bridge Overview: the bridge is on, Calendars and Reminders have Full Access, and three clients are listed with their access and last request." src="docs/images/overview-light.png" width="720">
</picture>

This is a source project, not a packaged release. The repository is private. The code has no network listener, public API, cloud-to-localhost route, or implemented MCP server. A cloud task can use the bridge only through an authorized task actually running on the Mac; it cannot assume an offline, sleeping, or logged-out Mac is available.

## Start here

| Goal | Guide |
| --- | --- |
| Build and verify the source without installing it | [Setup and signing](docs/SETUP.md) |
| Enroll a client and use the app | [User guide](docs/USAGE.md) |
| Call the local CLI and understand command parameters | [API and CLI reference](docs/API.md) |
| Understand processes, file storage, and security limits | [Architecture and threat model](docs/ARCHITECTURE.md) |
| See what was tested and diagnose failures | [Testing and troubleshooting](docs/TESTING.md) |
| Continue development or prepare a public release | [Maintainer handoff](docs/MAINTAINING.md) |

The app needs macOS 14 or later. On the currently supported development machine, the scripts use the macOS 26.5 SDK from Command Line Tools. Building and offline tests do not install the app or request access:

```sh
sh test.sh
sh build.sh
```

The build creates `build/EventKitBridge.app` and `build/bridge-client`. It signs the app **ad hoc by default for build validation**. For persistent Calendar and Reminders permissions, choose a stable signing identity and follow [the installation guide](docs/SETUP.md) rather than treating an ad hoc build as an update to an installed app. `sh ui_test.sh` runs the window and behavior tests and `sh ui_snapshots.sh` writes screenshots of every screen; both use fake data.

## Quick start

These are the same steps as the setup checklist the app shows on first launch:

1. **Build and open the app** (see [Setup and signing](docs/SETUP.md)). Its window opens on the checklist; later, use the calendar icon in the menu bar.
2. **Allow Calendar and/or Reminders access.** You need only the one your tools use.
3. **Create a client** for each tool or script. It gets its own key file and starts with no access.
4. **Choose what the client can use:** which calendars and lists, and which actions (Read, Create, Edit, Delete, Complete). Then **Save**.
5. **Turn on the bridge and send a test request.** The client page has a ready-to-run command:

```sh
python3 client.py scope_status --client "Claude Code"
```

<img alt="A client page: Connect shows the client ID, key file path and a command to copy; Access shows calendars grouped by account with Read, Create, Edit and Delete checkboxes." src="docs/images/client-light.png" width="720">

`python3 client.py --help` lists every command and the access it needs. Errors say what's wrong and how to fix it, with a distinct exit code for each kind of problem ([API and CLI](docs/API.md)). The app's **Activity** pane shows every request with a plain explanation of its result.

## What works today

- The user chooses collections and Read, Create, Edit, Delete, or reminder Complete grants per client. New clients have zero grants. Saved grants persist until edited or revoked; the bridge itself is off until enabled locally.
- Reads return bounded event or reminder rows, not unrestricted access to the user's EventKit store. Reads of other collections are denied. Writes use an idempotency key; edits and deletes require the latest item version.
- Events support timed creation and edits, plus validated all-day **creation** with a named time zone and optional notes. Existing all-day or recurring events are conservatively blocked from edit and delete.
- Reminders support title, due date, alarm, common recurrence rules, and nonrecurring completion or deletion. One narrowly constrained daily iCloud recurring occurrence can be completed only when its source has been explicitly verified and pinned in the signed app. The repository's source pin is empty, so an ordinary source build fails closed for that operation. Other recurring completion and all recurring deletion are blocked.
- One window with Overview, Activity, each client and Settings; a menu bar icon that shows whether the bridge is on, off or needs attention; and a first-run checklist.
- The app can launch at login when the local user registers it. The user's bridge-enabled choice and client grants are local state, not repository content.

The [support matrix](docs/API.md#support-matrix) and [testing record](docs/TESTING.md) distinguish implemented behavior from provider-specific observations and untested cases.

## Security boundary

The bridge stores each client's Ed25519 signing credential in a mode-0600 file under the user's Application Support directory; the registry stores a public verifier and grants. Request and response files are owned by the user and have restricted permissions. **These controls do not isolate another process running as the same macOS user.** Such a process can access the credential or policy files. A grant is therefore a boundary between enrolled clients in this app's protocol, not a defense against a compromised user account. Do not put credentials, raw bridge traffic, personal event contents, or diagnostic logs in this repository.

The app's exact installed signing identity, macOS privacy grants, client credentials, collection IDs, and any locally pinned iCloud source ID remain outside source control. No installed service, login item, credential, or Calendar/Reminders data is created by `build.sh` or `test.sh`.

## Project status

Offline tests and bounded live tests have exercised the local bridge, UI, and synthetic EventKit items. A full Mac reboot followed by login was observed with the bridge running and authorized scoped reads working. Notification and provider synchronization behavior is not established for every recurrence shape, and the source has not been packaged or hardened for public distribution. See [testing and open checks](docs/TESTING.md).

This repository does not yet declare a public license or support policy. Its visibility, license, distribution signing, and public release remain owner decisions; [the handoff guide](docs/MAINTAINING.md) lists them without choosing for the owner.

# EventKit Bridge

EventKit Bridge is a **local macOS menu bar app** that uses Apple's EventKit to work with Calendar and Reminders. A command-line client running as the same macOS user sends signed JSON requests through a private file exchange. The app checks macOS Full Access, the client's saved grant for a specific calendar or reminder list, request shape, and write safeguards before using EventKit.

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

On the currently supported development machine, the scripts use the macOS 26.5 SDK from Command Line Tools. Building and offline tests do not install the app or request access:

```sh
sh test.sh
sh build.sh
```

The build creates `build/EventKitBridge.app` and `build/bridge-client`. It signs the app **ad hoc by default for build validation**. For persistent Calendar and Reminders permissions, choose a stable signing identity and follow [the installation guide](docs/SETUP.md) rather than treating an ad hoc build as an update to an installed app.

## What works today

- The user chooses collections and Read, Create, Edit, Delete, or reminder Complete grants per client. New clients have zero grants. Saved grants persist until edited or revoked; the bridge itself is off until enabled locally.
- Reads return bounded event or reminder rows, not unrestricted access to the user's EventKit store. Reads of other collections are denied. Writes use an idempotency key; edits and deletes require the latest item version.
- Events support timed creation and edits, plus validated all-day **creation** with a named time zone and optional notes. Existing all-day or recurring events are conservatively blocked from edit and delete.
- Reminders support title, due date, alarm, common recurrence rules, and nonrecurring completion or deletion. One narrowly constrained daily iCloud recurring occurrence can be completed only when its source has been explicitly verified and pinned in the signed app. The repository's source pin is empty, so an ordinary source build fails closed for that operation. Other recurring completion and all recurring deletion are blocked.
- The app can launch at login when the local user registers it. The user's bridge-enabled choice and client grants are local state, not repository content.

The [support matrix](docs/API.md#support-matrix) and [testing record](docs/TESTING.md) distinguish implemented behavior from provider-specific observations and untested cases.

## Security boundary

The bridge stores each client's Ed25519 signing credential in a mode-0600 file under the user's Application Support directory; the registry stores a public verifier and grants. Request and response files are owned by the user and have restricted permissions. **These controls do not isolate another process running as the same macOS user.** Such a process can access the credential or policy files. A grant is therefore a boundary between enrolled clients in this app's protocol, not a defense against a compromised user account. Do not put credentials, raw bridge traffic, personal event contents, or diagnostic logs in this repository.

The app's exact installed signing identity, macOS privacy grants, client credentials, collection IDs, and any locally pinned iCloud source ID remain outside source control. No installed service, login item, credential, or Calendar/Reminders data is created by `build.sh` or `test.sh`.

## Project status

Offline tests and bounded live tests have exercised the local bridge, UI, and synthetic EventKit items. A full Mac reboot followed by login was observed with the bridge running and authorized scoped reads working. Notification and provider synchronization behavior is not established for every recurrence shape, and the source has not been packaged or hardened for public distribution. See [testing and open checks](docs/TESTING.md).

This repository does not yet declare a public license or support policy. Its visibility, license, distribution signing, and public release remain owner decisions; [the handoff guide](docs/MAINTAINING.md) lists them without choosing for the owner.

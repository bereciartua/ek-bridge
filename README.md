# EventKit Bridge

EventKit Bridge is a **local macOS menu bar app** that uses Apple's EventKit to work with Calendar and Reminders. Tools on the same Mac reach it two ways: a command-line client sends signed JSON requests through a private file exchange, and AI agents (Claude Code, Codex, Claude Desktop, Cursor and others) connect to an optional **MCP server** on `127.0.0.1`. With optional **Remote Access**, cloud agents such as claude.ai, ChatGPT and Cursor's cloud agents reach that server through a tunnel you run. Either way, the app checks macOS Full Access, the client's saved grant for a specific calendar or reminder list, request shape, and write safeguards before using EventKit, and can ask you before each change.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.png">
  <img alt="EventKit Bridge Overview: the bridge is on, Calendars and Reminders have Full Access, and three clients are listed with their access and last request." src="docs/images/overview-light.png" width="720">
</picture>

This is a source project, not a packaged release. The repository is private. The only network listeners are the MCP server and Remote Access, both off by default and bound to the loopback address only. A cloud agent can reach the bridge only through Remote Access and a tunnel the user sets up, only for clients the user allowed, or through an authorized agent or task actually running on the Mac; it cannot assume an offline, sleeping, or logged-out Mac is available.

## Start here

| Goal | Guide |
| --- | --- |
| Build and verify the source without installing it | [Setup and signing](docs/SETUP.md) |
| Enroll a client and use the app | [User guide](docs/USAGE.md) |
| Connect an AI agent over MCP, or a cloud agent through Remote Access; tool reference | [MCP guide](docs/MCP.md) |
| Call the local CLI and understand command parameters | [API and CLI reference](docs/API.md) |
| Understand processes, file storage, and security limits | [Architecture and threat model](docs/ARCHITECTURE.md) |
| See what was tested and diagnose failures | [Testing and troubleshooting](docs/TESTING.md) |
| Continue development or prepare a public release | [Maintainer handoff](docs/MAINTAINING.md) |

The app needs macOS 14 or later. On the currently supported development machine, the scripts use the macOS 26.5 SDK from Command Line Tools. Building and offline tests do not install the app or request access:

```sh
sh test.sh
sh build.sh
```

The build creates `build/EventKitBridge.app` (with the MCP launcher `bridge-mcp` inside it) and `build/bridge-client`. It signs the app **ad hoc by default for build validation**. For persistent Calendar and Reminders permissions, choose a stable signing identity and follow [the installation guide](docs/SETUP.md) rather than treating an ad hoc build as an update to an installed app. `sh ui_test.sh` runs the window and behavior tests and `sh ui_snapshots.sh` writes screenshots of every screen; both use fake data.

## Quick start

These are the same steps as the setup checklist the app shows on first launch:

1. **Build and open the app** (see [Setup and signing](docs/SETUP.md)). Its window opens on the checklist; later, use the calendar icon in the menu bar.
2. **Allow Calendar and/or Reminders access.** You need only the one your tools use.
3. **Create a client** for each tool or script, with **Connects from ▸ Command line**. It gets its own key file and starts with no access. (For an AI agent, see below.)
4. **Choose what the client can use:** which calendars and lists, and which actions (Read, Create, Edit, Delete, Complete). Then **Save**.
5. **Turn on the bridge and send a test request.** The client page has a ready-to-run command:

```sh
python3 client.py scope_status --client "Claude Code"
```

<img alt="A client page: Connect shows the client ID, key file path and a command to copy; Access shows calendars grouped by account with Read, Create, Edit and Delete checkboxes." src="docs/images/client-light.png" width="720">

`python3 client.py --help` lists every command and the access it needs. Errors say what's wrong and how to fix it, with a distinct exit code for each kind of problem ([API and CLI](docs/API.md)). The app's **Activity** pane shows every request with a plain explanation of its result.

### Connect an AI agent

After steps 1 and 2 above, the checklist follows the same path for an agent:

1. **New Client…**: name it after the agent and choose **Connects from ▸ AI agent (MCP)**. The app creates a token file for it; the client has no access, and **Ask me before each change** is on.
2. **Choose access** in the client's Access table, then **Save**. Grant Read only on what the agent needs: what it reads goes to its AI provider.
3. **Turn on the bridge and the MCP server** (Settings ▸ MCP Server, or the checklist). The server listens on `http://127.0.0.1:47615/mcp`.
4. **Copy the setup** from the client's **Connect ▸ AI agent** tab: pick your agent and paste the command or config. The status line says **Connected** when the first request arrives.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/connect-agent-dark.png">
  <img alt="Connect ▸ AI agent on a client page: Claude Code is selected with the recommended direct HTTP method, a claude mcp add-json command to copy, a Connected status, a hidden token with Reset, and the server URL." src="docs/images/connect-agent-light.png" width="720">
</picture>

When the agent wants to change something, a small panel asks you first. You can turn that off per client.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/approval-panel-dark.png">
  <img alt="The Ask before changes panel: Claude Code wants to add a weekly event to Work in Europe/Madrid, with rows for when, repeats, where with a map pin, notes, the link with its host in bold, alerts and show as, Deny and Allow buttons, a 45-second countdown and a checkbox to allow changes for 15 minutes." src="docs/images/approval-panel-light.png" width="420">
</picture>

Setups for every supported agent, the tool reference and troubleshooting are in the [MCP guide](docs/MCP.md).

### Connect a cloud agent

Cloud agents run on their vendor's servers and can't reach `127.0.0.1`. **Remote Access** (Settings ▸ Remote Access, off by default) opens a second loopback port, 47616, for a tunnel you run, such as Tailscale Funnel; the app shows the commands and tests the result. Each client needs **Allow cloud access** on its page. Agents that send a header (the Anthropic and OpenAI APIs, Claude Code on the web, Cursor and Copilot cloud agents, Devin) use the client's separate remote token. claude.ai, ChatGPT and Gemini Enterprise sign in with OAuth, which you approve on the Mac by matching a six-digit code. See [Use from cloud agents](docs/MCP.md#use-from-cloud-agents).

## What works today

- The user chooses collections and Read, Create, Edit, Delete, or reminder Complete grants per client. New clients have zero grants. Saved grants persist until edited or revoked; the bridge itself is off until enabled locally.
- AI agents on the Mac use twelve MCP tools (`list_collections`, `read_events`, `get_event`, `create_event`, `update_event`, `delete_event`, `read_reminders`, `get_reminder`, `create_reminder`, `update_reminder`, `complete_reminder`, `delete_reminder`) with ISO 8601 times. Each agent sees only the tools its grants allow. **Ask before changes** can require your approval for every write, per client, and shows every field that would change.
- Reads return bounded event or reminder rows, not unrestricted access to the user's EventKit store. Reads of other collections are denied. Writes use an idempotency key; edits and deletes require the latest item version.
- Events support every field EventKit exposes: times saved in the time zone you choose (or the Mac's, never UTC by default), all-day events up to a year, notes, location with a map pin, URL, alarms (including arriving or leaving a place), availability, and repeat rules. Recurring events can be changed or deleted one occurrence at a time, from one occurrence on, or as a whole series. Attendees, the organizer and your response are readable; invitations stay read-only, because changing them can notify every attendee.
- Reminders support title, due and start dates, notes, URL, priority, several alarms (including location alarms), repeat rules, completing and reopening, moving between lists, and deleting a repeating reminder as a series. One occurrence of a repeating reminder can be completed for the shapes and account types a supervised probe has verified (today an iCloud daily reminder with a due time).
- Updates change only the fields they send, and every written field is read back: a mismatch removes a new item or puts an edited one back. Inviting people, answering invitations, attachments, travel time and the Reminders app's tags and subtasks aren't possible through EventKit.
- Cloud agents can use the same tools through Remote Access, a tunnel you run and a per-client **Allow cloud access** switch, with a separate remote token per client or OAuth connections you approve on the Mac. Remote Access is off by default, can turn itself off on a timer, and is one click to turn off from the menu bar.
- One window with Overview, Activity (which says whether each request came via MCP, Remote Access or the command line), each client and Settings; a menu bar icon that shows whether the bridge is on, off or needs attention, with a globe while Remote Access is on; and a first-run checklist.
- The app can launch at login when the local user registers it. The user's bridge-enabled choice and client grants are local state, not repository content.

The [support matrix](docs/API.md#support-matrix) and [testing record](docs/TESTING.md) distinguish implemented behavior from provider-specific observations and untested cases.

## Security boundary

The bridge stores each client's Ed25519 signing credential in a mode-0600 file under the user's Application Support directory; the registry stores a public verifier and grants.

The MCP server is **off by default**. When on, it listens only on `127.0.0.1:47615`, never on a network interface. Every request needs the client's own 256-bit token, kept in a mode-0600 file; the registry stores only its SHA-256 hash, and the recommended agent setups read the file instead of putting the token in the agent's config. Requests with a foreign `Host`, any `Origin` (web pages), or tunnel forwarding headers are refused, and repeated failed sign-ins are locked out. See the [threat review](docs/ARCHITECTURE.md#mcp-threat-review-040).

**Remote Access** is also off by default. While on, it listens on `127.0.0.1:47616` for a tunnel the user runs; every path except a 128-bit secret path gets 404, and only clients with **Allow cloud access** can use it, with a separate remote token or an OAuth connection the user approved on the Mac. Local tokens don't work through it, and its credentials don't work on the local port. Calendar data a cloud agent reads goes to that vendor, and tunnels other than Tailscale Funnel can read the traffic at their edge. See the [Remote Access threat review](docs/ARCHITECTURE.md#remote-access-threat-review-050). Request and response files are owned by the user and have restricted permissions. **These controls do not isolate another process running as the same macOS user.** Such a process can access the credential, token or policy files. A grant is therefore a boundary between enrolled clients in this app's protocol, not a defense against a compromised user account. Do not put credentials, raw bridge traffic, personal event contents, or diagnostic logs in this repository.

The app's exact installed signing identity, macOS privacy grants, client credentials, collection IDs, and any locally pinned iCloud source ID remain outside source control. No installed service, login item, credential, or Calendar/Reminders data is created by `build.sh` or `test.sh`.

## Project status

Offline tests and bounded live tests have exercised the local bridge, UI, and synthetic EventKit items. The MCP server, launcher, agent setups, Remote Access and its OAuth server have offline tests over real loopback sockets and a local HTTPS fixture; neither the live agent matrix nor the live cloud matrix has been run yet. A full Mac reboot followed by login was observed with the bridge running and authorized scoped reads working. Notification and provider synchronization behavior is not established for every recurrence shape, and the source has not been packaged or hardened for public distribution. See [testing and open checks](docs/TESTING.md).

This repository does not yet declare a public license or support policy. Its visibility, license, distribution signing, and public release remain owner decisions; [the handoff guide](docs/MAINTAINING.md) lists them without choosing for the owner.

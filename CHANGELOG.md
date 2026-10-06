# Changelog

Notable changes to EK Bridge, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `CFBundleShortVersionString` in `Info.plist`. Release notes come from this file, so each version says what callers and agents must change, and whether a client registry upgrade can be rolled back.

Versions up to 0.7.0 were built and used from source only; none was published as a download.

## [Unreleased]

**EventKit Bridge is now EK Bridge.** The new name comes with a new bundle ID, `io.github.bereciartua.ekbridge`, and a new app name, `EKBridge.app`. To macOS it's a different app, so this upgrade needs a few steps once ([Setup](docs/SETUP.md#upgrading-from-eventkit-bridge-070-or-earlier)):

- Open the new app next to the old one. It asks the old app to quit, moves `~/Library/Application Support/EventKitBridge` to `EKBridge` (leaving a link at the old path), and copies the settings. Clients, keys, tokens, grants, cloud connections and Activity move unchanged; the client registry stays at version 4.
- macOS asks for Calendar and Reminders access again, once; the setup checklist comes back for it.
- **Agents:** copy every agent's setup again from the client's **Connect ▸ AI agent**. The launcher is now `/Applications/EKBridge.app/Contents/MacOS/bridge-mcp`, the MCP server key and `serverInfo.name` are `ek-bridge` (tool names become `mcp__ek-bridge__…`; update allowlists), the token variables are `EK_BRIDGE_TOKEN` and `EK_BRIDGE_REMOTE_TOKEN` (Copilot: `COPILOT_MCP_EK_BRIDGE_TOKEN`), and the Cloudflare named tunnel is `ek-bridge`. Remove the old `eventkit-bridge` entries. Cloud agents keep their Remote Access address and credentials.
- **Command line:** install the command-line tool again from **Settings ▸ Developer**. `client.py` looks for `EKBridge.app`. The request folder moved from `/tmp/eventkit-bridge-<uid>` to `/tmp/ek-bridge-<uid>`, so an old `bridge-client` can't reach the new app. Key file paths under the old folder keep working through the link.
- Turn on **Settings ▸ General ▸ Start at login** again if you used it, then delete the old app.
- **Rolling back** to 0.7.0: quit EK Bridge, delete the `EventKitBridge` link and rename `EKBridge` back to `EventKitBridge`. The old app keeps its own settings and access.

### Added

- Apache-2.0 `LICENSE` and a `NOTICE` file, also inside the app (`Contents/Resources/`); the About panel names the license.
- `SECURITY.md`, `CONTRIBUTING.md`, issue and pull request templates, and this changelog.
- The command-line client ships inside the app at `Contents/MacOS/bridge-client`, signed with it. **Settings ▸ Developer ▸ Install Command-Line Tool** links it into `~/.local/bin` (no administrator password), and the app's copied commands then start with `bridge-client` instead of `python3 client.py`.
- Universal builds: `EVENTKIT_ARCHS="arm64 x86_64" sh build.sh` builds the app, `bridge-mcp` and `bridge-client` for Apple silicon and Intel.
- Continuous integration on pull requests and `main` (`sh test.sh` and a universal `sh build.sh`), and `scripts/check_bundle.sh` and `scripts/check_version.sh` for releases.

### Changed

- Renamed to EK Bridge, as above. The MCP `_meta` key that names the client is `io.github.bereciartua.ekbridge/client`, and the CIMD fetch's User-Agent is `EKBridge/<version>`. Synthetic probe collections are named "EK Bridge …". The `ekb_*` and `ekb3_` prefixes and the `EVENTKIT_*` build variables are unchanged.
- `build.sh` and `test.sh` use the SDK `xcrun` selects, or `EVENTKIT_SDK`, instead of a fixed path. With Command Line Tools alone they use the macOS 26 SDK, because SwiftUI's macros in the macOS 27 SDK need Xcode.
- `bridge-client` is built for macOS 14 like the app. It used to be built for the macOS version of the Mac that built it.
- `build/bridge-client` is a link to the copy inside the built app.
- `client.py` uses `EVENTKIT_CLIENT_BINARY` when set, else `build/bridge-client`, else the installed app's copy in `/Applications` or `~/Applications`. Run directly, the client's help and errors call it `bridge-client`.
- The README starts with installing, and has Privacy and Uninstall sections.

### Fixed

- **Start at login** could not be turned on in a copy that had never been registered as a login item, such as every first install and the first launch after the rename: macOS reports that state as "not found", which disabled the switch. Only the install location disables it now.

### Removed

- `Candidate/`, the signed XPC design that was never used, and its test. It stays in the git history. The OpenAI tunnel spike note moved to `docs/history/`.
- The synthetic source check's fixed client and list names: `--synthetic-source-check` now takes `--synthetic-client NAME --synthetic-list TITLE`.

## [0.7.0] - 2026-10-06

App 0.7.0 adds **Pause Client** and **Resume Client**: a paused client keeps every credential, grant and setting, and every request from it is refused with the new outcome code `client_paused` (in `OutcomePresentation` and `AgentOutcomeText`; Activity shows **Client was paused**). The client registry stays at **version 4**: clients gain the optional `paused` and `pausedAt` fields, and no backup is written. **Rolling back to 0.6.0** keeps working but ignores the fields: paused clients are active again, and the old build's next write drops the fields for good. Resume or revoke paused clients before rolling back if that matters. Callers see `client_paused` only while a client is paused; scripts that treat any `ok:false` as a failure need no change.

## [0.6.0] - 2026-10-05

App 0.6.0 adds every EventKit field on events and reminders. The client registry stays at **version 4** and no grant actions were added; `get_event` and `get_reminder` need Read, and a move needs Edit on the source and Create on the destination. What changes for callers:

- **Time zones.** A timed event is saved in the requested `timeZone`, or the Mac's, instead of UTC. Events created by older versions stay in UTC until an update with only `timeZone` moves them (their instants don't change).
- **Partial updates.** `update_event` and `update_reminder` no longer need `title`, `start` and `end`; absent keeps, `null` clears. Old callers that always send them keep working. Moving a reminder's due date now keeps its alarms (one at the old due time follows it) instead of resetting them to the default.
- **CLI results.** Event and reminder rows gain the fields in [API](docs/API.md#reads); `read_events` pages with `nextCursor`/`afterKey` instead of failing with `too_many_events_narrow_range` (kept only for ranges with more than 20,000 events); reminder recurrence uses `monthDays` (0.5's `dayOfMonth` is accepted on input for one release); receipts gain `verified`. Requests may be 32 KB. `read_reminders` keeps returning every reminder unless `status` is given.
- **MCP results.** See the breaking changes in [MCP](docs/MCP.md#tools): `editable` is an object, event times carry the event's own offset, `verified` is a list, alarms use `minutes_before`, recurrence uses `month_days` and `end`, and `read_reminders` defaults to open reminders. Agents re-read the tool list when they reconnect.
- **Recurring reminder completion** uses an account-type and rule-shape allowlist (`RecurringReminderCompletion.verifiedShapes`) instead of a source ID pinned in `Info.plist`. Extend the allowlist only with shapes a supervised probe verified ([Testing](docs/TESTING.md#plan-03-live-probe-spikes-s1s6)).
- **Retired codes.** `all_day_or_attendees_unsupported`, `recurrence_delete_unsupported`, `complex_start_unsupported`, `complex_alarm_unsupported`, `floating_time_unsupported` and `recurrence_requires_alarm_reset` are no longer returned; their texts stay for journal replays of older results.

## [0.5.0] - 2026-10-05

App 0.5.0 adds Remote Access. The client registry stays at **version 4**: clients gain `remoteEnabled`, `remoteVerifier` and `remoteIssuedAt`, and Activity rows may have `via: remote`. 0.4.0 was never released on its own, so no version 5 or new backup was needed (the plan had called these fields v5). OAuth connections live in a new file, `remote-connections.json`. Remote Access is off until you turn it on, and every client starts without cloud access. Nothing changes for the CLI or local agents. See [Use from cloud agents](docs/MCP.md#use-from-cloud-agents).

## [0.4.0] - 2026-10-05

App 0.4.0 writes client registry **version 4** (MCP token digests, Ask before changes, `via` and agent in Activity). The first version 4 write keeps a one-time copy of the file it read as `client-registry.v3.backup.json` (or `client-registry.v2.backup.json` from a version 2 file). **0.3.x fails closed on version 4** ("client settings can't be read"). To roll back: quit the app, restore the backup over `client-registry.json`, and accept that changes made since the upgrade are lost, including every client's MCP access. See [Architecture](docs/ARCHITECTURE.md#client-registry-versions).

Existing clients keep their keys and grants and are set to *Allow without asking*. The MCP server is off until you turn it on. The write journal grows to 10,000 entries with a per-client quota, stored as one file per client in `write-journal/`; entries already in `write-journal.json` stay there and count toward the total only. CLI results gain `hasAttendees` on event rows, `completed` and `recurring` on reminder receipts, and `repeated` on journal replays, plus the `list_collections` command; scripts that ignore unknown keys keep working.

## [0.3.0] - 2026-10-05

App 0.3.0 writes client registry **version 3**. An older build fails closed on it ("client settings can't be read"). The first version 3 write keeps a one-time copy of the version 2 file as `client-registry.v2.backup.json`; to roll back, quit the app and restore that file over `client-registry.json` (changes made since the upgrade are lost). See [Architecture](docs/ARCHITECTURE.md#client-registry-versions).

The Controls, Clients & Permissions and Activity windows are replaced by one window. `client.py` failures now have specific messages and exit codes (see [API](docs/API.md)); scripts that only checked for a non-zero exit keep working.

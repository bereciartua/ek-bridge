# Changelog

Notable changes to EK Bridge, newest first, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. Versions follow `CFBundleShortVersionString` in `Info.plist`. Release notes come from this file, so each version says what callers and agents must change, and whether a client registry upgrade can be rolled back.

Versions up to 0.7.0 were built and used from source only; none was published as a download.

## [Unreleased]

### Added

- **Pause EK Bridge ▸ For 1 Hour / Until Tomorrow / Until I Turn It On** in the menu bar. A timed pause turns EK Bridge back on by itself (8:00 the next morning for Until Tomorrow), and Overview and the menu say until when.
- **Add a Connection** sheet: a tile per agent (agents found on this Mac first, marked **Installed**), a name filled in from it, and a **Starting access** (read everything, read everything and change one calendar or list, or nothing yet), so a new agent doesn't start from a blank grid. It replaces New Client and its Connects from choice.
- Access presets you can see: each column header in the access table has **Turn On for All** / **Turn Off for All** (for the rows shown), and each row has a **⋯** button with Read Only, Full Access and No Access.

### Changed

- The app calls clients **connections** (sidebar, menus, Activity, Settings), and the master switch reads **EK Bridge is on** / **EK Bridge is paused**. The CLI, the API, file names and `--client` keep "client".
- One switch: the local MCP server runs whenever EK Bridge is on and a connection uses MCP, and stops when you pause it. There's no MCP step in setup; **Settings ▸ Advanced ▸ Local MCP server** turns it off for a Mac where no agent should connect. Upgrading keeps it running if it was on or a connection uses MCP. Overview and the menu bar say **MCP on port 47615**, and agents, `bridge-client` and `bridge-mcp check` say EK Bridge is paused instead of off.
- The menu bar menu is reordered: the switch and Pause, the MCP and Remote Access lines, **Needs you** (approvals, problems, an update), then **Recent changes**, which lists only adds, edits, completions and deletes.

## [0.8.3] - 2026-10-08

A polish release: Activity's columns fit, Overview's client rows agree with themselves, a delete EK Bridge can't show is never the default, the menu bar shows the day-arc icon, the app offers to move itself to Applications, and unavailable calendars keep their names. Nothing changes for agents or scripts. The client registry stays at **version 4**, so going back to 0.8.2 means installing its DMG over this one; 0.8.2 ignores the new `collection-labels.json`.

### Added

- **Move to Applications.** Opened from Downloads, another folder or the disk image, EK Bridge asks once whether to move itself to Applications (with **Don't ask again**), and the "isn't in Applications" warnings, now one shared notice, offer **Move to Applications…**. It copies itself, checks the copy's signature against its own developer team, removes the quarantine flag, relaunches from Applications after any change waiting in the approval panel is answered, then moves the old copy to the Trash or offers to eject the disk image. An EK Bridge already in Applications goes to the Trash first, unless it's running.
- **Unavailable calendars keep their names.** EK Bridge now keeps the name, account and colour of each calendar and list a client has access to (`collection-labels.json`, mode 0600, nothing else). When one stops being listed (an account signed out, say), the review sheet shows "Project calendar (Exchange)" and "Not available since Oct 5", with the ID in a tooltip and **Copy ID**; the access banner and summaries name it too. A label is removed with the last access to its calendar or list. Older versions ignore the file.
- **Help menu links**: **EK Bridge Help**, **Set Up an AI Agent**, **Release Notes**, **Ask a Question…** (Discussions) and **Report an Issue…**, above **Show Setup Checklist**. Settings ▸ About has the same links.
- **⌘3** opens Settings (View menu), and **Find…** (**⌘F**, Edit menu) opens Activity with the cursor in its search field.
- **EK Bridge Test, a live-test copy for maintainers** (`sh scripts/live_test.sh`, [details](docs/TESTING.md#live-test-copy)). Built with `EVENTKIT_LIVE_TEST=1`, it has its own bundle ID, data folder, `/tmp` folder, ports (47625 and 47626) and MCP server key, refuses to start if any of them is the installed app's, and is driven through an automation channel that release builds never contain (`scripts/check_bundle.sh` checks). It creates, grants and removes only calendars and lists named "EK Bridge Test · …". Nothing changes in the released app.

### Changed

- **The menu bar icon is the app icon's day arc** instead of a calendar symbol, drawn as a template image in three states: on, paused (faded, with a pause sign) and needs attention (with a dot). The pending-change count, the Remote Access globe and the accessibility label are unchanged.

### Fixed

- **Activity's columns fit.** The Result column is as wide as the longest result ("Not approved in time"), so no result is cut off at the default or the minimum window size; Request keeps its labels whole at the default size ("List calendars" and "macOS access" are shorter in the table, the full name is in the tooltip); Client and Calendar or list share the rest and end in "…" with the full name in the tooltip. Times from earlier this year read "Oct 5" instead of "Oct 5, 2026", and at the minimum window size the filters move under the title instead of pushing the table out of the window.
- **Overview's client rows agree with themselves.** Each row shows its last request once (the agent's name and version no longer repeat the time), "Waiting for the agent…" shows only until the client's first request by any transport, and the access summary names only actions a calendar or list allows: a read-only calendar saved with Create reads "US Holidays: read", with an orange warning whose tooltip says some access can't apply.
- **A delete EK Bridge can't show is no longer the default.** When the item an agent wants to delete doesn't load, the approval panel says "EK Bridge can't show what will be deleted." with the item's ID (shortened, the full one in the tooltip), **Deny** is the default button (Return and Escape both deny), and deleting takes a click on **Delete Anyway**, after the same half-second arming.
- The approval panel fits its height to each change as you step through the queue; a taller change could cut off its buttons.
- A client with cloud access no longer shows a whole Cloud card while Remote Access is off: one line says cloud agents can't reach this Mac, with a **Remote Access…** link.
- Finished setup steps are no longer struck through: they collapse to one quiet line that says what happened ("Calendar access allowed", "Client created"), with a smaller check mark and their value on the right.
- Claude Desktop's setup had two **Show in Finder** buttons with different targets. The config one is now **Show Config File in Finder** and selects the file itself when it exists; the one under the Applications warning reads **Show EK Bridge in Finder**.
- Clearer words: the New Client sheet no longer repeats that a new client has no access; the setup checklist's optional access steps say "Skip it if your tools only use reminders" (or calendars); its last step, before any client exists, says to connect your agent and ask it something; a setup with a single step isn't numbered "1."; and a client without write access shows "Changes: none allowed. Ask me first applies once you allow a change." instead of a disabled picker, following the access you're editing.
- `ui_snapshots.sh` waits until each window has stopped moving before capturing it, and fails if any capture is under 400 pixels wide; its first captures used to catch the window still opening.

## [0.8.2] - 2026-10-07

Copied command-line commands now work as pasted in a downloaded copy, and every release also ships its disk image as `EKBridge.dmg`, so [one link](https://github.com/bereciartua/ek-bridge/releases/latest/download/EKBridge.dmg) always downloads the newest version. Nothing changes for agents or for existing scripts, and the client registry stays at **version 4**, so going back to 0.8.1 means installing its DMG over this one.

### Added

- Each release also carries its disk image as **`EKBridge.dmg`**, a name that's the same in every release, so [`releases/latest/download/EKBridge.dmg`](https://github.com/bereciartua/ek-bridge/releases/latest/download/EKBridge.dmg) always downloads the newest version. `scripts/release_assets.sh` makes the copy and writes `SHA256SUMS` for both DMG names and the zip; the versioned `EKBridge-<version>.dmg` stays for the Homebrew cask and older links.

### Changed

- The README opens like a product page: the icon, a one-line pitch, badges, a Download link, the Overview screenshot, three reasons to use it and the agents it has setups for. Three new sections follow the setup steps: **What you can ask** (example prompts and the tools they use), **How it works** (what's checked, the safeguards, and what it doesn't protect against) and a short **FAQ**. Nothing was removed.

### Fixed

- **A copied command now works as pasted in a downloaded copy.** The client page and the setup checklist offered `python3 client.py …`, "in the ek-bridge folder", unless the command-line tool was installed in `~/.local/bin`, which works only in a source checkout. They now copy `bridge-client …` when `bridge-client` runs this copy of the app (installed from Settings ▸ Developer or linked by Homebrew's cask), else the app's own copy by its full path, `/Applications/EKBridge.app/Contents/MacOS/bridge-client …`. Settings ▸ Developer says when Homebrew already linked it.

## [0.8.1] - 2026-10-07

The first update that installed copies of 0.8.0 get through **Check for Updates…**. Nothing changes for callers or agents, and the client registry stays at **version 4**, so going back to 0.8.0 means installing its DMG over this one.

### Added

- A Homebrew cask: `brew install --cask bereciartua/tap/ek-bridge` installs the release DMG's app and links `bridge-client` into Homebrew's `bin`. The cask lives in [`bereciartua/homebrew-tap`](https://github.com/bereciartua/homebrew-tap), which updates it after each release once the DMG's build attestation and checksum check out.
- An entry in the official [MCP Registry](https://registry.modelcontextprotocol.io), `io.github.bereciartua/ek-bridge` (`server.json`), published by `.github/workflows/mcp-registry.yml` when a release is published, with GitHub's OIDC token instead of a stored secret. `scripts/check_version.sh` checks that its version matches `Info.plist`.

### Changed

- A new app icon: the sun's path across a day over a dawn-cream tile, replacing the calendar page with a bridge, which read as Apple's Calendar icon at Dock size. The small sizes in Finder lists use a simpler drawing so they stay readable. On macOS 26 and later it's an Icon Composer icon, so it follows the system's Liquid Glass look and the Dark, Clear and Tinted icon styles.

## [0.8.0] - 2026-10-06

**The first public release.** EK Bridge is open source under the Apache License 2.0, and it ships as a universal (Apple silicon and Intel) download, signed with a Developer ID and notarized by Apple, that keeps itself up to date: it checks GitHub once a day and installs a new version when you click. The client registry stays at **version 4**, so rolling back to 0.7.0 keeps working (see the end of this list). Remote Access is labeled Experimental until its live cloud checks have run.

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
- **In-app updates** with [Sparkle](https://sparkle-project.org) 2.10.0, embedded in the app (`Contents/Frameworks`, without its XPC services) and signed with it. Once a day, and from **Check for Updates…** in the app and menu bar menus or **Settings ▸ General**, the app reads `appcast.xml` from the latest GitHub release. A scheduled check never opens a window: a found update shows as **Update Available** in the menu bar menu and a card on Overview, and Sparkle's window, with the release notes, opens when you pick one. Installing always takes a click. Before installing, Sparkle checks the download's EdDSA signature against the app's `SUPublicEDKey` and that the new app is signed by the same team; the app waits for changes in the approval panel to be answered (45 seconds at most), then quits as usual and restarts at the same path, so access, clients and agent setups stay. **Settings ▸ General ▸ Check for updates automatically** (also in the setup checklist) turns the daily check off; a copy built from source has no key and never checks. Sparkle's license is in `NOTICE` and `Contents/Resources/Sparkle-LICENSE.txt`.
- `scripts/update_test.sh`: the Sparkle update, end to end, without GitHub. It builds two copies of a separate "EK Bridge Update Test" app (its own bundle ID, data folder and `/tmp` folder), serves a feed signed with a throwaway key on `127.0.0.1`, and checks that 0.0.1 updates itself to 0.0.2.
- The release pipeline ([Maintaining](docs/MAINTAINING.md#releasing)): `release.sh` runs the tests, builds the universal app signed with a Developer ID and a secure timestamp, notarizes and staples the app and a DMG, builds the zip Sparkle will install from, writes `SHA256SUMS` and, given a Sparkle key, `appcast.xml`, and creates a draft GitHub release with notes from this changelog. `.github/workflows/release.yml` runs it on a `v*` tag in the protected `release` environment with build attestations. `scripts/check_notarized.sh` checks Gatekeeper's verdict and the staple; `Tests/release_test.py` covers the tools and the script's refusals.

### Changed

- Renamed to EK Bridge, as above. The MCP `_meta` key that names the client is `io.github.bereciartua.ekbridge/client`, and the CIMD fetch's User-Agent is `EKBridge/<version>`. Synthetic probe collections are named "EK Bridge …". The `ekb_*` and `ekb3_` prefixes and the `EVENTKIT_*` build variables are unchanged.
- `build.sh` and `test.sh` use the SDK `xcrun` selects, or `EVENTKIT_SDK`, instead of a fixed path. With Command Line Tools alone they use the macOS 26 SDK, because SwiftUI's macros in the macOS 27 SDK need Xcode.
- `bridge-client` is built for macOS 14 like the app. It used to be built for the macOS version of the Mac that built it.
- `build.sh` requests a secure timestamp when signing with a real identity (notarization requires one). It downloads the pinned Sparkle once into `build/vendor` (`scripts/sparkle.sh`, checked against its SHA-256; `EVENTKIT_SPARKLE_ARCHIVE` for builds without network access). Ad hoc builds may load Sparkle without library validation, which needs a team; Developer ID builds keep it, and `scripts/check_bundle.sh` checks that.
- `release.sh` requires `EVENTKIT_SPARKLE_KEY_FILE` for a release once `Info.plist` has `SUPublicEDKey`, so every release has an `appcast.xml`, and checks the zip's signature against that key before going on (`scripts/verify_update_signature.swift`).
- `build/bridge-client` is a link to the copy inside the built app.
- `client.py` uses `EVENTKIT_CLIENT_BINARY` when set, else `build/bridge-client`, else the installed app's copy in `/Applications` or `~/Applications`. Run directly, the client's help and errors call it `bridge-client`.
- The README starts with installing, and has Privacy and Uninstall sections.

### Fixed

- Pairing an OAuth cloud agent could fail with a network error when the server holding the agent's client metadata closed the connection abruptly (without TLS close_notify) right after replying: the request's send completion reported the close before the reply was read. The read now reports the outcome. The fetch also no longer resumes TLS sessions, so every fetch evaluates the server's certificate in full.
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

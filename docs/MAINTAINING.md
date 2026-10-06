# Maintaining

This guide is for maintainers: where the code lives, how a change is made and released, and what's still open. Contributors start with [CONTRIBUTING](../CONTRIBUTING.md). The project is licensed under Apache-2.0; release notes live in the [changelog](../CHANGELOG.md).

## Repository map

| Path | Responsibility |
| --- | --- |
| `Sources/main.swift` | App delegate: bridge start/stop, MCP service, Remote Access service, OAuth server and approval panel wiring, CLI request authentication, main menu |
| `Sources/BridgeAppModel.swift` | UI state and actions shared by the menu bar, the window and the setup checklist |
| `Sources/StatusMenuController.swift`, `Sources/MainWindowController.swift` | Menu bar extra; the one main window, its unsaved-changes guard and Dock policy |
| `Sources/MainView.swift`, `OverviewView.swift`, `ClientDetailView.swift`, `ActivityView.swift`, `SettingsView.swift`, `UIComponents.swift` | SwiftUI views hosted in AppKit (the New Client sheet and port sheet live in `ClientDetailView.swift`; Settings ▸ MCP Server in `SettingsView.swift`) |
| `Sources/RemoteAccessView.swift`, `Sources/RemoteAccessSupport.swift` | Remote Access UI: the Settings card and tunnel guide, the client page's Cloud section, the pairing sheet, the OAuth client sheet (Gemini Enterprise), and the address and port sheets; the keep-awake power assertion and the **Test** probe |
| `Sources/AgentSetup.swift`, `Sources/ConnectAgentView.swift` | Agent catalog and the pure snippet generator for every agent and method, plus the cloud agents (`CloudAgentKind`) and tunnel guides (`TunnelProvider`, which also names the tunnel from request headers); the Connect ▸ AI agent tab (picker, method, snippet, status, token actions) |
| `Sources/ApprovalCenter.swift`, `Sources/ApprovalPanel.swift` | Ask before changes: the pending queue, 45 s timeouts, 3 per client, 15-minute allowances; the non-activating panel and the summaries it shows |
| `Sources/AppIdentity.swift`, `AppPresentation.swift`, `OutcomePresentation.swift` | Product name, display formatting, setup checklist logic, outcome labels and fixes (shared with the CLI) |
| `Sources/RenameMigration.swift` | The one-time move from the EventKit Bridge identity (0.7.0 and earlier): data folder, settings, the Overview notice ([details](#the-rename-migration)) |
| `Sources/UIReview.swift` | `EVENTKIT_UI_REVIEW=1` builds only: fake data, snapshots, window and behavior tests |
| `Sources/ClientRegistry.swift`, `Sources/ClientCredentialFiles.swift` | Registry v4: public verifiers, MCP and remote token digests, cloud access, grants, Ask before changes, activity with `via`/`agent`/`approval`; signature and token authentication; key, `.mcp-token` and `.mcp-remote-token` file lifecycle |
| `Sources/RequestPipeline.swift` | The one path every request takes after authentication, in a fixed order: bridge on, rate limits, grant, policy, recheck, approval, dispatch, Activity |
| `Sources/LocalBridge.swift`, `Sources/ClientBridgeProtocol.swift`, `Sources/BridgeClient.swift`, `Sources/SafePath.swift`, `client.py` | Private per-user file transport, signed request checks, the CLI (`Contents/MacOS/bridge-client`, and `client.py`, which finds and runs it); file-safety checks shared with the launcher |
| `Sources/MCP/` | The MCP server: `HTTPMessage` (pure HTTP/1.1 parser), `LoopbackHTTPServer` (127.0.0.1 listener, limits, timeouts), `MCPService` (listener lifecycle, the hop to the main actor), `MCPServer` (endpoint checks, token auth, both protocol eras, dispatch), `JSONRPC`, `MCPToolCatalog` (the 12 tools from `tools.json`, visibility, argument validation), `MCPToolMapping` (arguments ⇄ core requests and results), `MCPTime`, `AgentOutcomeText` (error text for agents), `RateLimiter` (local and remote buckets, both lockouts), `MCPEndpointFile`. Remote Access: `RemoteMCPService` (the second listener, its gate, health nonces, remote authentication), `OAuthServer` (metadata, pairing, authorize, token, register, revoke), `OAuthStore` (`remote-connections.json`), `OAuthPages` (the browser pages), `OAuthTypes`, `CIMDFetcher` (the bounded metadata fetch and its SSRF guard) |
| `Sources/MCPLauncher.swift` | `bridge-mcp`: stdio relay, `headers` for Claude Code, `check`; listener verification; built without AppKit or EventKit |
| `Sources/CommandPolicy.swift`, `Sources/MutationPolicy.swift` | Strict parameter checks before EventKit; which items a write may touch (invitations, occurrences, spans, repeating reminders) |
| `Sources/EventKitCommands.swift`, `Sources/EventCommands.swift`, `Sources/ReminderCommands.swift` | EventKit reads and writes: dispatch and shared lookups; events (occurrences, spans, moves, rows); reminders (filters, completion, rows) |
| `Sources/EventFields.swift`, `Sources/ReminderFields.swift`, `Sources/ReminderSchedule.swift`, `Sources/ReminderDue.swift` | Writes as values: parsing a request, merging a partial update with the current item, and verifying the readback (pure, unit-tested); reminder fields ⇄ `EKReminder` |
| `Sources/ItemText.swift`, `Sources/ItemAlarms.swift`, `Sources/Recurrence.swift`, `Sources/RecurrenceText.swift` | Notes, location and URL rules and places; alarms; the shared recurrence model, its pure expansion and RRULE text; plain-English rule summaries |
| `Sources/RecurringReminderCompletion.swift` | The account-type and rule-shape allowlist for completing one occurrence of a repeating reminder, and its transition checks |
| `Sources/ApprovalSummaries.swift` | The approval panel's rows, built with the same resolvers the writes use |
| `Sources/WriteJournal.swift`, `Sources/WriteIdempotencyKey.swift` | Pending write reservation, replay, expiry, reconciliation signals |
| `Sources/Synthetic*.swift`, `Sources/TestCollections.swift` | Supervised synthetic test controls; most command routes compile only with `EVENTKIT_SYNTHETIC_TEST=1` |
| `Sources/CommandLineTool.swift` | Settings ▸ Developer ▸ Install Command-Line Tool: links the bundled `bridge-client` into `~/.local/bin` |
| `build.sh`, `scripts/sdk.sh`, `scripts/check_bundle.sh`, `scripts/check_version.sh` | The build (native or universal with `EVENTKIT_ARCHS`, signed inside out, with a secure timestamp for a real identity); the SDK choice shared with `test.sh`; the bundle layout check used by CI and releases; the release version check |
| `release.sh`, `scripts/check_notarized.sh`, `scripts/release_notes.py`, `scripts/appcast.py` | The release: tests, universal Developer ID build, notarization and stapling, DMG and zip, checksums, the Sparkle appcast and a draft GitHub release ([Releasing](#releasing)); Gatekeeper and staple checks; the CHANGELOG section as Markdown or HTML; the appcast writer |
| `Tests/`, `test.sh`, `ui_test.sh`, `ui_snapshots.sh` | Offline policy/shape/CLI tests, the isolated GUI window and behavior tests, and PNG snapshots of every screen |
| `Tests/mcp-fixtures/` | `tools.json` (the tool catalog contract, compared exactly), mapping goldens (`<tool>.<case>.args.json` → `.core.json`, `core-result.<case>.json` → `.structured.json`), agent error texts |
| `Tests/agent-setup/` | One golden per agent × method, the source of the setups in [MCP](MCP.md#set-up-your-agent), plus `cloud-*.txt` per cloud agent and `tunnel-*.txt` per tunnel, the source of [Use from cloud agents](MCP.md#use-from-cloud-agents) |
| `Tests/MCPServerHarness.swift`, `Tests/mcp_test.py`, `Tests/launcher_test.py` | The `-D EVENTKIT_MCP_TEST` server harness with fake EventKit and approvals (and the Remote Access listener and OAuth server, with control hooks for cloud access, pairing and nonces), and the Python suites that drive it over loopback and through `bridge-mcp` |
| `Tests/OAuthServerTests.swift`, `Tests/CIMDFetcherTests.swift` | The OAuth server and store with a fake fetcher and clock; the CIMD fetcher's URL, address, response and document rules and a live HTTPS fixture on localhost (built with `-D EVENTKIT_MCP_TEST`, the only build where its test hooks exist) |
| `Resources/` | App icon and the script that draws it |
| `.github/` | CI (`workflows/ci.yml`: `sh test.sh` and a universal `sh build.sh` with Xcode 27.0 and 26.6), the release workflow (`workflows/release.yml`: `release.sh` on a `v*` tag in the `release` environment), Dependabot for actions, issue and pull request templates |
| `docs/history/` | Research notes kept for context, such as why the OpenAI tunnel wasn't adopted |

## Working on a change

1. Read the [architecture](ARCHITECTURE.md) and [API limits](API.md) before widening a grant, command, due/recurrence shape, or transport. The current policy deliberately fails closed for unsupported EventKit semantics.
2. Make the smallest source change and test the policy and data shape offline. Run `sh test.sh` and `sh build.sh`. For UI changes, also run `sh ui_test.sh` in a logged-in GUI session, and attach light and dark PNGs from `sh ui_snapshots.sh` to the pull request (it needs Screen Recording permission for the terminal; `sh ui_snapshots.sh --cache` doesn't, but leaves lists and tables blank).
3. Treat installation and live EventKit tests as a separate, supervised step. Use a disposable client and app-created or otherwise empty test collections; get approval for actual writes and verify exact-item cleanup. A source build alone does not authorize a signed update or TCC change.
4. Keep `build/`, credentials, app data, request/response files, source IDs, personal titles, and raw crash logs out of commits and issues. If a write reports an uncertain state, reconcile it before another key or mutation.
5. Update the API, MCP guide, support matrix, testing evidence, and troubleshooting notes when behavior changes. A change to a tool's arguments, description or output starts in `Tests/mcp-fixtures/tools.json`; new outcome codes need an entry in both `OutcomePresentation` and `AgentOutcomeText` (tests scan `Sources/` for emitted codes; the OAuth files and `CIMDFetcher.swift` are skipped, because their error codes are OAuth protocol errors, not bridge outcomes). A change to a cloud agent's or tunnel's setup changes its golden; update [Use from cloud agents](MCP.md#use-from-cloud-agents) to match. Distinguish code path, offline test, live local readback, device notification, and cross-device sync evidence.

The scripts are deliberately simple: plain `swiftc` calls, no Xcode project or package manager. They use the SDK `xcrun` selects (see [Setup](SETUP.md#requirements)) and sign ad hoc by default. The installed app's signing identity, Launch at Login setting, macOS privacy grants, and client credentials are **local state**, not reproducible from this repository alone.

## Before every release

- [ ] `sh test.sh` and a universal `EVENTKIT_ARCHS="arm64 x86_64" sh build.sh` pass, and CI is green on `main`.
- [ ] `CFBundleShortVersionString` and a higher `CFBundleVersion` in `Info.plist`; the version's section in [CHANGELOG](../CHANGELOG.md) says what callers and agents must change and whether a registry upgrade can be rolled back.
- [ ] Docs match the behavior: README, API, MCP guide, support matrix, testing record.
- [ ] No personal data in the tree or the new commits: no keys, tokens, Remote Access URLs, tunnel host names, collection IDs, calendar or reminder contents, journal files or raw logs. `gitleaks git` over the new commits is clean.
- [ ] For UI changes: `sh ui_test.sh` passes and the screenshots in `docs/images/` are current.
- [ ] Live checks the release needs ran on synthetic data with the owner's approval: the fields probe for EventKit writes, the [live MCP matrix](TESTING.md#live-mcp-matrix) for MCP changes, the [live cloud matrix](TESTING.md#live-cloud-matrix) for Remote Access changes (Remote Access stays labeled Experimental until it has run).
- [ ] The release build installs over the previous one at the same path and keeps Calendar and Reminders access, clients, tokens and agent setups ([release install test](TESTING.md#release-install-test)).
- [ ] A rehearsal, `sh release.sh --untagged --no-release`, has produced a notarized DMG and zip from the release commit, so the workflow run is a formality.

The runtime write journal (`write-journal.json` and `write-journal/<client>.json`) can contain reminder titles, item IDs and due summaries in its completed receipts. Never attach Application Support files or raw logs to an issue or a release.

## Releasing

`Info.plist` is the one source of the version. A release is a tag `v<CFBundleShortVersionString>` on `main`, built by `release.sh`: in GitHub Actions when the tag is pushed (`.github/workflows/release.yml`, in the protected `release` environment), or by hand on a Mac that has the Developer ID identity and the notary credentials. Both produce a **draft** GitHub release for you to review and publish. In-app updates (Sparkle) aren't wired into the app yet; the pipeline already writes the appcast once a Sparkle key is set.

### What `release.sh` does

1. Refuses a tree with uncommitted changes or a `HEAD` that isn't tagged `v<version>` (`--untagged` for a rehearsal), and runs `scripts/check_version.sh` (tag, a higher `CFBundleVersion` than the previous `v*` tag, a `## [x.y.z]` section in the changelog).
2. Runs `sh test.sh` (`--skip-tests` only for repeated rehearsals).
3. Builds the universal app (`EVENTKIT_ARCHS="arm64 x86_64"`) in `build/release/`, signed inside out (`bridge-mcp`, `bridge-client`, then the app) with the Developer ID identity, the hardened runtime and a secure timestamp, and runs `scripts/check_bundle.sh`.
4. Notarizes the app (`notarytool submit --wait`; on anything but Accepted it prints Apple's log) and staples the ticket.
5. Builds `EKBridge-<version>.dmg` (LZFSE, HFS+, with an Applications link), signs, notarizes and staples it. `scripts/check_notarized.sh` confirms Gatekeeper's verdict (`source=Notarized Developer ID`) and the staple on the app and on the image.
6. Builds `EKBridge-<version>.zip` from the stapled app (Sparkle installs from the zip; people download the DMG) and writes `SHA256SUMS`.
7. With `EVENTKIT_SPARKLE_KEY_FILE`, signs the zip with Sparkle's `sign_update` and writes `appcast.xml` (`scripts/appcast.py`) with the version, build number, minimum macOS, URL, length, signature and the release notes as HTML.
8. Creates the draft release `v<version>` with the DMG, the zip, `SHA256SUMS`, `appcast.xml` and notes: the changelog section (`scripts/release_notes.py`, relative links made absolute) followed by Install and Checksums sections.

Everything goes to `dist/` (ignored). `sh release.sh --help` lists the options and environment variables.

### Cutting a release

1. On a branch: raise `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, turn `## [Unreleased]` into `## [x.y.z] - YYYY-MM-DD` in the changelog (keep an empty Unreleased above it), work through [Before every release](#before-every-release), and merge with CI green.
2. Rehearse on `main`: `sh release.sh --untagged --no-release` with the notary credentials (`--no-notarize` without them). It builds, notarizes and checks the DMG and the zip without touching GitHub.
3. `git tag v<x.y.z> && git push origin v<x.y.z>`, then approve the run in Actions. It takes about 10 minutes plus Apple's notarization time.
4. Open the draft under Releases: check the notes and the five assets, download the DMG and run `shasum -a 256 -c SHA256SUMS`, and before the first release or after a change to the bundle layout or the updater, run the [release install test](TESTING.md#release-install-test).
5. Publish. `https://github.com/bereciartua/ek-bridge/releases/latest/download/appcast.xml` then resolves to this version's feed.

### Release notes

The changelog section **is** the release notes, so write it for someone upgrading:

- A lead paragraph with the highlights, the client registry version, and whether a rollback to the previous version works (a registry upgrade that older versions can't read has no rollback: say so).
- What changes for agents and the command line: tool names and arguments, outcome codes, snippets to copy again, paths and variables.
- Known issues, if any.

`release.sh` appends the install steps, the SHA-256 sums and how the build was verified; don't repeat those.

### The `release` environment

Create it under Settings ▸ Environments with yourself as a required reviewer, and add these secrets. On GitHub Free, required reviewers and tag rulesets work only in a public repository, so do this right after the repository goes public and before the first tag.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate with its private key, exported from Keychain Access as a `.p12`, base64 encoded (`base64 -i certificate.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | The `.p12` password |
| `NOTARY_KEY` | An App Store Connect API key (`.p8`, Users and Access ▸ Integrations ▸ App Store Connect API, Developer role), base64 encoded |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | The key's ID and the issuer ID shown next to it |
| `SPARKLE_PRIVATE_KEY` | Later, with Sparkle: the EdDSA private key from `generate_keys -x`. Unset, the release has no `appcast.xml` |

The workflow imports the certificate into a temporary keychain, writes the keys to files under `RUNNER_TEMP`, runs `release.sh` with `GH_TOKEN` for the draft, attaches build attestations to the DMG and the zip (`gh attestation verify EKBridge-<version>.dmg --repo bereciartua/ek-bridge`; public repositories only), and deletes the keychain and the keys. Add a tag ruleset that lets only you create `v*` tags. Keep the exported `.p12` and the Sparkle key in a password manager too: losing the Developer ID key ends Calendar and Reminders access continuity for every user, and losing the Sparkle key leaves existing installs unable to verify updates.

### By hand

`release.sh` finds the one `Developer ID Application` identity in the keychain (or takes `EVENTKIT_SIGN_IDENTITY`). For notarization, store the API key once with `xcrun notarytool store-credentials ek-bridge --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer>` and run `EVENTKIT_NOTARY_PROFILE=ek-bridge sh release.sh`, or pass `EVENTKIT_NOTARY_KEY`, `EVENTKIT_NOTARY_KEY_ID` and `EVENTKIT_NOTARY_ISSUER`. The draft needs `gh` signed in. A full run from a tagged commit behaves exactly like the workflow, minus the attestations.

## Regenerating goldens

The agent setup snippets (`Tests/agent-setup/`) and the MCP mapping goldens (`Tests/mcp-fixtures/`) are compared byte for byte. After an intended change, rewrite them and review the diff before committing:

```sh
UPDATE_GOLDENS=1 sh test.sh
git diff Tests/agent-setup Tests/mcp-fixtures
```

Then update the snippets in [MCP](MCP.md#set-up-your-agent) and [Use from cloud agents](MCP.md#use-from-cloud-agents) to match the agent setup, cloud and tunnel goldens. `tools.json` is never rewritten by a test: edit it by hand, since agents see it.

## The rename migration

Up to 0.7.0 the app was called EventKit Bridge, with the bundle ID `dev.martin.dot.eventkitbridge` (`LegacyIdentity` in `Sources/AppIdentity.swift`; the only place that ID may appear). On its first launch under the new identity, `RenameMigration` (run from `main.swift` before anything reads settings or the data folder):

1. asks the old app to quit if it's running, offering Force Quit if it doesn't within 10 seconds. The two would share the data folder through the link, so this check runs on every launch, and an observer asks again if the old app starts while EK Bridge runs (for example through its own Start at login);
2. renames `~/Library/Application Support/EventKitBridge` to `EKBridge` and leaves a relative symlink at the old path, so scripts and agent configs that name key or token files there keep working;
3. copies the known settings from the old defaults domain (`RenameMigration.copiedKeys`), never overwriting a value the new domain has; the setup checklist's done and hidden flags stay behind, so the checklist comes back for the new Calendar and Reminders prompts;
4. records `RenameMigrationDone`, shows a one-time notice on Overview, and sets `RenameAccessRecheck`, which keeps Activity from before the rename from marking the checklist done until it completes again (or is hidden).

If the move fails (for example both folders exist), nothing is recorded, an alert says what to fix, and the next launch tries again. `bridge-client` and `bridge-mcp` look in the old folder only while the new one doesn't exist. The transport folder moved from `/tmp/eventkit-bridge-<uid>` to `/tmp/ek-bridge-<uid>`; the app and its bundled CLI changed together. Remove the symlink, `LegacyIdentity` and the tools' fallback one or two releases after the first public release.

## Upgrade notes

What changed for callers and agents in each version, and how to roll back a client registry upgrade, is in the [changelog](../CHANGELOG.md).

## Open decisions and suggested work

| Area | Owner decision or next investigation |
| --- | --- |
| Public rights and support | Decided: Apache-2.0 with a `NOTICE` ([LICENSE](../LICENSE)); private vulnerability reporting ([SECURITY](../SECURITY.md)); Issues with templates and best-effort support ([CONTRIBUTING](../CONTRIBUTING.md)). Contributions are under the same license, without a separate agreement. |
| Distribution | Decided: bundle ID `io.github.bereciartua.ekbridge`, Developer ID signing and notarization, a DMG and a zip built by a release workflow, universal builds, the CLI inside the app, and in-app updates with Sparkle 2. Done so far: portable SDK choice, universal builds, the CLI in the bundle, CI, the new name and bundle ID with their [one-time migration](#the-rename-migration), and the [release pipeline](#releasing) (`release.sh`, the release workflow, the appcast writer). Still to do: the notary credentials and the `release` environment (owner), the [release install test](TESTING.md#release-install-test), and Sparkle in the app. |
| Security boundary | Decide whether same-user file exposure is acceptable. Consider Keychain-backed credentials, an OS-enforced peer boundary, and task-runner authorization only after a threat review. A signed peer check alone (an XPC design explored early on, removed from the tree but in the git history) would not stop a same-user process from invoking a signed CLI. The local MCP server's threat review is in [Architecture](ARCHITECTURE.md#mcp-threat-review-040), and Remote Access's in [Architecture](ARCHITECTURE.md#remote-access-threat-review-050). |
| Remote access for cloud agents | Implemented in 0.5.0 (Phase 5 of the MCP plan), with its own [threat review](ARCHITECTURE.md#remote-access-threat-review-050). Labeled Experimental in Settings and the README until the [live cloud matrix](TESTING.md#live-cloud-matrix) has run; none of it has been run. Deviations from the plan: the registry stays v4; the OAuth discovery documents are served only behind the secret, with the path inserted after the well-known name (nothing at the bare `/.well-known` paths); dynamic registration needs an open pairing window; Gemini Enterprise uses confidential `cfg_` clients set up in the app; the Cloudflare quick tunnel command adds `--http-host-header 127.0.0.1:<port>`; ngrok is recognized by an ngrok domain in `X-Forwarded-Host`. The OpenAI Secure MCP Tunnel was not adopted ([spike note](history/OPENAI-TUNNEL-SPIKE.md)). Not implemented: approving changes from a phone, a **Start for me** button that runs `tailscale funnel`, IP allowlists per agent. |
| MCP follow-ups | Not implemented: tool-list change notifications (SSE), OAuth for local agents, IPv6 loopback, a Unix-socket launcher mode, Keychain tokens, a Claude Desktop extension, "Add to…" buttons that write agent configs. Run the [live MCP matrix](TESTING.md#live-mcp-matrix) before a release. |
| Product semantics | 0.6.0 covers every field EventKit exposes ([support matrix](API.md#support-matrix)). Still provider-gated: edits of invitations where the user is the organizer (spike S3), location alarm delivery on devices (S5), and recurring completion beyond the verified iCloud daily shape (S6). Preserve fail-closed handling of floating times, unsupported rules and alarms, and uncertain writes. Deviations from the plan: core all-day writes keep Unix-second midnights rather than `startDate`/`endDate` strings, for compatibility; `weekStart` is read only (EventKit can't set it); `read_events` pages with an opaque cursor rather than `next_start`; location alarm writes are enabled with readback but delivery is unverified (S5). |
| Public name | Applied: **EK Bridge** (`AppIdentity.displayName`, `CFBundleName`, `CFBundleDisplayName`), never expanded to the framework's name in the name, title, icon or store metadata, with "Not affiliated with Apple" in the README and `NOTICE`. If Apple ever objects, only the display name changes: no new permission prompt and no data migration. The MCP server key `ek-bridge` (`AppIdentity.mcpServerKey`) ends up in agents' tool names and allowlists, so it must not change after the first public release. The launcher name is `AppIdentity.launcherName`. The bundle ID (the launcher's identity check compares it), the data folder and the `/tmp` transport folder are permanent too; the `ekb_v1_`, `ekb_mcp_v1_`, `ekb_mcpr_v1_`, `ekb_oat_v1_`, `ekb_ort_v1_`, `ekb_ocs_v1_` and `ekb3_` prefixes must not change. The `EVENTKIT_*` build and test variables kept their names: they describe the framework, aren't user-visible, and renaming them would break existing scripts. |
| App icon | `Resources/AppIcon.icns` is drawn in code by `Resources/make_icon.sh` as a placeholder. Replace it with a commissioned icon before a public release. |
| Accessibility | VoiceOver labels are set for the status item, the menu switch, sidebar rows and every access checkbox, but a full VoiceOver pass by a VoiceOver user hasn't been done. |
| Evidence | Add repeatable tests across macOS versions, calendar providers, DST boundaries, restart/login conditions, longer idle periods, and cross-device recurrence/notification behavior using synthetic data. |

The [testing guide](TESTING.md) is the evidence ledger.

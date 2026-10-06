# Maintainer handoff

This is a developer-owned macOS prototype. The repository remains **private** while its owner decides whether and how to release it. This guide records current code boundaries and open decisions; it does not select a license, sign a release, register a service, or grant ongoing access.

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
| `Sources/UIReview.swift` | `EVENTKIT_UI_REVIEW=1` builds only: fake data, snapshots, window and behavior tests |
| `Sources/ClientRegistry.swift`, `Sources/ClientCredentialFiles.swift` | Registry v4: public verifiers, MCP and remote token digests, cloud access, grants, Ask before changes, activity with `via`/`agent`/`approval`; signature and token authentication; key, `.mcp-token` and `.mcp-remote-token` file lifecycle |
| `Sources/RequestPipeline.swift` | The one path every request takes after authentication, in a fixed order: bridge on, rate limits, grant, policy, recheck, approval, dispatch, Activity |
| `Sources/LocalBridge.swift`, `Sources/ClientBridgeProtocol.swift`, `Sources/BridgeClient.swift`, `Sources/SafePath.swift`, `client.py` | Private per-user file transport, signed request checks, local CLI; file-safety checks shared with the launcher |
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
| `Tests/`, `test.sh`, `ui_test.sh`, `ui_snapshots.sh` | Offline policy/shape/CLI tests, the isolated GUI window and behavior tests, and PNG snapshots of every screen |
| `Tests/mcp-fixtures/` | `tools.json` (the tool catalog contract, compared exactly), mapping goldens (`<tool>.<case>.args.json` → `.core.json`, `core-result.<case>.json` → `.structured.json`), agent error texts |
| `Tests/agent-setup/` | One golden per agent × method, the source of the setups in [MCP](MCP.md#set-up-your-agent), plus `cloud-*.txt` per cloud agent and `tunnel-*.txt` per tunnel, the source of [Use from cloud agents](MCP.md#use-from-cloud-agents) |
| `Tests/MCPServerHarness.swift`, `Tests/mcp_test.py`, `Tests/launcher_test.py` | The `-D EVENTKIT_MCP_TEST` server harness with fake EventKit and approvals (and the Remote Access listener and OAuth server, with control hooks for cloud access, pairing and nonces), and the Python suites that drive it over loopback and through `bridge-mcp` |
| `Tests/OAuthServerTests.swift`, `Tests/CIMDFetcherTests.swift` | The OAuth server and store with a fake fetcher and clock; the CIMD fetcher's URL, address, response and document rules and a live HTTPS fixture on localhost (built with `-D EVENTKIT_MCP_TEST`, the only build where its test hooks exist) |
| `Resources/` | App icon and the script that draws it |
| `Candidate/` | Historical signed XPC design exploration, not the active transport |

## Working on a change

1. Read the [architecture](ARCHITECTURE.md) and [API limits](API.md) before widening a grant, command, due/recurrence shape, or transport. The current policy deliberately fails closed for unsupported EventKit semantics.
2. Make the smallest source change and test the policy and data shape offline. Run `sh test.sh` and `sh build.sh`. For UI changes, also run `sh ui_test.sh` in a logged-in GUI session, and attach light and dark PNGs from `sh ui_snapshots.sh` to the pull request (it needs Screen Recording permission for the terminal; `sh ui_snapshots.sh --cache` doesn't, but leaves lists and tables blank).
3. Treat installation and live EventKit tests as a separate, supervised step. Use a disposable client and app-created or otherwise empty test collections; get approval for actual writes and verify exact-item cleanup. A source build alone does not authorize a signed update or TCC change.
4. Keep `build/`, credentials, app data, request/response files, source IDs, personal titles, and raw crash logs out of commits and issues. If a write reports an uncertain state, reconcile it before another key or mutation.
5. Update the API, MCP guide, support matrix, testing evidence, and troubleshooting notes when behavior changes. A change to a tool's arguments, description or output starts in `Tests/mcp-fixtures/tools.json`; new outcome codes need an entry in both `OutcomePresentation` and `AgentOutcomeText` (tests scan `Sources/` for emitted codes; the OAuth files and `CIMDFetcher.swift` are skipped, because their error codes are OAuth protocol errors, not bridge outcomes). A change to a cloud agent's or tunnel's setup changes its golden; update [Use from cloud agents](MCP.md#use-from-cloud-agents) to match. Distinguish code path, offline test, live local readback, device notification, and cross-device sync evidence.

The scripts are deliberately simple but machine-specific: they hardcode one SDK path, use ad hoc signing by default, and are not a public packaging pipeline. The installed app's stable signing identity, verified source pin, Launch at Login setting, macOS privacy grants, and client credentials are **local state**, not reproducible from this repository alone.

## Findings from the current source privacy audit

No actual client credential, private signing key, user collection UUID, home-directory path, or raw EventKit export was found in the tracked source/docs reviewed for this handoff. Before any public release, review the entire Git history as well as the current tree. The current tree still contains **personalized development identifiers**:

- `Info.plist` uses a development bundle identifier containing the original owner's name; `test.sh` and `Tests/SignedXPCBoundaryTests.swift` use matching test identifiers. Choosing a public bundle identity is a signing and TCC migration decision, not a documentation edit.
- `Sources/SyntheticTestMode.swift` has a test-only source check tied to a personally named client and reminder list. The ordinary build excludes this route, but the strings remain visible in public source if the repository is opened. Generalize or remove that test-only assumption before publication.
- `Candidate/` records an unimplemented XPC approach. Its note is clearly marked historical, but decide whether to retain it in a public source release.
- The Remote Access URL's secret path, tunnel host names, remote tokens and OAuth client secrets are local state; keep them out of issues, screenshots and test records.
- The runtime write journal (`write-journal.json` and `write-journal/<client>.json`) is outside the repo, but its completed receipts can contain reminder titles, item IDs, and due summaries. Source comments should not be read as a guarantee that the journal contains no personal item data. Exclude local Application Support files and raw logs from any release or issue attachment.

These are identifying strings and portability issues, **not evidence of a leaked private key**. No functional code was changed during this documentation pass. Review commits and tags for earlier personal text or test residue before changing repository visibility.

### Regenerating goldens

The agent setup snippets (`Tests/agent-setup/`) and the MCP mapping goldens (`Tests/mcp-fixtures/`) are compared byte for byte. After an intended change, rewrite them and review the diff before committing:

```sh
UPDATE_GOLDENS=1 sh test.sh
git diff Tests/agent-setup Tests/mcp-fixtures
```

Then update the snippets in [MCP](MCP.md#set-up-your-agent) and [Use from cloud agents](MCP.md#use-from-cloud-agents) to match the agent setup, cloud and tunnel goldens. `tools.json` is never rewritten by a test: edit it by hand, since agents see it.

## Upgrading to 0.6.0

App 0.6.0 adds every EventKit field on events and reminders (plan 03). The client registry stays at **version 4** and no grant actions were added; `get_event` and `get_reminder` need Read, and a move needs Edit on the source and Create on the destination. What changes for callers:

- **Time zones.** A timed event is saved in the requested `timeZone`, or the Mac's, instead of UTC. Events created by older versions stay in UTC until an update with only `timeZone` moves them (their instants don't change).
- **Partial updates.** `update_event` and `update_reminder` no longer need `title`, `start` and `end`; absent keeps, `null` clears. Old callers that always send them keep working. Moving a reminder's due date now keeps its alarms (one at the old due time follows it) instead of resetting them to the default.
- **CLI results.** Event and reminder rows gain the fields in [API](API.md#reads); `read_events` pages with `nextCursor`/`afterKey` instead of failing with `too_many_events_narrow_range` (kept only for ranges with more than 20,000 events); reminder recurrence uses `monthDays` (0.5's `dayOfMonth` is accepted on input for one release); receipts gain `verified`. Requests may be 32 KB. `read_reminders` keeps returning every reminder unless `status` is given.
- **MCP results.** See the breaking changes in [MCP](MCP.md#tools): `editable` is an object, event times carry the event's own offset, `verified` is a list, alarms use `minutes_before`, recurrence uses `month_days` and `end`, and `read_reminders` defaults to open reminders. Agents re-read the tool list when they reconnect.
- **Recurring reminder completion** uses an account-type and rule-shape allowlist (`RecurringReminderCompletion.verifiedShapes`) instead of a source ID pinned in `Info.plist`. Extend the allowlist only with shapes a supervised probe verified ([Testing](TESTING.md#plan-03-live-probe-spikes-s1s6)).
- **Retired codes.** `all_day_or_attendees_unsupported`, `recurrence_delete_unsupported`, `complex_start_unsupported`, `complex_alarm_unsupported`, `floating_time_unsupported` and `recurrence_requires_alarm_reset` are no longer returned; their texts stay for journal replays of older results.

## Upgrading to 0.5.0

App 0.5.0 adds Remote Access. The client registry stays at **version 4**: clients gain `remoteEnabled`, `remoteVerifier` and `remoteIssuedAt`, and Activity rows may have `via: remote`. 0.4.0 was never released on its own, so no version 5 or new backup was needed (the plan had called these fields v5). OAuth connections live in a new file, `remote-connections.json`. Remote Access is off until you turn it on, and every client starts without cloud access. Nothing changes for the CLI or local agents. See [Use from cloud agents](MCP.md#use-from-cloud-agents).

## Upgrading to 0.4.0

App 0.4.0 writes client registry **version 4** (MCP token digests, Ask before changes, `via` and agent in Activity). The first version 4 write keeps a one-time copy of the file it read as `client-registry.v3.backup.json` (or `client-registry.v2.backup.json` from a version 2 file). **0.3.x fails closed on version 4** ("client settings can't be read"). To roll back: quit the app, restore the backup over `client-registry.json`, and accept that changes made since the upgrade are lost, including every client's MCP access. See [Architecture](ARCHITECTURE.md#client-registry-versions).

Existing clients keep their keys and grants and are set to *Allow without asking*. The MCP server is off until you turn it on. The write journal grows to 10,000 entries with a per-client quota, stored as one file per client in `write-journal/`; entries already in `write-journal.json` stay there and count toward the total only. CLI results gain `hasAttendees` on event rows, `completed` and `recurring` on reminder receipts, and `repeated` on journal replays, plus the `list_collections` command; scripts that ignore unknown keys keep working.

## Upgrading to 0.3.0

App 0.3.0 writes client registry **version 3**. An older build fails closed on it ("client settings can't be read"). The first version 3 write keeps a one-time copy of the version 2 file as `client-registry.v2.backup.json`; to roll back, quit the app and restore that file over `client-registry.json` (changes made since the upgrade are lost). See [Architecture](ARCHITECTURE.md#client-registry-versions).

The Controls, Clients & Permissions and Activity windows are replaced by one window. `client.py` failures now have specific messages and exit codes (see [API](API.md)); scripts that only checked for a non-zero exit keep working.

## Open decisions and suggested work

| Area | Owner decision or next investigation |
| --- | --- |
| Public rights and support | Choose a license and copyright attribution, security reporting channel, issue/support policy, and contribution terms. No license is assumed here. |
| Distribution | Decide bundle ID, code-signing and notarization identity, versioning, update channel, and how a user's TCC grants migrate between builds. Replace the machine-specific SDK path for reproducible public builds. |
| Security boundary | Decide whether same-user file exposure is acceptable. Consider Keychain-backed credentials, an OS-enforced peer boundary, and task-runner authorization only after a threat review. The XPC candidate alone does not stop a same-user process from invoking a signed CLI. The local MCP server's threat review is in [Architecture](ARCHITECTURE.md#mcp-threat-review-040), and Remote Access's in [Architecture](ARCHITECTURE.md#remote-access-threat-review-050). |
| Remote access for cloud agents | Implemented in 0.5.0 (Phase 5 of the MCP plan), with its own [threat review](ARCHITECTURE.md#remote-access-threat-review-050). Run the [live cloud matrix](TESTING.md#live-cloud-matrix) before release; none of it has been run. Deviations from the plan: the registry stays v4; the OAuth discovery documents are served only behind the secret, with the path inserted after the well-known name (nothing at the bare `/.well-known` paths); dynamic registration needs an open pairing window; Gemini Enterprise uses confidential `cfg_` clients set up in the app; the Cloudflare quick tunnel command adds `--http-host-header 127.0.0.1:<port>`; ngrok is recognized by an ngrok domain in `X-Forwarded-Host`. The OpenAI Secure MCP Tunnel was not adopted ([spike note](OPENAI-TUNNEL-SPIKE.md)). Not implemented: approving changes from a phone, a **Start for me** button that runs `tailscale funnel`, IP allowlists per agent. |
| MCP follow-ups | Not implemented: tool-list change notifications (SSE), OAuth for local agents, IPv6 loopback, a Unix-socket launcher mode, Keychain tokens, a Claude Desktop extension, "Add to…" buttons that write agent configs. Run the [live MCP matrix](TESTING.md#live-mcp-matrix) before a release. |
| Product semantics | 0.6.0 covers every field EventKit exposes ([plan 03](API.md#support-matrix)). Still provider-gated: edits of invitations where the user is the organizer (spike S3), location alarm delivery on devices (S5), and recurring completion beyond the verified iCloud daily shape (S6). Preserve fail-closed handling of floating times, unsupported rules and alarms, and uncertain writes. Deviations from the plan: core all-day writes keep Unix-second midnights rather than `startDate`/`endDate` strings, for compatibility; `weekStart` is read only (EventKit can't set it); `read_events` pages with an opaque cursor rather than `next_start`; location alarm writes are enabled with readback but delivery is unverified (S5). |
| Public name | "EventKit Bridge" is still a working name; "EventKit" is Apple's framework name, so a public name should drop it. The display name lives in `AppIdentity.displayName` and `Info.plist` (`CFBundleName`, `CFBundleDisplayName`). The MCP server key `eventkit-bridge` (`AppIdentity.mcpServerKey`) is stable: it ends up in agents' tool names (`mcp__eventkit-bridge__read_events`) and allowlists, so keep it even after a rename. The launcher name is `AppIdentity.launcherName`. Changing the bundle ID (the launcher's identity check compares it), the data folder or the `/tmp` transport folder is a separate, migrated change; the `ekb_v1_`, `ekb_mcp_v1_`, `ekb_mcpr_v1_`, `ekb_oat_v1_`, `ekb_ort_v1_`, `ekb_ocs_v1_` and `ekb3_` prefixes must not change. |
| App icon | `Resources/AppIcon.icns` is drawn in code by `Resources/make_icon.sh` as a placeholder. Replace it with a commissioned icon before a public release. |
| Accessibility | VoiceOver labels are set for the status item, the menu switch, sidebar rows and every access checkbox, but a full VoiceOver pass by a VoiceOver user hasn't been done. |
| Evidence | Add repeatable tests across macOS versions, calendar providers, DST boundaries, restart/login conditions, longer idle periods, and cross-device recurrence/notification behavior using synthetic data. |

The [testing guide](TESTING.md) is the evidence ledger. The private repository can be handed over for continued development now; publishing it, choosing binding license terms, and widening persistent access are separate decisions for its owner.

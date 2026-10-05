# Maintainer handoff

This is a developer-owned macOS prototype. The repository remains **private** while its owner decides whether and how to release it. This guide records current code boundaries and open decisions; it does not select a license, sign a release, register a service, or grant ongoing access.

## Repository map

| Path | Responsibility |
| --- | --- |
| `Sources/main.swift` | App delegate: bridge start/stop, request handling, main menu |
| `Sources/BridgeAppModel.swift` | UI state and actions shared by the menu bar, the window and the setup checklist |
| `Sources/StatusMenuController.swift`, `Sources/MainWindowController.swift` | Menu bar extra; the one main window, its unsaved-changes guard and Dock policy |
| `Sources/MainView.swift`, `OverviewView.swift`, `ClientDetailView.swift`, `ActivityView.swift`, `SettingsView.swift`, `UIComponents.swift` | SwiftUI views hosted in AppKit |
| `Sources/AppIdentity.swift`, `AppPresentation.swift`, `OutcomePresentation.swift` | Product name, display formatting, setup checklist logic, outcome labels and fixes (shared with the CLI) |
| `Sources/UIReview.swift` | `EVENTKIT_UI_REVIEW=1` builds only: fake data, snapshots, window and behavior tests |
| `Sources/ClientRegistry.swift`, `Sources/ClientCredentialFiles.swift` | Public verifier registry, grants, Ed25519 credential file lifecycle |
| `Sources/LocalBridge.swift`, `Sources/ClientBridgeProtocol.swift`, `Sources/BridgeClient.swift`, `client.py` | Private per-user file transport, signed request checks, local CLI |
| `Sources/CommandPolicy.swift`, `Sources/EventKitCommands.swift`, `Sources/Reminder*.swift`, `Sources/EventCreation.swift` | Strict parameter checks, EventKit reads/writes, date/recurrence/readback guards |
| `Sources/WriteJournal.swift`, `Sources/WriteIdempotencyKey.swift` | Pending write reservation, replay, expiry, reconciliation signals |
| `Sources/Synthetic*.swift`, `Sources/TestCollections.swift` | Supervised synthetic test controls; most command routes compile only with `EVENTKIT_SYNTHETIC_TEST=1` |
| `Tests/`, `test.sh`, `ui_test.sh`, `ui_snapshots.sh` | Offline policy/shape/CLI tests, the isolated GUI window and behavior tests, and PNG snapshots of every screen |
| `Resources/` | App icon and the script that draws it |
| `Candidate/` | Historical signed XPC design exploration, not the active transport |

## Working on a change

1. Read the [architecture](ARCHITECTURE.md) and [API limits](API.md) before widening a grant, command, due/recurrence shape, or transport. The current policy deliberately fails closed for unsupported EventKit semantics.
2. Make the smallest source change and test the policy and data shape offline. Run `sh test.sh` and `sh build.sh`. For UI changes, also run `sh ui_test.sh` in a logged-in GUI session, and attach light and dark PNGs from `sh ui_snapshots.sh` to the pull request (it needs Screen Recording permission for the terminal; `sh ui_snapshots.sh --cache` doesn't, but leaves lists and tables blank).
3. Treat installation and live EventKit tests as a separate, supervised step. Use a disposable client and app-created or otherwise empty test collections; get approval for actual writes and verify exact-item cleanup. A source build alone does not authorize a signed update or TCC change.
4. Keep `build/`, credentials, app data, request/response files, source IDs, personal titles, and raw crash logs out of commits and issues. If a write reports an uncertain state, reconcile it before another key or mutation.
5. Update the API, support matrix, testing evidence, and troubleshooting notes when behavior changes. Distinguish code path, offline test, live local readback, device notification, and cross-device sync evidence.

The scripts are deliberately simple but machine-specific: they hardcode one SDK path, use ad hoc signing by default, and are not a public packaging pipeline. The installed app's stable signing identity, verified source pin, Launch at Login setting, macOS privacy grants, and client credentials are **local state**, not reproducible from this repository alone.

## Findings from the current source privacy audit

No actual client credential, private signing key, user collection UUID, home-directory path, or raw EventKit export was found in the tracked source/docs reviewed for this handoff. Before any public release, review the entire Git history as well as the current tree. The current tree still contains **personalized development identifiers**:

- `Info.plist` uses a development bundle identifier containing the original owner's name; `test.sh` and `Tests/SignedXPCBoundaryTests.swift` use matching test identifiers. Choosing a public bundle identity is a signing and TCC migration decision, not a documentation edit.
- `Sources/SyntheticTestMode.swift` has a test-only source check tied to a personally named client and reminder list. The ordinary build excludes this route, but the strings remain visible in public source if the repository is opened. Generalize or remove that test-only assumption before publication.
- `Candidate/` records an unimplemented XPC approach. Its note is clearly marked historical, but decide whether to retain it in a public source release.
- The runtime `write-journal.json` is outside the repo, but its completed receipts can contain reminder titles, item IDs, and due summaries. Source comments should not be read as a guarantee that the journal contains no personal item data. Exclude local Application Support files and raw logs from any release or issue attachment.

These are identifying strings and portability issues, **not evidence of a leaked private key**. No functional code was changed during this documentation pass. Review commits and tags for earlier personal text or test residue before changing repository visibility.

## Upgrading to 0.3.0

App 0.3.0 writes client registry **version 3**. An older build fails closed on it ("client settings can't be read"). The first version 3 write keeps a one-time copy of the version 2 file as `client-registry.v2.backup.json`; to roll back, quit the app and restore that file over `client-registry.json` (changes made since the upgrade are lost). See [Architecture](ARCHITECTURE.md#client-registry-versions).

The Controls, Clients & Permissions and Activity windows are replaced by one window. `client.py` failures now have specific messages and exit codes (see [API](API.md)); scripts that only checked for a non-zero exit keep working.

## Open decisions and suggested work

| Area | Owner decision or next investigation |
| --- | --- |
| Public rights and support | Choose a license and copyright attribution, security reporting channel, issue/support policy, and contribution terms. No license is assumed here. |
| Distribution | Decide bundle ID, code-signing and notarization identity, versioning, update channel, and how a user's TCC grants migrate between builds. Replace the machine-specific SDK path for reproducible public builds. |
| Security boundary | Decide whether same-user file exposure is acceptable. Consider Keychain-backed credentials, an OS-enforced peer boundary, and task-runner authorization only after a threat review. The XPC candidate alone does not stop a same-user process from invoking a signed CLI. No MCP integration is implemented. |
| Product semantics | Decide which additional EventKit fields and recurrence operations can be supported with verifiable provider behavior. Preserve fail-closed handling of ambiguous all-day, floating time, alarms, and uncertain writes. |
| Public name | "EventKit" is Apple's framework name, so the public name should drop it. The display name lives in `AppIdentity.displayName` and `Info.plist` (`CFBundleName`, `CFBundleDisplayName`). Changing the bundle ID, the data folder or the `/tmp` transport folder is a separate, migrated change; the `ekb_v1_` and `ekb3_` prefixes must not change. |
| App icon | `Resources/AppIcon.icns` is drawn in code by `Resources/make_icon.sh` as a placeholder. Replace it with a commissioned icon before a public release. |
| Accessibility | VoiceOver labels are set for the status item, the menu switch, sidebar rows and every access checkbox, but a full VoiceOver pass by a VoiceOver user hasn't been done. |
| Evidence | Add repeatable tests across macOS versions, calendar providers, DST boundaries, restart/login conditions, longer idle periods, and cross-device recurrence/notification behavior using synthetic data. |

The [testing guide](TESTING.md) is the evidence ledger. The private repository can be handed over for continued development now; publishing it, choosing binding license terms, and widening persistent access are separate decisions for its owner.

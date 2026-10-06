# Contributing

Thanks for helping with EK Bridge. This is a personal project maintained on a best-effort basis, so open an issue to discuss anything bigger than a small fix before you start.

Report security problems privately, as described in [SECURITY.md](SECURITY.md), never in a public issue.

## Build and test

You need macOS 14 or later, Xcode or the Xcode Command Line Tools, and Python 3. There's no Xcode project: the scripts call `swiftc` directly.

```sh
sh test.sh     # offline unit, CLI, MCP and launcher tests; no Calendar or Reminders access
sh build.sh    # build/EKBridge.app, signed ad hoc
```

- `EVENTKIT_ARCHS="arm64 x86_64" sh build.sh` builds a universal app, as releases do. The default is this Mac's architecture.
- `EVENTKIT_SDK=<path>` picks the SDK. By default the scripts use the one `xcrun` selects; with Command Line Tools alone they use the macOS 26 SDK, because SwiftUI's macros in the macOS 27 SDK need Xcode.
- `sh ui_test.sh` runs the window and behavior tests, and `sh ui_snapshots.sh` writes PNGs of every screen in light and dark. Both need a logged-in GUI session and use fake data. `ui_snapshots.sh` needs Screen Recording permission for the terminal; `sh ui_snapshots.sh --cache` doesn't, but leaves lists and tables blank.

Continuous integration runs `sh test.sh` and a universal `sh build.sh` on every pull request. The UI scripts stay local.

## Working on a change

1. Read the [architecture](docs/ARCHITECTURE.md) and [API limits](docs/API.md) before widening a grant, command, due date or recurrence shape, or transport. The bridge deliberately fails closed for EventKit behavior it doesn't support.
2. Make the smallest change that works, and test the policy and data shape offline. Add or update a test in `Tests/`.
3. A change to a tool's arguments, description or output starts in `Tests/mcp-fixtures/tools.json`, which agents see. New outcome codes need an entry in both `OutcomePresentation` and `AgentOutcomeText`.
4. Golden files (`Tests/agent-setup/`, `Tests/mcp-fixtures/`) are compared byte for byte. After an intended change, regenerate them and review the diff:

   ```sh
   UPDATE_GOLDENS=1 sh test.sh
   git diff Tests/agent-setup Tests/mcp-fixtures
   ```

   Then update the matching snippets in [MCP](docs/MCP.md).
5. UI changes come with light and dark PNGs from `sh ui_snapshots.sh` in the pull request.
6. Update the docs (API, MCP guide, support matrix, testing record) when behavior changes, and add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).

## Live tests and personal data

- **No personal data in commits, issues or pull requests:** no keys, tokens, Remote Access URLs, tunnel host names, collection IDs, calendar or reminder contents, journal files or raw logs. Use the obviously fake values the tests already use.
- Live EventKit tests are a separate, supervised step. Use a throwaway client and the empty test collections the app creates (Settings ▸ Developer ▸ Show developer tools), or the synthetic probes, which create and remove their own collections. Check that every test item was cleaned up.
- An ad hoc build is a different app to macOS, so it asks for Calendar and Reminders access again. Don't copy another Mac's privacy database or signing key.

## License

EK Bridge is licensed under the [Apache License 2.0](LICENSE). By contributing, you agree that your contribution is licensed under the same terms, as section 5 of the license describes. There's no separate contributor agreement.

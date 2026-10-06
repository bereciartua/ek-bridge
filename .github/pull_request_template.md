## What and why

<!-- What changes, and why. Link the issue if there is one. -->

## Checks

- [ ] `sh test.sh` passes
- [ ] `sh build.sh` passes
- [ ] Goldens regenerated and the diff reviewed (`UPDATE_GOLDENS=1 sh test.sh`), if agent setups or MCP mappings changed
- [ ] Docs updated (API, MCP guide, support matrix, testing record), if behavior changed
- [ ] A line under **Unreleased** in `CHANGELOG.md`
- [ ] For UI changes: `sh ui_test.sh` passes, and light and dark PNGs from `sh ui_snapshots.sh` are attached
- [ ] No personal data: no keys, tokens, Remote Access URLs, tunnel host names, collection IDs, calendar or reminder contents, or journal files

# Security policy

EK Bridge gives scripts and AI agents scoped access to your Calendar and Reminders, and can expose that access to cloud agents through a tunnel you run. Please report security problems privately.

## Supported versions

Only the latest release gets security fixes. Fixes ship as a new release and are listed in the [changelog](CHANGELOG.md).

## Report a vulnerability

Use GitHub's private vulnerability reporting: **Security ▸ Report a vulnerability** in this repository, or [open a draft advisory](https://github.com/bereciartua/eventkit-bridge/security/advisories/new) directly. Please don't open a public issue, discussion or pull request for a vulnerability.

Include the app version (Settings ▸ About), your macOS version, whether the Mac has Apple silicon or Intel, how the client connects (command line, local MCP agent, or Remote Access), and the steps to reproduce.

**Never include real secrets or personal data**, even in a private report:

- client key files, MCP tokens, remote tokens or OAuth secrets (anything starting with `ekb_`), or the contents of `client-registry.json` or `remote-connections.json`
- a Remote Access URL: its path is the secret
- tunnel host names
- calendar or reminder titles, notes or attendees, the write journal (`write-journal*`), or Activity screenshots that show them

Reproduce with a throwaway client and the empty test collections from Settings ▸ Developer, and replace anything secret with `REDACTED`.

This is a personal project with best-effort support. You'll get a reply as soon as the maintainer can, and credit in the advisory and the changelog if you'd like it.

## Scope

In scope:

- The bridge's checks: client authentication (signatures, tokens, OAuth), grants per calendar and list, request validation, write safeguards and verification, and Ask before changes.
- The local MCP server on `127.0.0.1`, the Remote Access listener, the OAuth server and pairing, and the client metadata fetch (CIMD) and its address checks.
- The `bridge-mcp` launcher (token handling and the check of the listening app) and `bridge-client` (file safety checks).
- File permissions of the request exchange in `/tmp` and of the app's files in `~/Library/Application Support`.
- The build and release pipeline, and in-app updates once they ship.

Out of scope, as described in [Threat model and limits](docs/ARCHITECTURE.md#threat-model-and-limits):

- A malicious process running as the same macOS user. It can read the same key and token files the app writes; the app's checks separate enrolled clients, not processes of one user.
- What an AI agent, or its provider, does with data you allowed it to read.
- The security of a tunnel provider, or a tunnel you left running or misconfigured.
- An attacker with physical access, an administrator account, or a Mac with System Integrity Protection turned off.

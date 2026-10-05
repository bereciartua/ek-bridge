# Historical signed XPC candidate

This directory contains **source-only design exploration**, not the active EventKit Bridge transport. The current app uses signed JSON requests through a private per-user file exchange, described in [the active architecture](../docs/ARCHITECTURE.md). It has been installed and exercised locally; this XPC candidate has **not** been installed, registered, or connected to EventKit. Do not read this note as a deployment procedure.

The MCP adapter this note anticipated is now implemented differently: a local MCP server inside the app, over loopback HTTP with per-client tokens (see [the active architecture](../docs/ARCHITECTURE.md)). The XPC candidate remains historical.

`SignedXPCBoundary.swift` builds a code-signing requirement that pins a client identifier and leaf certificate hash. `Tests/SignedXPCBoundaryTests.swift` parses the requirement and checks one ad hoc signed matching executable against another with a wrong identifier. That is an **offline requirement test**, not a live XPC listener/client test and not proof of privacy-permission continuity.

The candidate considered a named Mach service registered through a user login agent. That would require a packaging, service lifecycle, and migration design distinct from the current `SMAppService.mainApp` login registration. A separate helper might get a different TCC identity; a main-app listener would need a single-instance plan. Neither path is implemented here. A cloud task still cannot directly call a local Mach service.

Signed peer checks could improve transport provenance, but they do not alone protect private reads from a malicious process running as the same macOS user: that process may be able to launch a signed client or access same-user state. An XPC or MCP design would need a fresh threat review of the signed CLI, credential custody, task-runner authorization, request scope, error handling, and EventKit permission boundary.

The candidate's older per-write approval-sheet concept is also **not the current grant policy**. In the active app, the local user saves collection/action grants, and supported writes proceed while the bridge is enabled unless the client is set to **Ask before changes**, which shows the app's own approval panel for each write. The caller must still be authorized for each real user task. See [the user guide](../docs/USAGE.md) and [API reference](../docs/API.md) for the implemented behavior.

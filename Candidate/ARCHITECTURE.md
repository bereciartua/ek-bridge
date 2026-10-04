# Signed XPC candidate — source only

This directory is a review candidate. It has not been installed, registered,
launched, or signed with Martin's Keychain identity. The installed app still
uses the attended 15-minute file bridge and starts with that bridge off.

## What the offline code proves

- `SignedXPCBoundary` constructs a requirement that pins both the signing
  identifier and leaf certificate hash. A future listener would set this with
  `xpc_connection_set_peer_code_signing_requirement` **before** activation,
  check the peer's effective UID, and reject any failed setup. The client
  would pin the server in the same way. The local SDK exposes this API on
  macOS 12 and later. A test parses the requirement and checks that an
  ad hoc test executable with a different identifier fails a static code
  requirement. The test does not validate the real self-signed certificate
  or an actual XPC connection.
- `ExactActionApproval` accepts a version-2 write proposal only from a
  transport that has verified the peer. It binds the proposal to an app-launch
  epoch and one request ID, validates strict command shape and selected
  target, retains exact request bytes and their digest, and issues a single
  in-memory approval ticket. Approval rechecks expiry and target generation
  and consumes the ticket. Cancellation, app restart, and target changes
  cannot turn a pending proposal into an automatic write.
- `ExactActionApprovalUI` is a source-only AppKit sheet. It shows the action,
  collection, existing item summary for edits/deletions, proposed title and
  times, and request digest. The app must resolve the collection and existing
  item from EventKit and hold the exact proposed bytes through approval.
  The XPC interface must expose proposal and reply methods only; it must not
  expose `approve`, `cancel`, or EventKit mutation methods to the client.

These parts are **not wired together or operational**. No Mach listener,
signed client executable, EventKit approval execution path, or remembered
read mode has been deployed. The AppKit sheet has been typechecked, not shown
in a live app. The offline tests use a mocked `peerVerified` value for the
approval policy and separate ad hoc binaries for the identifier requirement.

## Required transport and signing decision

A named Mach service needs a launchd registration. The local SDK documents
`SMAppService.agent(plistName:)` with a plist in
`Contents/Library/LaunchAgents`; a launchd `MachServices` entry advertises
the name. Registering this would create an additional persistent login agent
or replace the current main-app login registration. It is a new authorization
boundary, not a consequence of the existing Launch at Login approval.

The smallest candidate is to have the current app executable own the named
service as a user LaunchAgent, while keeping EventKit and approval UI in the
same process. This might preserve its TCC identity, but that has not been
verified. It also needs a single-instance plan so manually opening the app
does not race the agent. A separate helper would have its own signing and
possibly TCC identity, adding another permission migration. Choose and
review the packaging before writing deployment or migration code.

The listener must require the signed client's identifier **and** certificate
hash; the client must require the app's identifier and certificate hash. A
same-cert update can preserve those requirements. The real self-signed
certificate, XPC enforcement, registration, and TCC continuity still require
user-assisted live tests. A Developer ID identity would be a separate signing
choice. No private key is stored in this repository.

## Same-user limit and read decision

Peer verification proves which executable sent an XPC message, but another
process running as Martin can launch a signed command-line client and supply
it arguments. If that client offers arbitrary scoped reads, it can be used
as a deputy to extract them. The proposed XPC layer therefore improves
transport integrity, but **does not by itself isolate remembered reads from
other same-user processes**. It would replace the copyable `/tmp` token, yet
an unrestricted signed client can recreate the same practical exposure.

Remembered read scope remains off by default and is not implemented here.
Enabling it requires Martin to choose the exact calendar/list, returned
fields, and whether it resumes after login or wake, and to accept this
same-user exposure. If he wants reads private to dot rather than to the
macOS user account, the supported local task route needs an attestable caller
identity or another OS-enforced boundary. Until that exists, retain attended
read windows. A cloud task cannot directly call a local Mach service, and an
offline, asleep, or logged-out Mac cannot be assumed to run a local task.

For writes, the signed client may propose an action, but the app must show
the exact parsed change and require one explicit local approval. After
approval it must pass the retained request to EventKit's existing journal,
expected-version, and target checks. No write approval survives app restart,
target change, expiry, or cancellation. A user who cannot see the app (for
example while locked) cannot approve a new write until they return.

## Before any deployment approval

1. Review and choose the LaunchAgent packaging and migration from the
   existing main-app login item, including single-instance behavior.
2. Review the signed client invocation surface and same-user read risk.
3. Complete the XPC listener/client wiring and EventKit execution path,
   with the read mode off and no global write arm in daily mode.
4. Run a supervised live test of correct and wrong signed clients, request
   tampering and replay, expiry, cancellation, target changes, restart,
   permission persistence, lock, sleep/wake, and logout/relogin. Use only
   synthetic items until the whole path is verified.

No new agent registration, signing with Martin's key, permission prompt,
automatic read availability, or real-item operation is authorized by this
source-only work.

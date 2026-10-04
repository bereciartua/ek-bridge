# EventKit Bridge

A small, user-operated macOS app for testing native Calendar and Reminders
permissions without GUI automation of Apple's apps. Version 0.1 can show
authorization state, request access when its buttons are pressed, and list only
calendar or Reminders-list **name, ID, and writability** after full access has
been granted. It does not read or change any event or reminder item.

## Build

This Mac has Command Line Tools and Swift 6.4. Its default macOS 27 SDK does
not match the installed compiler, so `build.sh` uses its installed 26.5 SDK.

```sh
sh build.sh
```

This creates `build/EventKitBridge.app` inside the project. Set
`EVENTKIT_OUTPUT_DIR="$PWD/build/prototype"` to build at a separate path and
preserve an already granted app while testing a new version. Run `sh test.sh`
for the isolated request-validation checks. The default ad hoc
signature is for compilation checks only; **do not use it as a durable TCC
identity**. For a user-approved signing test, pass an existing, reviewed
Apple signing identity as `EVENTKIT_SIGN_IDENTITY` to `build.sh`. The script
does not create or fetch any certificate. Keep the bundle identifier
`dev.martin.dot.eventkitbridge` and signing identity stable across versions.
Review the signature and entitlement with `codesign --display --verbose=4
--entitlements - build/EventKitBridge.app` and verify with `codesign --verify
--verbose=2 build/EventKitBridge.app`.

## Access and current limits

- The app is launched independently by the user through the normal macOS app
  lifecycle. No installation or launch has been performed as part of this
  project yet.
- Calendar and Reminders requests are separate button actions. The user
  decides each macOS permission prompt. Full access is broader than the app's
  current list operation; it could permit item access to this app.
- List results are displayed only in the app window after the corresponding
  List button is pressed. The local bridge returns counts and permission
  status only; it never returns titles or IDs. No analytics, network listener,
  login item, or startup service is implemented.
- An independent app process and its TCC attribution must be verified on
  the test Mac before any permission is granted. An earlier CLI prototype failed
  inside the local task sandbox; that result does not establish this app's
  runtime behavior.

## Temporary local counts bridge

The user must press **Enable for 15 Minutes** in the running app. While enabled,
an in-process timer checks a local folder under `/tmp/eventkit-bridge-<uid>`.
It accepts only `authorization_status`, `calendar_count`, and
`reminder_list_count`. A local task can call one command at a time with:

```sh
python3 client.py authorization_status
python3 client.py calendar_count
python3 client.py reminder_list_count
```

Requests and replies are small JSON files written with atomic renames. The
folder is owned by the current Mac user and mode 0700; files are mode 0600.
The app checks file ownership, type, size, command, one-time request ID, token,
and timestamp. A random session token is stored in `current.json`, read by the
client without printing it, and expires after 15 minutes. **Disable** removes
the session files immediately. A crash may leave expired files in `/tmp`; the
token cannot authorize a request after its expiry.

This is a bounded same-user proof of concept, not strong isolation from other
apps running as the same Mac user: they could read the temporary token. It
must not expose item contents or writes. No app group, Mach service, network
socket, daemon, or background startup is used. The app must remain running and
the Mac must remain awake. A lock-screen test is meaningful only after an
unlocked baseline succeeds; sleep and logout are separate, untested cases.
Dot's cloud computer has no direct access to the Mac's localhost and cannot
work through this app while the Mac is offline.

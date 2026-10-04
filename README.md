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

This creates `build/EventKitBridge.app` inside the project. The default ad hoc
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
  List button is pressed. No analytics, network access, listener, login item,
  or file output is implemented.
- An independent app process and its TCC attribution must be verified on
  the test Mac before any permission is granted. An earlier CLI prototype failed
  inside the local task sandbox; that result does not establish this app's
  runtime behavior.

## Future local task bridge

The next version needs a separately approved, narrow communication boundary
between a local Work/Codex task and this user-owned app. It should authenticate
the local caller, allow only named operations, limit returned fields, require
specific user instructions for writes, and keep audit output free of private
items. A future on-demand local IPC channel would be evaluated before any
listener or persistent service is installed. Dot's cloud computer has no
direct access to the Mac's localhost and cannot work through this app while
the Mac is offline.

# Setup, signing, and macOS access

This guide describes the source build and the local choices needed before using real Calendar or Reminders data. It is not an installer. Work on a Mac you control, with a logged-in graphical session for the menu bar UI.

## Requirements

- macOS 14 or later according to `Info.plist`. Development has been exercised on one Mac with the macOS 26.5 SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; `build.sh` and `test.sh` currently hardcode that path. Other SDK versions are not validated by these scripts.
- Xcode Command Line Tools with `xcrun`, `swiftc`, `clang`, `codesign`, and the AppKit, SwiftUI, EventKit, Security, and ServiceManagement frameworks. The app targets macOS 14 (`build.sh` passes `-target arm64-apple-macosx14.0`).
- Python 3 for the small `client.py` launcher and test syntax check.
- A Calendar and/or Reminders account already configured in macOS if you want to use synced collections. Provider behavior can differ.

From the repository root:

```sh
sh test.sh
sh build.sh
codesign --verify --deep --strict build/EventKitBridge.app
```

`build.sh` writes only to ignored `build/`. It makes `build/EventKitBridge.app` and `build/bridge-client`, and signs the app ad hoc by default. `test.sh` compiles and runs offline tests and ad hoc XPC requirement fixtures; it does not need Calendar or Reminders data. `ui_test.sh` is a separate logged-in GUI fixture using fake clients and collections; `ui_snapshots.sh` writes PNGs of every screen from the same fake data.

## Signing and installation

**Choose a stable signing identity before you rely on macOS privacy grants.** The build script accepts `EVENTKIT_SIGN_IDENTITY` as a `codesign` identity; with no value it uses `-` (ad hoc). A personally built prototype may use a local identity. Public distribution needs its own signing, notarization, and update plan; this repository does not provide one.

For example, after you have chosen your own code-signing identity:

```sh
EVENTKIT_SIGN_IDENTITY='<your code-signing identity>' sh build.sh
codesign --verify --deep --strict build/EventKitBridge.app
```

`Info.plist` currently contains a development bundle identifier. If you change the identifier or signing identity, treat the resulting app as a different macOS privacy identity and expect to review access again. Keep the bundle identifier, signing identity, and installed location stable across updates when testing permission continuity. Quit a running copy before replacing it. Do not run two bridge processes against one local directory. Install the reviewed app in `~/Applications` or `/Applications` if you want this app's **Launch at Login** control; the code enables that control only for those locations. Launch the installed copy through Finder or LaunchServices. Keep the matching `bridge-client` built from the same source revision.

The source `Info.plist` leaves `EKBridgeVerifiedICloudReminderSourceID` empty. This intentionally disables the narrow recurring-occurrence completion path. A verified source ID is a **local signed-build configuration**, not a sample value to copy from another Mac or commit to source control. See [the support matrix](API.md#support-matrix).

## macOS permissions and first run

1. Open the installed app. On first launch its window opens on a setup checklist; later, open it from the menu bar icon (**Open EventKit Bridge…**, ⌘O).
2. In the checklist (or Overview ▸ macOS access), choose **Allow Access…** for Calendars and/or Reminders and answer the macOS prompts yourself. The app requires **Full Access** for item operations; add-only access isn't enough. If access was turned off, **Open Privacy Settings** opens **System Settings → Privacy & Security → Calendars / Reminders**.
3. Create a client and choose its calendars and lists, as described in [the user guide](USAGE.md). A new client has no access and the bridge is still off.
4. Turn on the bridge (the switch on Overview or in the menu) only when you want local tasks to use saved access. The choice is saved; turning it off saves that too.
5. Send the test request the checklist offers. Settings ▸ Developer (off by default) lists every calendar and list ID EventKit can see.

The app uses [`EKEventStore.requestFullAccessToEvents`](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)) and the corresponding Reminders API. Its `Info.plist` contains privacy usage descriptions. Its shipped `Entitlements.plist` is part of the build; changing entitlements or packaging needs a fresh permission test. Never copy another user's TCC database or signing key.

## Launch at Login

Turn on **Settings ▸ General ▸ Start at login**. This uses [`SMAppService.mainApp`](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp). The switch is available only when the app is in `/Applications` or `~/Applications`; if macOS needs approval, Settings says so and offers **Open Login Items**. Registration is separate from enabling the bridge. At login, the app reads its saved bridge choice; if the bridge was off, startup leaves it off. If you want it off before a restart, turn it off first.

A supervised restart on the development Mac showed the app process and scoped read-only bridge active after login, with Full access and the same grants. This does not prove operation before login or while the Mac is asleep. A remote cloud process cannot call the local bridge directly. See [verification and remaining checks](TESTING.md).

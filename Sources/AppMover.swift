import AppKit
import Security

/// The outcome of Move to Applications. `moving` means the copy is in place
/// and the app is about to relaunch from it.
enum MoveResult: Equatable {
    case moving
    case failed(String)
}

/// Move to Applications (F16): copy the running app into Applications,
/// check the copy's signature, remove the quarantine flag, relaunch from
/// there, and clean up the old copy. Every step is reversible: an app in the
/// way and the old copy go to the Trash, never deleted, and anything unclear
/// stops the move. The live-test copy never touches a bundle named like the
/// installed app (`LiveTestIsolation.mayModifyBundle`).
@MainActor
enum AppMover {
    /// Passed to the relaunched copy: the old location, and the process to
    /// wait for.
    static let movedFromArgument = "--moved-from"
    static let waitForArgument = "--wait-for-pid"

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var location: InstallLocation {
        let running = Bundle.main.bundleURL
        return InstallLocation.classify(bundlePath: running.path, home: home,
                                        originalPath: translocationOriginal(of: running))
    }

    /// Where a translocated app really is. `SecTranslocateCreateOriginalPathForURL`
    /// isn't in the public headers, so it's looked up at run time (as LetsMove
    /// does); nil when it's missing or the app isn't translocated.
    static func translocationOriginal(of url: URL) -> String? {
        guard url.path.contains("/AppTranslocation/"),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: Function.self)
        return (function(url as CFURL, nil)?.takeRetainedValue() as URL?)?.path
    }

    /// Copies, checks and relaunches. `prepareToQuit` runs once the new copy
    /// is ready; it quits this one (waiting for changes in the approval
    /// panel first).
    static func move(prepareToQuit: @escaping () -> Void) -> MoveResult {
        let location = location
        guard location != .applications else { return .failed(String(localized: "It's already in Applications.")) }
        let running = Bundle.main.bundleURL.standardizedFileURL.path
        guard let source = location.sourcePath(running: running) else {
            return .failed(String(localized: "macOS didn't say where \(AppIdentity.displayName) was opened from. Drag it to Applications in Finder, then open it from there."))
        }
        let manager = FileManager.default
        let destination = InstallLocation.destination(bundleFileName: AppIdentity.bundleFileName,
                                                      applicationsWritable: manager.isWritableFile(atPath: "/Applications"),
                                                      home: home)
        guard LiveTestIsolation.mayModifyBundle(atPath: destination),
              LiveTestIsolation.mayModifyBundle(atPath: source) else {
            return .failed(String(localized: "The test copy never replaces or moves EK Bridge itself."))
        }
        guard let team = teamIdentifier(of: Bundle.main.bundleURL) ?? allowedWithoutTeam else {
            return .failed(String(localized: "This copy isn't signed by a developer, so its copy can't be checked. Drag it to Applications in Finder instead."))
        }

        // Something already there: only an older EK Bridge that isn't running
        // may go, and only to the Trash.
        let destinationURL = URL(fileURLWithPath: destination)
        if manager.fileExists(atPath: destination) {
            guard Bundle(url: destinationURL)?.bundleIdentifier == AppIdentity.bundleID else {
                return .failed(String(localized: "Something else named \(AppIdentity.bundleFileName) is in \((destination as NSString).deletingLastPathComponent). Move it away first."))
            }
            let me = ProcessInfo.processInfo.processIdentifier
            let other = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
                .contains { $0.processIdentifier != me && $0.bundleURL?.standardizedFileURL.path == destination }
            if other { return .failed(String(localized: "Quit the other copy first.")) }
            do {
                try manager.trashItem(at: destinationURL, resultingItemURL: nil)
            } catch {
                return .failed(String(localized: "The copy already in Applications couldn't be moved to the Trash."))
            }
        }

        do {
            try manager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
            try manager.copyItem(atPath: source, toPath: destination)
        } catch {
            try? manager.trashItem(at: destinationURL, resultingItemURL: nil)
            return .failed(String(localized: "The copy couldn't be made: \((error as NSError).localizedDescription)"))
        }
        guard verify(destinationURL, team: team) else {
            try? manager.trashItem(at: destinationURL, resultingItemURL: nil)
            return .failed(String(localized: "The copy's signature didn't check out, so it was moved to the Trash."))
        }
        removeQuarantine(destination)

        // The old copy is the relaunched copy's job (`cleanUpOldCopy`): a
        // disk image is offered for ejecting, anything else goes to the
        // Trash. Moving a file out of Downloads can make macOS ask first,
        // which mustn't hold up this copy's quitting.

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [movedFromArgument, location.leavesVolume ?? source,
                                   waitForArgument, String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: destinationURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil { prepareToQuit() }
            }
        }
        return .moving
    }

    #if DEBUG || EVENTKIT_UI_REVIEW
    private static let allowedWithoutTeam: String? = ""
    #else
    private static let allowedWithoutTeam: String? = nil
    #endif

    /// The signing team of a bundle, or nil for ad hoc signatures.
    static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The copy's signature is valid, sealed, and by the same team as this app.
    static func verify(_ url: URL, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        if !team.isEmpty {
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
            guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return false }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Removes the quarantine flag from the copy, as dragging it out of a disk
    /// image does, so Gatekeeper doesn't translocate it again.
    static func removeQuarantine(_ path: String) {
        let name = "com.apple.quarantine"
        removexattr(path, name, XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(atPath: path) else { return }
        for case let item as String in items {
            removexattr((path as NSString).appendingPathComponent(item), name, XATTR_NOFOLLOW)
        }
    }

    /// In the relaunched copy: waits (up to 15 s) for the old one to quit, so
    /// the two never run at once.
    static func waitForPreviousCopy(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: waitForArgument), index + 1 < arguments.count,
              let pid = pid_t(arguments[index + 1]), pid != ProcessInfo.processInfo.processIdentifier else { return }
        let deadline = Date().addingTimeInterval(15)
        while kill(pid, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// In the relaunched copy: moves the old copy (`--moved-from`, not on a
    /// disk image) to the Trash, off the main thread because macOS may ask
    /// for access to its folder first. Reports whether it went.
    static func cleanUpOldCopy(_ path: String, completion: @escaping @MainActor (Bool) -> Void) {
        let running = Bundle.main.bundleURL.standardizedFileURL.path
        let old = (path as NSString).standardizingPath
        guard InstallLocation.volume(of: old) == nil, old != running,
              (old as NSString).lastPathComponent == AppIdentity.bundleFileName,
              LiveTestIsolation.mayModifyBundle(atPath: old),
              Bundle(path: old)?.bundleIdentifier == AppIdentity.bundleID else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let trashed = (try? FileManager.default.trashItem(at: URL(fileURLWithPath: old), resultingItemURL: nil)) != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(trashed) } }
        }
    }

    /// The `--moved-from` path the relaunched copy was given.
    static func movedFrom(arguments: [String] = CommandLine.arguments) -> String? {
        guard let index = arguments.firstIndex(of: movedFromArgument), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

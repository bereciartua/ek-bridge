import Darwin
import Foundation

// RenameMigration with two throwaway defaults suites and a temporary
// Application Support folder.
@main
struct RenameMigrationTests {
    static var checks = 0

    static func main() throws {
        try freshInstall()
        try fullMigration()
        try settingsOnly()
        try interruptedLaunch()
        try conflictLeavesEverything()
        try unwritableSupportFolder()
        try alreadyLinked()
        try toolFallback()
        print("Rename migration: \(checks) fresh, move, settings, conflict, failure and tool fallback checks passed")
    }

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    struct Fixture {
        let support: URL
        let defaults: UserDefaults
        let legacy: UserDefaults
        private let names: [String]

        init() throws {
            support = FileManager.default.temporaryDirectory
                .appendingPathComponent("ek-bridge-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            names = ["ek-bridge-migration-new-\(UUID().uuidString)", "ek-bridge-migration-old-\(UUID().uuidString)"]
            defaults = UserDefaults(suiteName: names[0])!
            legacy = UserDefaults(suiteName: names[1])!
        }

        var migration: RenameMigration {
            RenameMigration(defaults: defaults, legacyDefaults: legacy, support: support)
        }
        var old: URL { support.appendingPathComponent("EventKitBridge", isDirectory: true) }
        var new: URL { support.appendingPathComponent("EKBridge", isDirectory: true) }

        func makeOldFolder() throws {
            try makePrivateFolder(old)
            try makePrivateFolder(old.appendingPathComponent("client-credentials"))
            try makePrivateFolder(old.appendingPathComponent("write-journal"))
            try write("{\"version\":4}", old.appendingPathComponent("client-registry.json"))
            try write("{\"secret\":\"x\"}", old.appendingPathComponent("client-credentials/aaaa.json"))
            try write("{}", old.appendingPathComponent("write-journal/shard.json"))
        }

        func cleanUp() {
            for name in names { UserDefaults().removePersistentDomain(forName: name) }
            chmod(support.path, 0o700)
            try? FileManager.default.removeItem(at: support)
        }
    }

    static func makePrivateFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func write(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url)
        chmod(url.path, 0o600)
    }

    static func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o777
    }

    static func freshInstall() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        check(!f.migration.isPending, "fresh: nothing pending")
        check(f.migration.run() == .nothingToMigrate, "fresh: nothing to migrate")
        check(f.defaults.integer(forKey: RenameMigration.doneKey) == 1, "fresh: recorded")
        check(f.defaults.object(forKey: RenameMigration.noticeKey) == nil, "fresh: no notice")
        check(!FileManager.default.fileExists(atPath: f.new.path), "fresh: no folder created")
        check(!FileManager.default.fileExists(atPath: f.old.path), "fresh: no link created")
        check(f.migration.run() == .alreadyDone, "fresh: second run does nothing")
    }

    static func fullMigration() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.makeOldFolder()
        f.legacy.set(true, forKey: "DurableLocalBridgeEnabled")
        f.legacy.set("always", forKey: "DockIconMode")
        f.legacy.set(true, forKey: "MCPServerEnabled")
        f.legacy.set(48_000, forKey: "MCPServerPort")
        f.legacy.set(["https://example.com"], forKey: "MCPServerAllowedOrigins")
        f.legacy.set("q7Zk2vN4bXwP9sL1mT6hYa", forKey: "RemoteAccessSecretPath")
        f.legacy.set([3], forKey: "SetupChecklistSkipped")
        f.legacy.set(true, forKey: "SetupChecklistCompleted")
        f.legacy.set(true, forKey: "SetupChecklistHidden")
        f.legacy.set("1 2 900 640 0 0 2560 1410 ", forKey: "NSWindow Frame MainWindow")
        f.legacy.set(["outcome": "passed"], forKey: "durableSyntheticLastResult")
        // A value the new domain already has wins.
        f.defaults.set(47_000, forKey: "MCPServerPort")

        check(f.migration.isPending, "full: pending")
        let outcome = f.migration.run()
        check(outcome == .migrated(settings: 7, movedData: true), "full: outcome \(outcome)")

        check(RenameMigration.isRealDirectory(f.new), "full: new folder is a real folder")
        check(mode(f.new) == 0o700, "full: folder stays private")
        check(read(f.new.appendingPathComponent("client-registry.json")) == "{\"version\":4}", "full: registry moved")
        check(read(f.new.appendingPathComponent("client-credentials/aaaa.json")) == "{\"secret\":\"x\"}",
              "full: key file moved")
        check(mode(f.new.appendingPathComponent("client-credentials/aaaa.json")) == 0o600, "full: key file stays private")
        check(read(f.new.appendingPathComponent("write-journal/shard.json")) == "{}", "full: journal moved")
        check(RenameMigration.isSymlink(f.old), "full: old path is a link")
        check((try? FileManager.default.destinationOfSymbolicLink(atPath: f.old.path)) == "EKBridge",
              "full: link is relative")
        check(read(f.old.appendingPathComponent("client-credentials/aaaa.json")) == "{\"secret\":\"x\"}",
              "full: old key path still reads")

        check(f.defaults.bool(forKey: "DurableLocalBridgeEnabled"), "full: bridge on copied")
        check(f.defaults.string(forKey: "DockIconMode") == "always", "full: Dock copied")
        check(f.defaults.integer(forKey: "MCPServerPort") == 47_000, "full: existing value kept")
        check(f.defaults.stringArray(forKey: "MCPServerAllowedOrigins") == ["https://example.com"], "full: array copied")
        check(f.defaults.string(forKey: "RemoteAccessSecretPath") == "q7Zk2vN4bXwP9sL1mT6hYa", "full: secret path copied")
        check(f.defaults.array(forKey: "SetupChecklistSkipped") as? [Int] == [3], "full: skipped steps copied")
        check(f.defaults.string(forKey: "NSWindow Frame MainWindow") != nil, "full: window frame copied")
        check(f.defaults.object(forKey: "SetupChecklistCompleted") == nil, "full: checklist comes back")
        check(f.defaults.object(forKey: "SetupChecklistHidden") == nil, "full: checklist isn't hidden")
        check(f.defaults.object(forKey: "durableSyntheticLastResult") == nil, "full: test results stay behind")
        check(f.defaults.bool(forKey: RenameMigration.noticeKey), "full: notice pending")
        check(f.legacy.string(forKey: "DockIconMode") == "always", "full: old domain untouched")

        check(!f.migration.isPending, "full: nothing pending afterwards")
        check(f.migration.run() == .alreadyDone, "full: second run does nothing")
        check(read(f.new.appendingPathComponent("client-registry.json")) == "{\"version\":4}", "full: still there")
    }

    static func settingsOnly() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        f.legacy.set("settings", forKey: "LastPane")
        check(f.migration.isPending, "settings: pending")
        check(f.migration.run() == .migrated(settings: 1, movedData: false), "settings: outcome")
        check(!FileManager.default.fileExists(atPath: f.old.path), "settings: no link without a folder")
        check(f.defaults.string(forKey: "LastPane") == "settings", "settings: copied")
        check(f.defaults.bool(forKey: RenameMigration.noticeKey), "settings: notice pending")
    }

    static func interruptedLaunch() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.makeOldFolder()
        try makePrivateFolder(f.new)
        try write("", f.new.appendingPathComponent(".DS_Store"))
        check(f.migration.run() == .migrated(settings: 0, movedData: true), "interrupted: an empty folder is replaced")
        check(read(f.new.appendingPathComponent("client-registry.json")) == "{\"version\":4}", "interrupted: moved")
    }

    static func conflictLeavesEverything() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.makeOldFolder()
        try makePrivateFolder(f.new)
        try write("{\"version\":4,\"new\":true}", f.new.appendingPathComponent("client-registry.json"))
        f.legacy.set("always", forKey: "DockIconMode")
        guard case .failed(let problem) = f.migration.run() else { preconditionFailure("conflict: should fail") }
        check(problem.contains("EventKitBridge") && problem.contains("EKBridge"), "conflict: names both folders")
        check(RenameMigration.isRealDirectory(f.old), "conflict: old folder untouched")
        check(read(f.new.appendingPathComponent("client-registry.json"))?.contains("new") == true,
              "conflict: new folder untouched")
        check(f.defaults.object(forKey: RenameMigration.doneKey) == nil, "conflict: not recorded")
        check(f.defaults.object(forKey: "DockIconMode") == nil, "conflict: settings not copied")
        check(f.defaults.object(forKey: RenameMigration.noticeKey) == nil, "conflict: no notice")
        check(f.migration.isPending, "conflict: still pending")
    }

    static func unwritableSupportFolder() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.makeOldFolder()
        chmod(f.support.path, 0o500)
        guard case .failed(let problem) = f.migration.run() else { preconditionFailure("unwritable: should fail") }
        chmod(f.support.path, 0o700)
        check(problem.contains("couldn't be renamed"), "unwritable: explains")
        check(RenameMigration.isRealDirectory(f.old), "unwritable: old folder untouched")
        check(f.defaults.object(forKey: RenameMigration.doneKey) == nil, "unwritable: not recorded")
        // Once fixed, the next launch completes it.
        check(f.migration.run() == .migrated(settings: 0, movedData: true), "unwritable: retry succeeds")
    }

    static func alreadyLinked() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try makePrivateFolder(f.new)
        symlink("EKBridge", f.old.path)
        check(!f.migration.isPending, "linked: a link isn't a folder to move")
        check(f.migration.run() == .nothingToMigrate, "linked: nothing to migrate")
        check(RenameMigration.isSymlink(f.old), "linked: link kept")
    }

    static func toolFallback() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        check(AppIdentity.toolDataFolder(inSupport: f.support) == f.new, "tools: neither folder → new")
        try f.makeOldFolder()
        check(AppIdentity.toolDataFolder(inSupport: f.support) == f.old, "tools: only the old folder → old")
        check(AppIdentity.dataFolder(inSupport: f.support) == f.new, "app: always the new folder")
        _ = f.migration.run()
        check(AppIdentity.toolDataFolder(inSupport: f.support) == f.new, "tools: after the move → new")
    }
}

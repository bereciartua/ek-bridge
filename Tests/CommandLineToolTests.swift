import Foundation

@main
struct CommandLineToolTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("eventkit-cli-tool-test-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let app = root.appendingPathComponent("Apps/EKBridge.app")
        let other = root.appendingPathComponent("Old/EventKitBridge.app")
        try files.createDirectory(at: home, withIntermediateDirectories: true)

        let brew = root.appendingPathComponent("homebrew/bin")
        let tool = CommandLineTool(appURL: app, home: home, packageBins: [brew])
        precondition(tool.linkURL.path == home.path + "/.local/bin/bridge-client")
        precondition(tool.bundledURL.path == app.path + "/Contents/MacOS/bridge-client")

        // No bundled binary: nothing to link, and commands use the source launcher.
        precondition(tool.state == .unavailable)
        precondition(tool.program == .source && tool.program.text == "python3 client.py")
        precondition(tool.install() == .failure(.unavailable))
        precondition((try? files.attributesOfItem(atPath: tool.linkURL.path)) == nil)

        try executable(at: tool.bundledURL)
        precondition(tool.state == .notInstalled)
        // Not linked anywhere: commands run this copy's bridge-client by its full path.
        precondition(tool.program == .bundled(path: tool.bundledURL.path))
        precondition(tool.program.text == tool.bundledURL.path, "a path without spaces isn't quoted")
        precondition(!tool.linkedByPackageManager)

        // Homebrew's link to this copy puts bridge-client on the PATH, without
        // changing what Settings reports or installs.
        try files.createDirectory(at: brew, withIntermediateDirectories: true)
        let brewLink = brew.appendingPathComponent("bridge-client")
        try files.createSymbolicLink(at: brewLink, withDestinationURL: tool.bundledURL)
        precondition(tool.state == .notInstalled)
        precondition(tool.program == .onPath && tool.program.text == "bridge-client")
        precondition(tool.linkedByPackageManager)
        // Homebrew's link to another copy doesn't count.
        try files.removeItem(at: brewLink)
        try files.createSymbolicLink(at: brewLink, withDestinationURL: other.appendingPathComponent("Contents/MacOS/bridge-client"))
        precondition(tool.program == .bundled(path: tool.bundledURL.path) && !tool.linkedByPackageManager)
        // Neither does a regular file there.
        try files.removeItem(at: brewLink)
        try Data("#!/bin/sh\n".utf8).write(to: brewLink)
        precondition(tool.program == .bundled(path: tool.bundledURL.path))
        try files.removeItem(at: brewLink)

        // Creates ~/.local/bin and the link.
        precondition(tool.install() == .success(tool.linkURL))
        precondition(tool.state == .installed)
        precondition(tool.program == .onPath && !tool.linkedByPackageManager)
        let destination = try files.destinationOfSymbolicLink(atPath: tool.linkURL.path)
        precondition(destination == tool.bundledURL.path)
        precondition(tool.install() == .success(tool.linkURL), "installing again is harmless")
        precondition(tool.state == .installed)

        // A link to another copy of the app is replaced.
        let otherTool = CommandLineTool(appURL: other, home: home, packageBins: [brew])
        try executable(at: otherTool.bundledURL)
        precondition(otherTool.state == .elsewhere)
        precondition(otherTool.install() == .success(otherTool.linkURL))
        precondition(otherTool.state == .installed && tool.state == .elsewhere)
        precondition(tool.program == .bundled(path: tool.bundledURL.path), "a link to another copy doesn't run this one")

        // A dangling link counts as elsewhere and is replaced too.
        try files.removeItem(at: other)
        precondition(tool.state == .elsewhere)
        precondition(tool.install() == .success(tool.linkURL))
        precondition(tool.state == .installed)

        // A relative link that resolves to this copy counts as installed.
        try files.removeItem(at: tool.linkURL)
        try files.createSymbolicLink(atPath: tool.linkURL.path,
                                     withDestinationPath: "../../../Apps/EKBridge.app/Contents/MacOS/bridge-client")
        precondition(tool.state == .installed)

        // A regular file is never replaced.
        try files.removeItem(at: tool.linkURL)
        try Data("#!/bin/sh\n".utf8).write(to: tool.linkURL)
        precondition(tool.state == .elsewhere)
        precondition(tool.install() == .failure(.notALink))
        let kept = try String(contentsOf: tool.linkURL, encoding: .utf8)
        precondition(kept == "#!/bin/sh\n")

        // The displayed app path (the UI review build shows /Applications) and quoting.
        let shown = CommandLineTool(appURL: app, home: root.appendingPathComponent("empty-home"), packageBins: [],
                                    displayAppURL: URL(fileURLWithPath: "/Applications/EKBridge.app"))
        precondition(shown.program.text == "/Applications/EKBridge.app/Contents/MacOS/bridge-client")
        precondition(CommandLineTool.shellWord("/Users/a/My Apps/EKBridge.app/Contents/MacOS/bridge-client")
                     == "'/Users/a/My Apps/EKBridge.app/Contents/MacOS/bridge-client'")
        precondition(CommandLineTool.shellWord("/Users/o'neil/EKBridge.app") == #"'/Users/o'\''neil/EKBridge.app'"#)

        print("Command-line tool: unavailable, install, reinstall, other copy, dangling and relative links, file in the way, Homebrew links, copied-command program and quoting passed")
    }

    private static func executable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        chmod(url.path, 0o755)
    }
}

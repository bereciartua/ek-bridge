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

        let tool = CommandLineTool(appURL: app, home: home)
        precondition(tool.linkURL.path == home.path + "/.local/bin/bridge-client")
        precondition(tool.bundledURL.path == app.path + "/Contents/MacOS/bridge-client")

        // No bundled binary: nothing to link.
        precondition(tool.state == .unavailable)
        precondition(tool.install() == .failure(.unavailable))
        precondition((try? files.attributesOfItem(atPath: tool.linkURL.path)) == nil)

        try executable(at: tool.bundledURL)
        precondition(tool.state == .notInstalled)

        // Creates ~/.local/bin and the link.
        precondition(tool.install() == .success(tool.linkURL))
        precondition(tool.state == .installed)
        let destination = try files.destinationOfSymbolicLink(atPath: tool.linkURL.path)
        precondition(destination == tool.bundledURL.path)
        precondition(tool.install() == .success(tool.linkURL), "installing again is harmless")
        precondition(tool.state == .installed)

        // A link to another copy of the app is replaced.
        let otherTool = CommandLineTool(appURL: other, home: home)
        try executable(at: otherTool.bundledURL)
        precondition(otherTool.state == .elsewhere)
        precondition(otherTool.install() == .success(otherTool.linkURL))
        precondition(otherTool.state == .installed && tool.state == .elsewhere)

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

        print("Command-line tool: unavailable, install, reinstall, other copy, dangling and relative links, file in the way passed")
    }

    private static func executable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        chmod(url.path, 0o755)
    }
}

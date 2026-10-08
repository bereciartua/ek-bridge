import Foundation

// Move to Applications: where the app runs from, where the copy goes, and how
// the prompt names the place.
@main
struct InstallLocationTests {
    static let home = "/Users/someone"

    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        func classify(_ path: String, original: String? = nil) -> InstallLocation {
            InstallLocation.classify(bundlePath: path, home: home, originalPath: original)
        }

        check(classify("/Applications/EKBridge.app") == .applications, "Applications")
        check(classify("/Applications/Utilities/EKBridge.app") == .applications, "a subfolder of Applications")
        check(classify("/Users/someone/Applications/EKBridge.app") == .applications, "~/Applications")
        check(classify("/Volumes/Work/Applications/EKBridge.app") == .applications, "another volume's Applications")
        check(classify("/Volumes/EK Bridge/EKBridge.app") == .diskImage(volume: "/Volumes/EK Bridge"), "disk image")
        check(classify("/Volumes/EK Bridge/./EKBridge.app") == .diskImage(volume: "/Volumes/EK Bridge"),
              "standardized")
        check(classify("/Users/someone/Downloads/EKBridge.app") == .elsewhere(path: "/Users/someone/Downloads/EKBridge.app"),
              "Downloads")
        check(classify("/Applications.old/EKBridge.app") == .elsewhere(path: "/Applications.old/EKBridge.app"),
              "a look-alike folder isn't Applications")
        check(classify("/Users/other/Applications/EKBridge.app") == .elsewhere(path: "/Users/other/Applications/EKBridge.app"),
              "another user's Applications")

        let translocated = "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/EKBridge.app"
        check(classify(translocated, original: "/Users/someone/Downloads/EKBridge.app")
              == .translocated(original: "/Users/someone/Downloads/EKBridge.app"), "translocated with original")
        check(classify(translocated) == .translocated(original: nil), "translocated without original")
        check(classify(translocated).sourcePath(running: translocated) == nil, "no source without the original")
        check(classify("/Volumes/EK Bridge/EKBridge.app").sourcePath(running: "/Volumes/EK Bridge/EKBridge.app")
              == "/Volumes/EK Bridge/EKBridge.app", "the running copy is the source")

        check(InstallLocation.destination(bundleFileName: "EKBridge.app", applicationsWritable: true, home: home)
              == "/Applications/EKBridge.app", "Applications when writable")
        check(InstallLocation.destination(bundleFileName: "EK Bridge Test.app", applicationsWritable: false, home: home)
              == "/Users/someone/Applications/EK Bridge Test.app", "~/Applications otherwise")

        check(classify("/Users/someone/Downloads/EKBridge.app").placeName(home: home) == "Downloads", "Downloads name")
        check(classify("/Users/someone/Downloads/ek-test/EKBridge.app").placeName(home: home) == "Downloads",
              "a folder in Downloads")
        check(classify("/Users/someone/Desktop/EKBridge.app").placeName(home: home) == "the “Desktop” folder",
              "another folder")
        check(classify("/Volumes/EK Bridge/EKBridge.app").placeName(home: home) == "the disk image", "disk image")
        check(classify(translocated, original: "/Volumes/EK Bridge/EKBridge.app").placeName(home: home)
              == "the disk image", "translocated from a disk image")
        check(classify(translocated).placeName(home: home) == "a temporary location", "translocated")

        check(classify("/Volumes/EK Bridge/EKBridge.app").leavesVolume == "/Volumes/EK Bridge", "eject offer")
        check(classify(translocated, original: "/Volumes/EK Bridge/EKBridge.app").leavesVolume == "/Volumes/EK Bridge",
              "eject offer when translocated from a disk image")
        check(classify("/Users/someone/Downloads/EKBridge.app").leavesVolume == nil, "Downloads goes to the Trash")
        print("Install location: \(checks) classify, destination, prompt wording and cleanup checks passed")
    }
}

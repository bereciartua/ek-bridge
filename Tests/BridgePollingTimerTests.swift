import CoreFoundation
import Foundation

@main
struct BridgePollingTimerTests {
    static func main() {
        let modeName = "EKBridgeTestTracking"
        let cfModeName = CFStringCreateWithCString(
            nil, modeName, CFStringBuiltInEncodings.UTF8.rawValue)!
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: cfModeName))

        var defaultFired = false
        var bridgeFired = false
        let defaultTimer = Timer(timeInterval: 0.01, repeats: false) { _ in
            defaultFired = true
        }
        RunLoop.main.add(defaultTimer, forMode: .default)
        let bridgeTimer = BridgePollingTimer.schedule(interval: 0.01, repeats: false) { _ in
            bridgeFired = true
        }
        defer {
            defaultTimer.invalidate()
            bridgeTimer.invalidate()
        }

        let trackingMode = RunLoop.Mode(rawValue: modeName)
        _ = RunLoop.main.run(mode: trackingMode, before: Date().addingTimeInterval(0.2))
        precondition(bridgeFired, "bridge polling timer must run in a common tracking mode")
        precondition(!defaultFired, "default-mode timer should stay queued in tracking mode")
        print("Bridge polling timer: common-mode delivery passed")
    }
}

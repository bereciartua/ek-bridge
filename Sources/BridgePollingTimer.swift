import Foundation

enum BridgePollingTimer {
    static func schedule(
        interval: TimeInterval,
        repeats: Bool,
        block: @escaping (Timer) -> Void
    ) -> Timer {
        precondition(Thread.isMainThread)
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        // Menu tracking and modal UI can run the main loop outside default mode.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

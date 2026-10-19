import Foundation

// EK Bridge's words for BridgeKitRemote's KeepAwake and reachability test
// (the Remote Access page ▸ Test).

extension KeepAwake {
    /// "Keep this Mac awake while on power" (R7).
    static func remoteAccess() -> KeepAwake {
        KeepAwake(reason: "\(AppIdentity.displayName) Remote Access is on")
    }
}

/// The Remote Access page ▸ Test, in EK Bridge's words: the round trip and the
/// tunnel's name, or why it failed.
enum RemoteTest {
    @MainActor
    static func run(_ configuration: RemoteConfiguration, nonces: RemoteNonces,
                    completion: @escaping (Result<(rtt: TimeInterval, tunnel: String?), RemoteTestFailure>) -> Void) {
        RemoteProbe.test(configuration, nonces: nonces) { result in
            switch result {
            case .success(let value): completion(.success((value.rtt, value.tunnel?.name)))
            case .failure(let failure):
                completion(.failure(RemoteTestFailure(reason: reason(failure, port: configuration.port))))
            }
        }
    }

    static func reason(_ failure: RemoteProbeFailure, port: Int) -> String {
        switch failure {
        case .noAddress: String(localized: "Add the tunnel's address first.")
        case .invalidAddress: String(localized: "The address isn't valid.")
        case .timedOut: String(localized: "No answer within 10 seconds. Is the tunnel running?")
        case .cannotFindHost:
            String(localized: "The address doesn't resolve yet. A new address can take a few minutes (about 10 for Tailscale Funnel).")
        case .connectionRefused: String(localized: "The tunnel refused the connection.")
        case .certificateRejected: String(localized: "The tunnel's HTTPS certificate wasn't accepted.")
        case .requestFailed(let code): String(localized: "The request failed (\(code)).")
        case .wrongHost:
            String(localized: "The tunnel sent a different host name. Check the address, or set the tunnel to rewrite Host.")
        case .notThisApp(let status):
            String(localized: "Something answered at that address, but not \(AppIdentity.displayName) (HTTP \(status)). Check that the tunnel points at port \(String(port)).")
        case .noAnswer: String(localized: "No answer.")
        }
    }
}

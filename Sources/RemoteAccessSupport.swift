import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// "Keep this Mac awake while on power" (R7): an idle-sleep assertion held
/// only while Remote Access is on and the Mac runs on AC power. Closing the
/// lid still sleeps the Mac unless an external display is attached.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func set(_ on: Bool) {
        if on && !held {
            let reason = "\(AppIdentity.displayName) Remote Access is on" as CFString
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), reason,
                                               &assertion) == kIOReturnSuccess
        } else if !on && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }

    static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

/// Settings ▸ Remote Access ▸ Test: one HTTPS request to this app's own
/// health URL through the tunnel. The nonce proves the reply came from this
/// app, not from something else answering at that address.
enum RemoteProbe {
    @MainActor
    static func test(_ configuration: RemoteConfiguration, nonces: RemoteNonces,
                     completion: @escaping (Result<(rtt: TimeInterval, tunnel: String?), RemoteTestFailure>) -> Void) {
        guard let origin = configuration.publicOrigin else {
            return completion(.failure(RemoteTestFailure(reason: String(localized: "Add the tunnel's address first."))))
        }
        let nonce = nonces.issue()
        guard let url = URL(string: origin + configuration.secretPrefix + "/health?nonce=" + nonce) else {
            return completion(.failure(RemoteTestFailure(reason: String(localized: "The address isn't valid."))))
        }
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            return configuration
        }(), delegate: NoRedirects(), delegateQueue: nil)
        let started = Date()
        session.dataTask(with: url) { data, response, error in
            let rtt = Date().timeIntervalSince(started)
            let result: Result<(rtt: TimeInterval, tunnel: String?), RemoteTestFailure>
            if let error = error as? URLError {
                result = .failure(RemoteTestFailure(reason: describe(error)))
            } else if let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      body["nonce"] as? String == nonce {
                result = .success((rtt, body["tunnel"] as? String))
            } else if let http = response as? HTTPURLResponse {
                result = .failure(RemoteTestFailure(reason: http.statusCode == 421
                    ? String(localized: "The tunnel sent a different host name. Check the address, or set the tunnel to rewrite Host.")
                    : String(localized: "Something answered at that address, but not \(AppIdentity.displayName) (HTTP \(http.statusCode)). Check that the tunnel points at port \(String(configuration.port)).")))
            } else {
                result = .failure(RemoteTestFailure(reason: String(localized: "No answer.")))
            }
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: String(localized: "No answer within 10 seconds. Is the tunnel running?")
        case .cannotFindHost, .dnsLookupFailed:
            String(localized: "The address doesn't resolve yet. New Tailscale Funnel addresses can take about 10 minutes.")
        case .cannotConnectToHost: String(localized: "The tunnel refused the connection.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            String(localized: "The tunnel's HTTPS certificate wasn't accepted.")
        default: String(localized: "The request failed (\(error.code.rawValue)).")
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

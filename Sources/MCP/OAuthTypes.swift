import Foundation

/// An OAuth client's metadata document (Client ID Metadata Document, CIMD):
/// the client ID is an https URL that serves this JSON.
struct ClientMetadata: Equatable {
    /// Must equal the URL the document was fetched from.
    let clientID: String
    let clientName: String?
    let redirectURIs: [String]
    let clientURI: String?
}

enum CIMDError: Error, Equatable {
    /// Not an https URL, or it has a fragment, user info or no path.
    case invalidURL
    /// The host resolved to a private, loopback, link-local or other
    /// non-public address (SSRF guard).
    case blockedAddress
    case timedOut
    case tooLarge
    case redirected
    case httpStatus(Int)
    case invalidDocument(String)
    case network(String)

    /// One sentence for the browser page. Network details stay out of it.
    var reason: String {
        switch self {
        case .invalidURL: return "Its client ID isn’t an https URL with a host name and a path."
        case .blockedAddress: return "Its host name doesn’t resolve to a public internet address."
        case .timedOut: return "Its server didn’t answer within 5 seconds."
        case .tooLarge: return "The document is larger than 16 KB."
        case .redirected: return "Its server answered with a redirect, which isn’t followed."
        case .httpStatus(let status): return "Its server answered with HTTP status \(status)."
        case .invalidDocument(let why): return "The document isn’t valid: \(why)."
        case .network: return "Its server couldn’t be reached."
        }
    }
}

/// Fetches client metadata documents. The app's fetcher is the first
/// outbound HTTP the app makes, so it's tightly bounded (§22.6 of the plan).
@MainActor
protocol CIMDFetching: AnyObject {
    /// Calls `completion` once, on the main actor.
    func fetch(_ url: URL, completion: @escaping (Result<ClientMetadata, CIMDError>) -> Void)
}

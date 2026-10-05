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
}

/// Fetches client metadata documents. The app's fetcher is the first
/// outbound HTTP the app makes, so it's tightly bounded (§22.6 of the plan).
@MainActor
protocol CIMDFetching: AnyObject {
    /// Calls `completion` once, on the main actor.
    func fetch(_ url: URL, completion: @escaping (Result<ClientMetadata, CIMDError>) -> Void)
}

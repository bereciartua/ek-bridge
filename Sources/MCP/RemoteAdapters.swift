import Foundation

// EK Bridge on BridgeKitRemote: its prefixes, scope and wording for Remote
// Access, and its client registry behind the kit's RemoteAuthenticator. The
// listener, OAuth, client metadata and tunnel checks live in BridgeKitRemote.

extension EKBridgeMCP {
    /// The OAuth scope cloud apps are granted.
    static let remoteScope = "calendar"
    static let accessTokenPrefix = "ekb_oat_v1_"
    static let refreshTokenPrefix = "ekb_ort_v1_"
    static let clientSecretPrefix = "ekb_ocs_v1_"

    /// `remote-connections.json` lives in `dataFolder`, next to the registry.
    static func remoteConfiguration(dataFolder: URL) -> RemoteBridgeConfiguration {
        RemoteBridgeConfiguration(
            identity: configuration().identity, defaultPort: TunnelProvider.defaultRemotePort,
            remoteTokenPrefix: ClientRegistry.remoteTokenPrefix, accessTokenPrefix: accessTokenPrefix,
            refreshTokenPrefix: refreshTokenPrefix, clientSecretPrefix: clientSecretPrefix, scope: remoteScope,
            userAgentProduct: "EKBridge", storeDirectory: dataFolder,
            texts: .standard(displayName: AppIdentity.displayName, agent: "client"))
    }
}

/// Remote tokens and OAuth clients, checked against the registry: only
/// clients with cloud access on, and local MCP tokens never.
@MainActor
final class RegistryRemoteAuthenticator: RemoteAuthenticator {
    private let registry: ClientRegistry

    init(registry: ClientRegistry) { self.registry = registry }

    func authenticate(remoteToken: PresentedKey) async -> AuthenticationOutcome {
        EKBridgeMCP.outcome(registry.authenticateRemoteToken(remoteToken.value), registry: registry)
    }

    func cloudAccessAllowed(agentID: String) -> Bool { registry.cloudAccessAllowed(clientID: agentID) }

    func agentName(agentID: String) -> String? { registry.clients()?.first { $0.id == agentID }?.name }

    func recordFailedRemoteAuth() { registry.recordFailedRemoteAuth() }
}

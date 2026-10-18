// BridgeKit (https://github.com/bereciartua/bridgekit) holds the code EK Bridge
// shares with Funes Vault. BridgeKitCore: the MCP protocol and security core
// (the loopback HTTP server, MCP and JSON-RPC, keys, rate limits, safe files,
// the launcher and agent config writing). BridgeKitRemote: Remote Access (the
// tunnel listener, OAuth, client metadata and the tunnel checks). Re-exported,
// so every file here sees them as before.
@_exported import BridgeKitCore
@_exported import BridgeKitRemote

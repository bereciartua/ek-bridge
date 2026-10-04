import Darwin
import Dispatch
import Foundation
import Security
import XPC

// Not linked into the installed app. A future, separately approved LaunchAgent
// would advertise the Mach service before either factory is used.
enum SignedXPCBoundaryError: Error {
    case invalidRequirement
    case connectionUnavailable
    case requirementRejected
}

enum SignedXPCBoundary {
    static func codeRequirement(identifier: String, leafSHA1: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              leafSHA1.count == 40,
              leafSHA1.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
        else { return nil }
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(leafSHA1.lowercased())\""
    }

    static func makeListener(name: String, clientIdentifier: String,
                             leafSHA1: String, queue: DispatchQueue) throws -> xpc_connection_t {
        guard let clientRequirement = codeRequirement(
            identifier: clientIdentifier, leafSHA1: leafSHA1),
              syntaxIsValid(clientRequirement) else {
            throw SignedXPCBoundaryError.invalidRequirement
        }
        let listener = xpc_connection_create_mach_service(
            name, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        guard xpc_get_type(listener) == XPC_TYPE_CONNECTION else {
            throw SignedXPCBoundaryError.connectionUnavailable
        }
        guard xpc_connection_set_peer_code_signing_requirement(
            listener, clientRequirement) == 0 else {
            throw SignedXPCBoundaryError.requirementRejected
        }
        // The caller must install the handler before activating the listener.
        return listener
    }

    static func makeClient(name: String, serverIdentifier: String,
                           leafSHA1: String, queue: DispatchQueue) throws -> xpc_connection_t {
        guard let serverRequirement = codeRequirement(
            identifier: serverIdentifier, leafSHA1: leafSHA1),
              syntaxIsValid(serverRequirement) else {
            throw SignedXPCBoundaryError.invalidRequirement
        }
        let connection = xpc_connection_create_mach_service(name, queue, 0)
        guard xpc_get_type(connection) == XPC_TYPE_CONNECTION else {
            throw SignedXPCBoundaryError.connectionUnavailable
        }
        guard xpc_connection_set_peer_code_signing_requirement(
            connection, serverRequirement) == 0 else {
            throw SignedXPCBoundaryError.requirementRejected
        }
        // The caller must install the handler before activating the client.
        return connection
    }

    static func sameUser(_ peer: xpc_connection_t) -> Bool {
        xpc_connection_get_euid(peer) == geteuid()
    }

    static func syntaxIsValid(_ requirement: String) -> Bool {
        var compiled: SecRequirement?
        return SecRequirementCreateWithString(
            requirement as CFString, SecCSFlags(rawValue: 0), &compiled) == errSecSuccess
    }
}

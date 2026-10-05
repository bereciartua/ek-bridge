import CoreFoundation
import Foundation

/// A JSON-RPC request ID: a string or an integer, echoed back with its type.
enum JSONRPCID: Equatable, Hashable {
    case string(String)
    case int(Int)

    var json: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        }
    }

    /// For log-free keys such as in-flight request tracking.
    var key: String {
        switch self {
        case .string(let value): "s:" + value
        case .int(let value): "i:\(value)"
        }
    }

    /// Strings and whole numbers only; null, booleans and fractions are invalid.
    init?(json value: Any) {
        if let text = value as? String {
            self = .string(text)
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            // Integers are read as integers, so large IDs echo exactly;
            // anything outside Int64 is refused.
            // A number written with a fraction or exponent (1.0, 1e3) can't be
            // echoed with its type, so it's refused like any non-integer.
            guard !CFNumberIsFloatType(number), number.stringValue == String(number.int64Value)
            else { return nil }
            self = .int(Int(number.int64Value))
        } else {
            return nil
        }
    }
}

/// One message from a client. MCP removed batching in 2025-06-18, so a body
/// is exactly one object.
enum JSONRPCMessage {
    case request(id: JSONRPCID, method: String, params: [String: Any])
    case notification(method: String, params: [String: Any])
    /// A client's reply to a server request. We never send requests, so these
    /// are accepted and ignored.
    case response
}

enum JSONRPCParseError: Error, Equatable {
    case parse
    case invalidRequest
    /// The request was malformed but its ID could be read, so the error can
    /// name it.
    case invalidRequestWithID(JSONRPCID)
}

enum JSONRPC {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// Implementation-defined: the bearer token wasn't recognized.
    static let authenticationFailed = -32001
    /// Reserved by MCP 2026-07-28 for Streamable HTTP header problems.
    static let headerMismatch = -32020
    static let unsupportedProtocolVersion = -32022

    static func parse(_ body: Data) -> Result<JSONRPCMessage, JSONRPCParseError> {
        guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        else { return .failure(.parse) }
        guard let object = value as? [String: Any] else { return .failure(.invalidRequest) }
        let id = object["id"].flatMap(JSONRPCID.init(json:))
        guard object["jsonrpc"] as? String == "2.0" else {
            return .failure(id.map(JSONRPCParseError.invalidRequestWithID) ?? .invalidRequest)
        }
        if object["method"] == nil, object["id"] != nil,
           object["result"] != nil || object["error"] != nil {
            return .success(.response)
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return .failure(id.map(JSONRPCParseError.invalidRequestWithID) ?? .invalidRequest)
        }
        let params: [String: Any]
        switch object["params"] {
        case nil: params = [:]
        case let value as [String: Any]: params = value
        default: return .failure(id.map(JSONRPCParseError.invalidRequestWithID) ?? .invalidRequest)
        }
        guard let rawID = object["id"] else { return .success(.notification(method: method, params: params)) }
        guard let id = JSONRPCID(json: rawID) else { return .failure(.invalidRequest) }
        return .success(.request(id: id, method: method, params: params))
    }

    static func result(id: JSONRPCID, _ result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    /// `id` nil writes `"id": null`; `omitID` leaves the member out, as MCP
    /// asks for the Origin refusal.
    static func error(id: JSONRPCID?, code: Int, message: String, data: Any? = nil,
                      omitID: Bool = false) -> Data {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var object: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if !omitID { object["id"] = id?.json ?? NSNull() }
        return encode(object)
    }

    static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object,
                                     options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}

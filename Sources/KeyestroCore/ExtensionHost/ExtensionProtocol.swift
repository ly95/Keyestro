import Foundation
import KeyestroDomain

/// A bounded, strongly typed JSON value used by the extension protocol.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// A JSON-RPC request identifier represented as either an integer or string.
public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON-RPC id must be an integer or string")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

/// A JSON-RPC error object returned across the extension process boundary.
public struct JSONRPCErrorObject: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A validated JSON-RPC 2.0 request, notification, response, or error envelope.
public struct JSONRPCEnvelope: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCErrorObject?

    public init(
        id: JSONRPCID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONRPCErrorObject? = nil
    ) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        result = container.contains(.result) ? try container.decode(JSONValue.self, forKey: .result) : nil
        error = try container.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        if let result { try container.encode(result, forKey: .result) }
        try container.encodeIfPresent(error, forKey: .error)
    }

    public func validate() throws {
        guard jsonrpc == "2.0" else { throw ExtensionProtocolError.invalidEnvelope }
        let isRequest = method != nil && result == nil && error == nil
        let isResponse = method == nil && id != nil && ((result != nil) != (error != nil))
        guard isRequest || isResponse else { throw ExtensionProtocolError.invalidEnvelope }
        if let method {
            guard !method.isEmpty, method.utf8.count <= 256 else { throw ExtensionProtocolError.invalidEnvelope }
        }
    }
}

/// Stable framing and envelope validation failures for extension communication.
public enum ExtensionProtocolError: Error, Equatable, Sendable {
    case headerTooLarge
    case malformedHeader
    case duplicateContentLength
    case invalidContentLength
    case frameTooLarge
    case invalidUTF8
    case invalidJSON
    case invalidEnvelope
    case streamEnded
    case timeout

    public var descriptor: ErrorDescriptor {
        ErrorDescriptor(
            code: "extension.protocol.\(String(describing: self))", message: "The extension violated the communication protocol.")
    }
}

/// Incrementally frames and decodes bounded Content-Length JSON-RPC messages.
public struct JSONRPCFramer: Sendable {
    public static let maximumHeaderBytes = 8 * 1_024
    public static let maximumFrameBytes = 1 * 1_024 * 1_024
    private static let delimiter = Data("\r\n\r\n".utf8)
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while true {
            guard let headerRange = buffer.range(of: Self.delimiter) else {
                if buffer.count > Self.maximumHeaderBytes { throw ExtensionProtocolError.headerTooLarge }
                break
            }
            let headerLength = headerRange.lowerBound
            guard headerLength <= Self.maximumHeaderBytes else { throw ExtensionProtocolError.headerTooLarge }
            let headerData = buffer.prefix(headerLength)
            guard let header = String(data: headerData, encoding: .ascii) else {
                throw ExtensionProtocolError.malformedHeader
            }
            var contentLength: Int?
            for line in header.components(separatedBy: "\r\n") where !line.isEmpty {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw ExtensionProtocolError.malformedHeader }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                guard name == "content-length" else { continue }
                guard contentLength == nil else { throw ExtensionProtocolError.duplicateContentLength }
                guard !value.isEmpty,
                    value.allSatisfy(\.isNumber),
                    let parsed = Int(value),
                    parsed > 0
                else { throw ExtensionProtocolError.invalidContentLength }
                guard parsed <= Self.maximumFrameBytes else { throw ExtensionProtocolError.frameTooLarge }
                contentLength = parsed
            }
            guard let contentLength else { throw ExtensionProtocolError.invalidContentLength }
            let bodyStart = headerRange.upperBound
            guard buffer.count >= bodyStart + contentLength else { break }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            guard String(data: body, encoding: .utf8) != nil else { throw ExtensionProtocolError.invalidUTF8 }
            frames.append(body)
            buffer.removeSubrange(0..<(bodyStart + contentLength))
        }
        return frames
    }

    public static func frame(_ envelope: JSONRPCEnvelope) throws -> Data {
        try envelope.validate()
        let body = try JSONEncoder().encode(envelope)
        guard body.count <= maximumFrameBytes else { throw ExtensionProtocolError.frameTooLarge }
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return framed
    }

    public static func decode(_ body: Data) throws -> JSONRPCEnvelope {
        guard String(data: body, encoding: .utf8) != nil else { throw ExtensionProtocolError.invalidUTF8 }
        do {
            let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: body)
            try envelope.validate()
            return envelope
        } catch let error as ExtensionProtocolError {
            throw error
        } catch {
            throw ExtensionProtocolError.invalidJSON
        }
    }
}

extension Encodable {
    public func jsonValue() throws -> JSONValue {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue {
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

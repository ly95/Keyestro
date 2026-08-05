import Foundation

/// A bounded network request that can only be sent by an explicitly enabled feature.
public struct NetworkRequest: Equatable, Sendable {
    public enum Method: String, Equatable, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public let url: URL
    public let method: Method
    public let headers: [String: String]
    public let body: Data?
    public let timeout: Duration
    public let maximumResponseBytes: Int

    public init(
        url: URL,
        method: Method = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Duration = .seconds(15),
        maximumResponseBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = min(max(timeout, .seconds(1)), .seconds(60))
        self.maximumResponseBytes = min(max(1, maximumResponseBytes), 25 * 1_024 * 1_024)
    }
}

/// A validated HTTP response with a bounded body.
public struct NetworkResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum NetworkServiceError: Error, Equatable, Sendable {
    case disabled
    case invalidURL
    case hostNotAllowed
    case invalidResponse
    case responseTooLarge
}

/// Network boundary used only by features with explicit enablement and a documented host allowlist.
public protocol NetworkServicing: Sendable {
    func send(_ request: NetworkRequest) async throws -> NetworkResponse
}

/// Secure default for every feature that does not explicitly opt in to network access.
public struct DisabledNetworkService: NetworkServicing {
    public init() {}

    public func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        throw NetworkServiceError.disabled
    }
}

/// HTTPS-only implementation restricted to an immutable host allowlist.
public actor AllowlistedNetworkService: NetworkServicing {
    private let allowedHosts: Set<String>
    private let session: URLSession

    public init(allowedHosts: Set<String>) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: NetworkRequest) async throws -> NetworkResponse {
        guard request.url.scheme?.lowercased() == "https", let host = request.url.host?.lowercased() else {
            throw NetworkServiceError.invalidURL
        }
        guard allowedHosts.contains(host) else { throw NetworkServiceError.hostNotAllowed }
        guard request.body?.count ?? 0 <= 2 * 1_024 * 1_024 else { throw NetworkServiceError.responseTooLarge }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = Self.seconds(request.timeout)
        for (name, value) in request.headers {
            guard Self.validHeaderName(name), value.utf8.count <= 8_192 else {
                throw NetworkServiceError.invalidURL
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (body, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw NetworkServiceError.invalidResponse }
        guard body.count <= request.maximumResponseBytes else { throw NetworkServiceError.responseTooLarge }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { output, entry in
            guard let name = entry.key as? String, let value = entry.value as? String else { return }
            output[name] = value
        }
        return NetworkResponse(statusCode: http.statusCode, headers: headers, body: body)
    }

    private static func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
            }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

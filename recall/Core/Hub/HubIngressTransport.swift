import Foundation
import CryptoKit

/// Store-only transport. Callers persist the envelope before invoking this client,
/// and persist the matching receipt before retiring any original or queue item.
/// It never loads Gateway credentials, dispatches processing, or follows redirects.
final class HubIngressTransport: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case invalidConfiguration
        case unavailable
        case network(Int)
        case rejected(Int)
        case invalidResponse

        var diagnosticCategory: String {
            switch self {
            case .invalidConfiguration: return "invalid_configuration"
            case .unavailable: return "unavailable"
            case .network(let code): return "network_\(code)"
            case .rejected(let status): return "http_\(status)"
            case .invalidResponse: return "invalid_response"
            }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class AttemptMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let id: UUID
        init(id: UUID) { self.id = id }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let last = metrics.transactionMetrics.last else { return }
            let timing = HubRequestTiming(
                dnsStart: last.domainLookupStartDate, dnsEnd: last.domainLookupEndDate,
                connectStart: last.connectStartDate, connectEnd: last.connectEndDate,
                tlsStart: last.secureConnectionStartDate, tlsEnd: last.secureConnectionEndDate,
                requestStart: last.requestStartDate, requestEnd: last.requestEndDate,
                responseStart: last.responseStartDate, reusedConnection: last.isReusedConnection,
                proxyConnection: last.isProxyConnection)
            let id = self.id
            Task { @MainActor in HubConnectionDiagnostics.shared.collected(id: id, timing: timing) }
        }
    }

    private let endpoint: URL
    private let bearerToken: String
    private let session: URLSession
    private let endpointSHA256: String

    static func endpointFingerprint(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw Failure.invalidConfiguration
        }
        // Match the Hub operator's existing fingerprint: exact configured URL,
        // with only its optional trailing root slash removed. No token is read.
        let identity = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The deployment owner must establish tailnet-only reachability and provision
    /// Recall's source-bound credential separately. No implicit endpoint or token.
    init(baseURL: URL, bearerToken: String,
         configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              !bearerToken.isEmpty,
              !bearerToken.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.invalidConfiguration }
        self.endpoint = baseURL.appendingPathComponent("v1/events")
        self.endpointSHA256 = try Self.endpointFingerprint(baseURL)
        self.bearerToken = bearerToken
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func submit(_ envelope: HubProducerEnvelope,
                boundEventID: String? = nil) async throws -> HubStorageReceipt {
        try await submit(encodedJSON: envelope.encodedJSON, expected: envelope.expectedReceipt,
                         boundEventID: boundEventID)
    }

    /// Retry directly from a durable lease without rebuilding archival metadata.
    func submit(encodedJSON: Data, expected: HubExpectedStorageReceipt,
                boundEventID: String? = nil) async throws -> HubStorageReceipt {
        let (status, data) = try await submitRaw(encodedJSON: encodedJSON)
        guard status == 200 || status == 201 else { throw Failure.rejected(status) }
        do {
            return try HubProducerContract.validateResponse(
                responseData: data, expected: expected, boundEventID: boundEventID)
        } catch {
            throw Failure.invalidResponse
        }
    }

    /// Returns the body only to the caller that owns durable receipt validation.
    /// The transport never logs or interprets it and still rejects redirects.
    func submitRaw(encodedJSON: Data) async throws -> (status: Int, body: Data) {
        guard !encodedJSON.isEmpty,
              encodedJSON.count <= HubProducerContract.maximumEncodedJSONBytes else {
            throw Failure.invalidConfiguration
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = encodedJSON
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        let diagnosticID = UUID()
        await HubConnectionDiagnostics.shared.started(id: diagnosticID, endpointSHA256: endpointSHA256)
        do {
            (data, response) = try await session.data(for: request, delegate: AttemptMetrics(id: diagnosticID))
        } catch is CancellationError {
            await HubConnectionDiagnostics.shared.completed(id: diagnosticID, urlError: URLError.cancelled.rawValue)
            throw CancellationError()
        } catch {
            // Preserve only the fixed URL loading code, never URL/token-bearing
            // descriptions, userInfo, underlying errors, or response bodies.
            let failure = error as NSError
            await HubConnectionDiagnostics.shared.completed(id: diagnosticID,
                urlError: failure.domain == NSURLErrorDomain ? failure.code : nil)
            if failure.domain == NSURLErrorDomain { throw Failure.network(failure.code) }
            throw Failure.unavailable
        }
        await HubConnectionDiagnostics.shared.completed(id: diagnosticID, status: (response as? HTTPURLResponse)?.statusCode)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return (http.statusCode, data)
    }
}

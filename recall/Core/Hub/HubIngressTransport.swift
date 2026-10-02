import Foundation

/// Store-only transport. Callers persist the envelope before invoking this client,
/// and persist the matching receipt before retiring any original or queue item.
/// It never loads Gateway credentials, dispatches processing, or follows redirects.
final class HubIngressTransport: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case invalidConfiguration
        case unavailable
        case rejected(Int)
        case invalidResponse
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let endpoint: URL
    private let bearerToken: String
    private let session: URLSession

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
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not propagate URL/token-bearing diagnostics into activity logs.
            throw Failure.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw Failure.rejected(http.statusCode)
        }
        do {
            return try HubProducerContract.validateResponse(
                responseData: data, expected: expected, boundEventID: boundEventID)
        } catch {
            throw Failure.invalidResponse
        }
    }
}

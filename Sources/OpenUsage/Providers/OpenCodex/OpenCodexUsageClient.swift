import Foundation

struct OpenCodexUsageClient: Sendable {
    let http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchQuotas(auth: OpenCodexAuth) async throws -> Data {
        try await get(auth.baseURL.appendingPathComponent("api/provider-quotas"), auth: auth)
    }

    func fetchUsage(auth: OpenCodexAuth) async throws -> Data {
        let url = auth.baseURL.appendingPathComponent("api/usage")
            .appending(queryItems: [URLQueryItem(name: "days", value: "30")])
        return try await get(url, auth: auth)
    }

    private func get(_ url: URL, auth: OpenCodexAuth) async throws -> Data {
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(
                method: "GET", url: url,
                headers: ["Authorization": "Bearer \(auth.adminToken)", "Accept": "application/json"],
                timeout: 15
            ))
        } catch {
            throw OpenCodexUsageError.connectionFailed
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw OpenCodexAuthError.invalidToken
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodexUsageError.requestFailed(response.statusCode)
        }
        return response.body
    }
}

enum OpenCodexUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .connectionFailed: ProviderUsageErrorText.connectionFailed
        case .requestFailed(let status): ProviderUsageErrorText.requestFailed(statusCode: status)
        case .invalidResponse: ProviderUsageErrorText.invalidResponse
        }
    }
}

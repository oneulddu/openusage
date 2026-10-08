import Foundation

struct OpenCodexAuth: Sendable {
    let baseURL: URL
    let adminToken: String
}

enum OpenCodexAuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case invalidConfiguration
    case credentialAccess
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "OpenCodex is not configured. Add ~/.config/openusage/opencodex.json or start your local hub."
        case .invalidConfiguration:
            "OpenCodex configuration is invalid. Check the base URL and token settings."
        case .credentialAccess:
            "Couldn't read the OpenCodex configuration or token file. Check its permissions."
        case .invalidToken:
            "OpenCodex rejected the admin token. Check your hub's token file."
        }
    }
}

/// One local-only loader shared by refresh and provider discovery. An explicit config never falls
/// through to a different hub, even when malformed or unreadable.
struct OpenCodexAuthStore: Sendable {
    static let configPath = "~/.config/openusage/opencodex.json"
    private let files: any TextFileAccessing
    private let environment: any EnvironmentReading

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        environment: any EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
    }

    func load() throws -> OpenCodexAuth {
        do {
            if let text = try files.readTextIfPresent(Self.configPath) {
                // Do not log decoder errors: the input contains private credential material.
                guard let config = try? JSONDecoder().decode(Configuration.self, from: Data(text.utf8)),
                      let url = validBaseURL(config.baseURL) else {
                    throw OpenCodexAuthError.invalidConfiguration
                }
                let token: String?
                if let inline = config.adminToken {
                    token = trimmed(inline)
                } else if let path = trimmed(config.adminTokenFile) {
                    token = trimmed(try files.readTextIfPresent(path))
                } else {
                    token = nil
                }
                guard let token else { throw OpenCodexAuthError.notConfigured }
                return OpenCodexAuth(baseURL: url, adminToken: token)
            }
            let home = trimmed(environment.value(for: "OPENCODEX_HOME")) ?? "~/.opencodex"
            guard let token = trimmed(try files.readTextIfPresent(
                home.trimmingTrailingSlashes + "/admin-api-token"
            )) else { throw OpenCodexAuthError.notConfigured }
            return OpenCodexAuth(baseURL: URL(string: "http://127.0.0.1:10100")!, adminToken: token)
        } catch let error as OpenCodexAuthError {
            throw error
        } catch {
            throw OpenCodexAuthError.credentialAccess
        }
    }

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func validBaseURL(_ raw: String) -> URL? {
        guard let text = trimmed(raw), let url = URL(string: text.trimmingTrailingSlashes),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.nilIfEmpty != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    private struct Configuration: Decodable {
        let baseURL: String
        let adminToken: String?
        let adminTokenFile: String?
    }
}

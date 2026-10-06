import CoreFoundation
import Foundation

/// Observed in Hive's public portal SDK: GET /api/organization/:id/balance returns
/// data.billing_info.balance in USD. This is a portal-session API, not the inference-key API.
enum TheHivePortalBalance {
    static let portal = URL(string: "https://portal.thehive.ai")!
    static let dataStoreID = UUID(uuidString: "867596F0-6E6B-4F20-9FD5-730EED887B61")!
    static let organizationKey = "openusage.theHive.organization"
    static let metricLabel = "TheHive Credits"

    static func organization(in url: URL?) -> String? {
        guard let url, url.scheme == "https", url.host == portal.host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "organization", validOrganization(String(parts[1])) else { return nil }
        return String(parts[1])
    }

    static func validOrganization(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func allowedNavigation(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return host == "thehive.ai" || host.hasSuffix(".thehive.ai")
            || ["accounts.google.com", "github.com"].contains(host)
    }

    static func parse(_ result: Any) throws -> Double {
        guard let envelope = result as? [String: Any], let status = envelope["status"] as? Int else { throw Failure.invalidResponse }
        if status == 401 || status == 403 { throw Failure.signInRequired }
        guard status == 200, let root = envelope["body"] as? [String: Any],
              let data = root["data"] as? [String: Any], let billing = data["billing_info"] as? [String: Any] else {
            throw Failure.invalidResponse
        }
        if let currency = billing["currency"] as? String, currency.uppercased() != "USD" { throw Failure.invalidResponse }
        let amount: Double?
        if let number = billing["balance"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            amount = number.doubleValue
        } else if let string = billing["balance"] as? String {
            amount = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { amount = nil }
        guard let amount, amount.isFinite else { throw Failure.invalidResponse }
        return amount // Zero and negative balances are real data, never a missing value.
    }

    enum Failure: Error, LocalizedError {
        case signInRequired, chooseOrganization, invalidResponse, unavailable, cancelled
        var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in to TheHive to read your credits."
            case .chooseOrganization: "Open your organization in the TheHive portal, then connect it."
            case .invalidResponse: "TheHive did not return a readable USD balance."
            case .unavailable: "Could not read TheHive credits. Try again."
            case .cancelled: "TheHive connection was cancelled."
            }
        }
    }

    /// Runs only on the exact portal origin. Cookies never leave WebKit; only the balance result
    /// returns to Swift. Abort both network stalls and bodies that fail to finish within 12 seconds.
    static let balanceScript = """
    if (location.origin !== 'https://portal.thehive.ai') return {status: 401};
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch('https://portal-customer-api.thehive.ai/api/organization/'
        + encodeURIComponent(organization) + '/balance', {
          method: 'GET', credentials: 'include', signal: controller.signal, redirect: 'error'
        });
      if (!response.ok) return {status: response.status};
      const body = await response.json();
      return {status: response.status, body: {data: {billing_info: {
        balance: body?.data?.billing_info?.balance ?? null,
        currency: body?.data?.billing_info?.currency ?? 'USD'
      }}}};
    } finally { clearTimeout(timer); }
    """
}

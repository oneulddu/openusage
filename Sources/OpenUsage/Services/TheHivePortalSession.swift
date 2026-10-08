import AppKit
import Observation
import SwiftUI
import WebKit

/// A separate persistent browser profile, used only for the user's Hive login and read-only balance.
/// No Safari-cookie access, credential export, hub upload, or payment requests.
@MainActor @Observable
final class TheHivePortalSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = TheHivePortalSession()
    private(set) var organizationID: String?
    private(set) var candidateOrganizationID: String?
    private(set) var balance: Double?
    private(set) var updatedAt: Date?
    private(set) var message: String?
    private(set) var isRefreshing = false
    private(set) var isClearing = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var browser: WKWebView?
    @ObservationIgnored private var locationObservation: NSKeyValueObservation?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var flight: Task<Double, Error>?
    @ObservationIgnored private var pageReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: TheHivePortalBalance.organizationKey)
        self.organizationID = saved.flatMap { TheHivePortalBalance.validOrganization($0) ? $0 : nil }
        super.init()
    }

    var webView: WKWebView {
        if let browser { return browser }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: TheHivePortalBalance.dataStoreID)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        browser = view
        locationObservation = view.observe(\.url, options: [.new]) { [weak self] view, _ in
            let url = view.url
            Task { @MainActor [weak self] in self?.candidateOrganizationID = TheHivePortalBalance.organization(in: url) }
        }
        return view
    }

    func showLogin(onChange: @escaping @MainActor () -> Void) {
        guard !isClearing else { return }
        message = nil
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.title = L10n.text("Connect TheHive")
            created.minSize = NSSize(width: 980, height: 620)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.contentView = NSHostingView(rootView: TheHiveLoginView(session: self, onChange: onChange))
        if webView.url == nil || webView.url?.host != TheHivePortalBalance.portal.host {
            loadPortal()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeLogin() { window?.orderOut(nil) }

    func connectSelectedOrganization() async -> Bool {
        guard let selected = TheHivePortalBalance.organization(in: webView.url), !isRefreshing, !isClearing else {
            message = TheHivePortalBalance.Failure.chooseOrganization.localizedDescription
            return false
        }
        generation += 1
        let revision = generation
        isRefreshing = true
        defer { if revision == generation { isRefreshing = false } }
        do {
            let value = try await readBalance(organization: selected, revision: revision)
            guard revision == generation else { return false }
            organizationID = selected
            defaults.set(selected, forKey: TheHivePortalBalance.organizationKey)
            balance = value
            updatedAt = Date()
            message = nil
            return true
        } catch {
            if revision == generation { report(error) }
            return false
        }
    }

    func refresh() async {
        guard let organizationID, !isClearing else { return }
        // A settings refresh and a provider refresh share one request.
        if let flight { _ = try? await flight.value; return }
        guard !isRefreshing else { return }
        let revision = generation
        isRefreshing = true
        let task = Task {
            do {
                let value = try await self.readBalance(organization: organizationID, revision: revision)
                guard revision == generation else { throw TheHivePortalBalance.Failure.cancelled }
                balance = value; updatedAt = Date(); message = nil
                return value
            } catch {
                if revision == generation {
                    balance = nil; updatedAt = nil
                    report(error)
                }
                throw error
            }
        }
        flight = task
        defer {
            if revision == generation { flight = nil; isRefreshing = false }
        }
        _ = try? await task.value
    }

    func creditLine() async -> MetricLine {
        await refresh()
        return currentCreditLine
    }

    var currentCreditLine: MetricLine {
        if let balance {
            return .values(label: TheHivePortalBalance.metricLabel,
                           values: [MetricValue(number: balance, kind: .dollars)])
        }
        let label = organizationID == nil || message == TheHivePortalBalance.Failure.signInRequired.localizedDescription
            ? "Sign In Required" : (message == nil ? "Refreshing" : "Unavailable")
        return .badge(label: TheHivePortalBalance.metricLabel,
                      text: label,
                      colorHex: "#888888")
    }

    func disconnect() async {
        guard !isClearing else { return }
        isClearing = true
        generation += 1
        flight?.cancel(); flight = nil
        isRefreshing = false
        organizationID = nil; candidateOrganizationID = nil; balance = nil; updatedAt = nil; message = nil
        defaults.removeObject(forKey: TheHivePortalBalance.organizationKey)
        closeLogin()
        browser?.stopLoading()
        locationObservation = nil
        browser?.navigationDelegate = nil
        browser?.uiDelegate = nil
        browser = nil
        window?.contentView = nil
        pageReady = false
        let store = WKWebsiteDataStore(forIdentifier: TheHivePortalBalance.dataStoreID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        isClearing = false
    }

    private func loadPortal() {
        pageReady = false
        let target = organizationID.flatMap { URL(string: "https://portal.thehive.ai/organization/\($0)/dashboard") }
            ?? TheHivePortalBalance.portal
        webView.load(URLRequest(url: target))
    }

    private func readBalance(organization: String, revision: Int) async throws -> Double {
        guard TheHivePortalBalance.validOrganization(organization) else { throw TheHivePortalBalance.Failure.chooseOrganization }
        if webView.url == nil { loadPortal() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !pageReady && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard revision == generation else { throw TheHivePortalBalance.Failure.cancelled }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard revision == generation else { throw TheHivePortalBalance.Failure.cancelled }
        guard pageReady else { throw TheHivePortalBalance.Failure.unavailable }
        guard webView.url?.scheme == "https", webView.url?.host == TheHivePortalBalance.portal.host else {
            throw TheHivePortalBalance.Failure.signInRequired
        }
        let value: Double = try await withCheckedThrowingContinuation { continuation in
            let completion = BalanceCompletion(continuation)
            completion.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                completion.finish(.failure(TheHivePortalBalance.Failure.unavailable))
            }
            webView.callAsyncJavaScript(TheHivePortalBalance.balanceScript,
                arguments: ["organization": organization], in: nil, in: .page) { result in
                completion.finish(result.flatMap { raw in Result { try TheHivePortalBalance.parse(raw as Any) } })
            }
        }
        guard revision == generation else { throw TheHivePortalBalance.Failure.cancelled }
        return value
    }

    private func report(_ error: Error) {
        message = (error as? TheHivePortalBalance.Failure)?.localizedDescription
            ?? TheHivePortalBalance.Failure.unavailable.localizedDescription
        AppLog.warn(LogTag.plugin("opencodex"), "TheHive portal balance unavailable")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        candidateOrganizationID = TheHivePortalBalance.organization(in: webView.url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { pageReady = false }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        message = TheHivePortalBalance.Failure.unavailable.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The trusted portal may embed provider-owned CAPTCHA frames. Top-level navigation stays
        // restricted; HTTPS subframes keep the portal's normal login controls working.
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(navigationAction.request.url?.scheme == "https" ? .allow : .cancel)
            return
        }
        guard let url = navigationAction.request.url, TheHivePortalBalance.allowedNavigation(url) else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, TheHivePortalBalance.allowedNavigation(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

@MainActor
private final class BalanceCompletion {
    private var continuation: CheckedContinuation<Double, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Double, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Double, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

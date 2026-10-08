import SwiftUI
import WebKit

struct TheHiveConnectionSection: View {
    @Environment(WidgetDataStore.self) private var dataStore
    @State private var session = TheHivePortalSession.shared
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var confirmDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("TheHive Credits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let balance = session.balance {
                        Text(balance, format: .currency(code: "USD")).monospacedDigit()
                    } else {
                        Text(L10n.text(session.organizationID == nil ? "Not Connected" : "Connected"))
                    }
                    Spacer()
                    if session.isRefreshing || session.isClearing { ProgressView().controlSize(.small) }
                    Button(session.organizationID == nil ? L10n.text("Sign In") : L10n.text("Open Portal")) {
                        session.showLogin(onChange: refreshCard)
                    }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(session.isClearing)
                }
                Text("Sign in to the Hive portal to show your real remaining credits in OpenCodex.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = session.message {
                    Text(L10n.text(message)).font(.caption).foregroundStyle(Theme.notice)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.organizationID != nil {
                    HStack {
                        Button("Refresh") { Task { await session.refresh(); refreshCard() } }
                            .disabled(session.isRefreshing || session.isClearing)
                        Spacer()
                        Button("Disconnect…") { confirmDisconnect = true }
                            .disabled(session.isClearing)
                    }.controlSize(.small)
                }
            }
            .padding(12)
            .cardSurface()
        }
        .confirmationDialog("Disconnect TheHive?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { await session.disconnect(); refreshCard() }
            }
        } message: {
            Text("This removes only OpenUsage's TheHive web session. Your browser login and Hive account are unchanged.")
        }
    }

    private func refreshCard() {
        dataStore.updateTheHiveCredits(session.currentCreditLine)
        Task { await dataStore.refresh(providerID: "opencodex", force: true) }
    }
}

struct TheHiveLoginView: View {
    let session: TheHivePortalSession
    let onChange: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect TheHive").font(.title2.weight(.semibold))
                Text("Sign in, open the organization whose credits you want to see, then choose Connect This Organization.")
                    .foregroundStyle(.secondary)
                Text("Your login stays in this app's web session. It is not sent to the OpenCodex hub.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            TheHiveWebView(webView: session.webView)
            Divider()
            HStack(spacing: 12) {
                if let message = session.message {
                    Text(L10n.text(message)).foregroundStyle(.red).font(.caption)
                } else if session.candidateOrganizationID == nil {
                    Text("Waiting for an organization page…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isRefreshing { ProgressView().controlSize(.small) }
                Button("Close") { session.closeLogin() }.keyboardShortcut(.cancelAction)
                Button("Connect This Organization") {
                    Task {
                        if await session.connectSelectedOrganization() {
                            onChange()
                            session.closeLogin()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.candidateOrganizationID == nil || session.isRefreshing || session.isClearing)
            }.padding(16)
        }
    }
}

private struct TheHiveWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

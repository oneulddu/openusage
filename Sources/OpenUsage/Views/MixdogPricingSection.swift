import SwiftUI

/// Customize → Mixdog → Model Prices: per-million-token rates for models Mixdog recorded without a
/// cost. Lists every such model in the ledger plus any model that already has a saved price. Saving or
/// clearing a price forces a Mixdog refresh so the spend tiles recalculate immediately.
struct MixdogPricingSection: View {
    let provider: MixdogProvider

    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var models: [String] = []
    @State private var saved: [String: MixdogModelPrice] = [:]
    @State private var drafts: [String: PriceDraft] = [:]
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Model Prices")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                content
                if let actionError {
                    Text(L10n.display(actionError))
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                Text("Set prices per million tokens for models Mixdog couldn't price. They apply only to requests without a recorded cost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .cardSurface()
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 6) {
                MotionAwareProgressView(controlSize: .mini)
                    .accessibilityHidden(true)
                Text("Loading Models…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        } else if let loadError {
            Text(L10n.display(loadError))
                .font(.caption)
                .foregroundStyle(Theme.notice)
                .padding(12)
        } else if models.isEmpty {
            Text("Every model in your Mixdog ledger has a recorded cost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        } else {
            ForEach(Array(models.enumerated()), id: \.element) { index, model in
                if index > 0 { Divider() }
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: String) -> some View {
        let draft = drafts[model] ?? PriceDraft()
        let parsed = draft.price
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if saved[model] != nil {
                    Button("Clear") { clear(model) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                Button("Save") { save(model) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(parsed == nil || parsed == saved[model])
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    field("Input", \.input, model: model)
                    field("Output", \.output, model: model)
                }
                GridRow {
                    field("Cache Read", \.cacheRead, model: model)
                    field("Cache Write", \.cacheWrite, model: model)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    @ViewBuilder
    private func field(_ title: String, _ keyPath: WritableKeyPath<PriceDraft, String>, model: String) -> some View {
        Text(L10n.display(title))
            .font(.caption)
            .foregroundStyle(.secondary)
        TextField("$0", text: Binding(
            get: { drafts[model, default: PriceDraft()][keyPath: keyPath] },
            set: { drafts[model, default: PriceDraft()][keyPath: keyPath] = $0 }
        ))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(width: 64)
        .accessibilityLabel(L10n.format("%@ price per million tokens", L10n.display(title)))
    }

    // MARK: - Actions

    private func load() async {
        let scanner = provider.usageScanner
        do {
            let ledgerModels = try await loadOffMainActor { try scanner.unpricedModels() }
            let prices = MixdogModelPriceSetting.load()
            saved = prices
            drafts = prices.mapValues(PriceDraft.init(price:))
            models = Set(ledgerModels).union(prices.keys).sorted()
        } catch {
            loadError = "Couldn't read Mixdog's usage ledger."
            AppLog.warn(LogTag.plugin("mixdog"), "model price list unavailable: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func save(_ model: String) {
        guard let price = drafts[model]?.price else { return }
        var next = saved
        next[model] = price
        commit(next)
    }

    private func clear(_ model: String) {
        var next = saved
        next[model] = nil
        drafts[model] = nil
        commit(next)
    }

    private func commit(_ prices: [String: MixdogModelPrice]) {
        do {
            try MixdogModelPriceSetting.save(prices)
            saved = prices
            actionError = nil
            recalculate()
        } catch {
            actionError = "Couldn't save the model price."
            AppLog.error(LogTag.plugin("mixdog"), "model price save failed: \(error.localizedDescription)")
        }
    }

    /// Force a refresh so the tiles pick up the new prices. A refresh already in flight may have read
    /// the previous prices, so wait for it instead of having the new pass skipped.
    private func recalculate() {
        let id = provider.provider.id
        Task {
            while dataStore.refreshingProviderIDs.contains(id) {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            dataStore.clearFailureBackoff(for: id)
            await dataStore.refresh(providerID: id, force: true)
        }
    }
}

/// The editable text of one model's four rates. An empty field counts as $0; the draft is savable
/// when at least one field is filled and every filled field is a non-negative number.
private struct PriceDraft {
    var input = ""
    var output = ""
    var cacheRead = ""
    var cacheWrite = ""

    init() {}

    init(price: MixdogModelPrice) {
        input = Self.text(price.inputPerMillion)
        output = Self.text(price.outputPerMillion)
        cacheRead = Self.text(price.cacheReadPerMillion)
        cacheWrite = Self.text(price.cacheWritePerMillion)
    }

    var price: MixdogModelPrice? {
        let fields = [input, output, cacheRead, cacheWrite].map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.contains(where: { !$0.isEmpty }) else { return nil }
        var rates: [Double] = []
        for field in fields {
            let text = field.hasPrefix("$") ? String(field.dropFirst()) : field
            if text.isEmpty {
                rates.append(0)
                continue
            }
            guard let rate = Double(text), rate.isFinite, rate >= 0 else { return nil }
            rates.append(rate)
        }
        return MixdogModelPrice(
            inputPerMillion: rates[0],
            outputPerMillion: rates[1],
            cacheReadPerMillion: rates[2],
            cacheWritePerMillion: rates[3]
        )
    }

    private static func text(_ rate: Double) -> String {
        // `String(Double)` is round-trip exact, so reopening a saved price never drifts from it.
        rate == 0 ? "" : String(rate)
    }
}

import CryptoKit
import CoreFoundation
import Foundation

/// Removes only positively matched rollout events. No model-name or current-config inference:
/// OpenCodex hashes the client thread id with SHA256 and persists its first 32 hex characters.
/// Fetch compact correlation data through the existing read-only API; never copy session files.
actor OpenCodexUsageReconciler {
    static let incompleteWarning = "Only confirmed OpenCodex requests were excluded. Unmatched history may still overlap with the hub."
    static let unavailableWarning = "OpenCodex usage could not be checked. Codex history is unchanged and totals may overlap."

    struct Result: Sendable {
        var events: [CodexLogUsageScanner.Event]
        var excluded: Int
        var warning: String?
    }

    struct Request: Sendable {
        var id: String
        var conversationID: String
        var start: Date
        var end: Date
        var models: Set<String>
        var input: Int
        var output: Int

        init?(_ row: [String: Any]) {
            guard let id = row["requestId"] as? String, !id.isEmpty,
                  let conversationID = row["conversationId"] as? String, !conversationID.isEmpty,
                  let status = row["status"] as? Int, (200..<300).contains(status),
                  let start = Self.number(row["timestamp"]), start >= 0, start < 1e15,
                  let duration = Self.number(row["durationMs"]), duration >= 0, (start + duration).isFinite,
                  let usage = row["usage"] as? [String: Any],
                  let input = Self.token(usage["inputTokens"]),
                  let output = Self.token(usage["outputTokens"]), input > 0 || output > 0
            else { return nil }
            self.id = id
            self.conversationID = conversationID
            self.start = Date(timeIntervalSince1970: start / 1000)
            self.end = Date(timeIntervalSince1970: (start + duration) / 1000)
            self.models = Set(["requestedModel", "model", "resolvedModel", "servedModel"].compactMap {
                (row[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
            self.input = input
            self.output = output
        }

        private static func number(_ raw: Any?) -> Double? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }

        private static func token(_ raw: Any?) -> Int? {
            guard let value = number(raw), value >= 0, value.rounded(.down) == value, value < Double(Int.max) else { return nil }
            return Int(value)
        }
    }

    private struct CachedHistory: Sendable {
        var since: Date
        var until: Date
        var lastFullRead: Date
        var requests: [Request]
    }

    private let authStore: OpenCodexAuthStore
    private let client: OpenCodexUsageClient
    private var cached: [String: CachedHistory] = [:]
    private var hubIdentity: String?

    init(authStore: OpenCodexAuthStore = OpenCodexAuthStore(),
         client: OpenCodexUsageClient = OpenCodexUsageClient()) {
        self.authStore = authStore
        self.client = client
    }

    func reconcile(events: [CodexLogUsageScanner.Event], since: Date, now: Date) async -> Result {
        guard !events.isEmpty else { return Result(events: events, excluded: 0, warning: nil) }
        do {
            let auth: OpenCodexAuth
            do { auth = try authStore.load() }
            catch OpenCodexAuthError.notConfigured { return Result(events: events, excluded: 0, warning: nil) }
            // Changing the hub or its credential must never reuse another hub's match evidence.
            let identity = Self.digest(auth.baseURL.absoluteString + "\n" + auth.adminToken)
            if identity != hubIdentity { cached = [:]; hubIdentity = identity }
            let usageBody = try await client.fetchUsage(auth: auth)
            guard identity == hubIdentity else { throw OpenCodexUsageError.invalidResponse }
            guard let summary = ProviderParse.jsonObject(usageBody),
                  let sinceMS = summary["since"] as? Double, sinceMS.isFinite,
                  let untilMS = summary["generatedAt"] as? Double, untilMS.isFinite,
                  sinceMS >= 0, untilMS < 1e15, untilMS >= sinceMS,
                  summary["historyTruncated"] as? Bool != true else {
                throw OpenCodexUsageError.invalidResponse
            }
            // A history fetch isn't enough: the matching request must be in the hub's spend window.
            var spendLines: [MetricLine] = []
            _ = try OpenCodexUsageMapper.appendSpendLines(usageBody, now: now, to: &spendLines)
            let from = max(since.addingTimeInterval(-86400), Date(timeIntervalSince1970: sinceMS / 1000))
            let until = Date(timeIntervalSince1970: untilMS / 1000)
            let ids = Set(events.flatMap(Self.conversationIDs)).sorted()
            let needed = ids.filter {
                guard let entry = cached[$0] else { return true }
                return entry.since > from || until.timeIntervalSince(entry.until) > 30 || entry.until > until
            }
            // Four bounded reads at a time. No unbounded task fan-out on a large rollout directory.
            for offset in stride(from: 0, to: needed.count, by: 4) {
                try Task.checkCancellation()
                let batch = Array(needed[offset..<min(offset + 4, needed.count)])
                let client = self.client
                let previous = self.cached
                let fetched = try await withThrowingTaskGroup(of: (String, CachedHistory).self) { group in
                    for id in batch {
                        let old = previous[id]
                        // Re-read the trailing hour for delayed completions. A periodic full read
                        // also recovers requests taking longer than an hour without guessing.
                        let full = old == nil || old!.since > from || old!.until > until
                            || until.timeIntervalSince(old!.lastFullRead) > 3600
                        let queryFrom = full ? from : max(from, old!.until.addingTimeInterval(-3600))
                        group.addTask {
                            let new = try await Self.fetchAll(client: client, auth: auth, id: id,
                                                              since: queryFrom, until: until)
                            var byID = Dictionary((full ? [] : old!.requests).map { ($0.id, $0) },
                                                  uniquingKeysWith: { _, latest in latest })
                            for request in new { byID[request.id] = request }
                            return (id, CachedHistory(since: from, until: until,
                                lastFullRead: full ? until : old!.lastFullRead,
                                requests: byID.values.filter { $0.start >= from && $0.start <= until }))
                        }
                    }
                    var result: [(String, CachedHistory)] = []
                    for try await entry in group { result.append(entry) }
                    return result
                }
                guard identity == hubIdentity else { throw OpenCodexUsageError.invalidResponse }
                for (id, history) in fetched { cached[id] = history }
            }
            guard identity == hubIdentity else { throw OpenCodexUsageError.invalidResponse }
            // Other Codex account cards share this actor; retain their evidence until it ages out.
            cached = cached.filter { $0.value.until >= from && $0.value.since <= until }
            let requests = ids.flatMap { cached[$0]?.requests ?? [] }.filter {
                $0.start >= from && $0.start <= until
            }
            let result = Self.filter(events: events, requests: requests)
            AppLog.info(LogTag.plugin("codex"), "hub reconciliation: excluded \(result.excluded) confirmed events; retained \(result.events.count)")
            return result
        } catch {
            // Don't log URLs, tokens, ids, request bodies or server diagnostics.
            AppLog.warn(LogTag.plugin("codex"), "hub reconciliation unavailable; retaining local usage")
            return Result(events: events, excluded: 0, warning: Self.unavailableWarning)
        }
    }

    private static func fetchAll(client: OpenCodexUsageClient, auth: OpenCodexAuth, id: String,
                                 since: Date, until: Date) async throws -> [Request] {
        var cursor: String?
        var cursors: Set<String> = []
        var requests: [Request] = []
        for _ in 0..<100 {
            try Task.checkCancellation()
            let body = try await client.fetchHistory(auth: auth, conversationID: id, since: since,
                                                     until: until, cursor: cursor)
            guard let root = ProviderParse.jsonObject(body), let entries = root["entries"] as? [[String: Any]],
                  let hasMore = root["hasMore"] as? Bool else { throw OpenCodexUsageError.invalidResponse }
            if let index = root["index"] as? [String: Any], let error = index["lastError"], !(error is NSNull) {
                // The index uses an empty string for healthy state on some hub versions.
                guard let message = error as? String,
                      message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw OpenCodexUsageError.invalidResponse
                }
            }
            requests += entries.compactMap(Request.init).filter {
                $0.conversationID == id && $0.start >= since && $0.start <= until
            }
            if !hasMore { return requests }
            guard let next = root["nextCursor"] as? String, !next.isEmpty, cursors.insert(next).inserted else {
                throw OpenCodexUsageError.invalidResponse
            }
            cursor = next
        }
        // Never silently accept an incomplete 10,000-row conversation.
        throw OpenCodexUsageError.invalidResponse
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func conversationIDs(_ event: CodexLogUsageScanner.Event) -> [String] {
        [event.sessionID, event.parentSessionID].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return digest(value)
        }
    }

    /// One-to-one matching: identity + exact input/output + recorded model + response time.
    /// Keep ambiguous collisions and unknown events; never subtract the hub's differently priced dollars.
    static func filter(events: [CodexLogUsageScanner.Event], requests: [Request]) -> Result {
        let unique = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: Array(unique.values), by: \.conversationID)
        var excluded: Set<CodexLogUsageScanner.Event> = []
        var matches: [CodexLogUsageScanner.Event: [Request]] = [:]
        var uses: [String: Int] = [:]
        for event in Set(events) {
            let candidates = Set(conversationIDs(event)).flatMap { grouped[$0] ?? [] }.filter {
                $0.input == event.input && $0.output == event.output
                    && $0.models.contains(event.model.trimmingCharacters(in: .whitespacesAndNewlines))
                    && event.timestamp >= $0.start.addingTimeInterval(-2)
                    && abs(event.timestamp.timeIntervalSince($0.end)) <= 30
            }
            matches[event] = candidates
            for candidate in candidates { uses[candidate.id, default: 0] += 1 }
        }
        for (event, candidates) in matches {
            guard candidates.count == 1, let matched = candidates.first, uses[matched.id] == 1 else { continue }
            excluded.insert(event)
        }
        let kept = events.filter { !excluded.contains($0) }
        return Result(events: kept, excluded: excluded.count,
                      warning: kept.isEmpty ? nil : incompleteWarning)
    }
}

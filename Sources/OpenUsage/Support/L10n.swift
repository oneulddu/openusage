import Foundation

/// UI translations shipped in the app's main bundle (`Contents/Resources/<lang>.lproj/Localizable.strings`).
/// Keys are the English source strings, so a missing key — or a run without the packaged strings, such as
/// the test runner or `swift run` — shows the original English. Only call these at the display edge:
/// metric labels, local API output, logs, and persisted values must stay English.
enum L10n {
    /// The bundle the strings are read from. Tests can inject one with a translation table.
    nonisolated(unsafe) static var bundle: Bundle = .main

    /// Exact lookup of an English source string.
    static func text(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        let value = bundle.localizedString(forKey: key, value: key, table: nil)
        return value.isEmpty ? key : value
    }

    /// Looks up an English format string (`%@`, `%lld`) and fills it.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func display(_ value: String?) -> String? {
        value.map { display($0) }
    }

    /// Translates a string that was assembled elsewhere in English: an exact key first, then a fixed set
    /// of value phrases ("65% left", "Resets in 3d 10h", "$4.08 · 1.2M tokens"). Each phrase is rebuilt from
    /// a translated template, so without a translation table the result equals the input.
    static func display(_ value: String) -> String {
        let exact = text(value)
        if exact != value { return exact }
        if value.contains(" · ") {
            return value.components(separatedBy: " · ").map { display($0) }.joined(separator: " · ")
        }
        for rule in rules {
            if let translated = rule.apply(value) { return translated }
        }
        return value
    }

    /// "3d 10h", "4h 43m", "52m", "45s" → localized units. Returns nil when `value` isn't a compact duration.
    static func duration(_ value: String) -> String? {
        let parts = value.split(separator: " ")
        guard !parts.isEmpty else { return nil }
        var out: [String] = []
        for part in parts {
            guard let unit = part.last, "dhms".contains(unit), let number = Int(part.dropLast()) else { return nil }
            out.append(format("%lld\(unit)", number))
        }
        return out.joined(separator: " ")
    }

    /// Translates a captured fragment: a compact duration, a relative day phrase, or any exact key.
    fileprivate static func fragment(_ value: String) -> String {
        if let duration = duration(value) { return duration }
        for rule in Rule.when {
            if let translated = rule.apply(value) { return translated }
        }
        return display(value)
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        /// Whether each capture is translated as a fragment (durations, day phrases) or kept verbatim.
        let translateCaptures: Bool

        init(_ pattern: String, _ template: String, translateCaptures: Bool = true) {
            regex = try! NSRegularExpression(pattern: "^" + pattern + "$")
            self.template = template
            self.translateCaptures = translateCaptures
        }

        func apply(_ value: String) -> String? {
            let range = NSRange(value.startIndex..., in: value)
            guard let match = regex.firstMatch(in: value, range: range) else { return nil }
            let captures: [String] = (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: value).map { String(value[$0]) }
            }
            let localizedTemplate = L10n.text(template)
            guard localizedTemplate != template || captures.contains(where: { L10n.fragment($0) != $0 }) else {
                return nil
            }
            let filled = captures.map { translateCaptures ? L10n.fragment($0) : $0 }
            var result = localizedTemplate
            for capture in filled {
                guard let marker = result.range(of: "%@") else { break }
                result.replaceSubrange(marker, with: capture)
            }
            return result
        }

        static let when: [Rule] = [
            Rule("today at (.+)", "today at %@", translateCaptures: false),
            Rule("tomorrow at (.+)", "tomorrow at %@", translateCaptures: false),
            Rule("(.+) at (.+)", "%@ at %@", translateCaptures: false)
        ]
    }

    private static let rules: [Rule] = [
        Rule("Resets in (.+)", "Resets in %@"),
        Rule("Resets (.+)", "Resets %@"),
        Rule("Limit in (.+)", "Limit in %@"),
        Rule("Limit (.+)", "Limit %@"),
        Rule("Reset expires in (.+)", "Reset expires in %@"),
        Rule("Reset expires (.+)", "Reset expires %@"),
        Rule("~(\\d+)% left at reset", "~%@% left at reset", translateCaptures: false),
        Rule("~(\\d+)% used at reset", "~%@% used at reset", translateCaptures: false),
        Rule("~(\\d+)% over limit at reset", "~%@% over limit at reset", translateCaptures: false),
        Rule("~(\\d+)% spare", "~%@% spare", translateCaptures: false),
        Rule("(.+) left", "%@ left", translateCaptures: false),
        Rule("(.+) used", "%@ used", translateCaptures: false),
        Rule("(.+) spent", "%@ spent", translateCaptures: false),
        Rule("(.+) limit", "%@ limit", translateCaptures: false),
        Rule("(.+) cap", "%@ cap", translateCaptures: false),
        Rule("(\\S+) tokens", "%@ tokens", translateCaptures: false),
        Rule("(\\S+) requests", "%@ requests", translateCaptures: false),
        Rule("(\\S+) searches", "%@ searches", translateCaptures: false),
        Rule("(\\S+) resets", "%@ resets", translateCaptures: false),
        Rule("(\\S+) credits", "%@ credits", translateCaptures: false),
        Rule("(\\S+) available", "%@ available", translateCaptures: false),
        Rule("(\\d+) metrics", "%@ metrics", translateCaptures: false),
        Rule("Next update in (.+)", "Next update in %@"),
        Rule("Last updated (.+) ago", "Last updated %@ ago"),
        Rule("Updated (.+)", "Updated %@"),
        Rule("(\\d+[dhm]) ago", "%@ ago"),
        Rule("Refresh timed out after (.+)", "Refresh timed out after %@"),
        Rule("Rate limited, retry in ~(.+)", "Rate limited, retry in ~%@"),
        Rule("Live usage rate limited - retry in ~(.+)", "Live usage rate limited - retry in ~%@"),
        Rule("(.+) Retrying in ~(.+)\\.", "%@ Retrying in ~%@."),
        Rule("(.+) request failed \\(HTTP (\\d+)\\)\\. Try again later\\.", "%@ request failed (HTTP %@). Try again later.", translateCaptures: false),
        Rule("(.+) request failed \\(HTTP (\\d+)\\)\\.", "%@ request failed (HTTP %@).", translateCaptures: false),
        Rule("Request failed \\(HTTP (\\d+)\\)\\.", "Request failed (HTTP %@).", translateCaptures: false),
        Rule("Refresh failed: (.+)", "Refresh failed: %@"),
        Rule("Only includes (.+)\\.", "Only includes %@.", translateCaptures: false),
        Rule("Total cost (.+) across (\\d+) providers", "Total cost %@ across %@ providers", translateCaptures: false),
        Rule("Total tokens (.+) across (\\d+) providers", "Total tokens %@ across %@ providers", translateCaptures: false),
        Rule("Blended cost per megatoken (.+) across (\\d+) providers", "Blended cost per megatoken %@ across %@ providers", translateCaptures: false),
        Rule("Copy (.+) Screenshot", "Copy %@ Screenshot"),
        Rule("Hide (.+)", "Hide %@", translateCaptures: false),
        Rule("Refresh (.+)", "Refresh %@", translateCaptures: false),
        Rule("Open (.+)", "Open %@", translateCaptures: false),
        Rule("Reset (\\d+), (.+)", "Reset %@, %@", translateCaptures: false),
        Rule("Reset ([A-Z][^,]*)", "Reset %@", translateCaptures: false),
        Rule("(.+), opens in browser", "%@, opens in browser"),
        Rule("peak (.+)", "peak %@", translateCaptures: false),
        Rule("(\\S+) dollars", "%@ dollars", translateCaptures: false),
        Rule("OpenUsage (.+) is ready to download\\.", "OpenUsage %@ is ready to download.", translateCaptures: false),
        Rule("Up to (\\d+) stars per provider", "Up to %@ stars per provider", translateCaptures: false)
    ] + Rule.when
}

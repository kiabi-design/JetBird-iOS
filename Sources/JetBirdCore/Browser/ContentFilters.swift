//
//  ContentFilters.swift
//  JetBirdCore
//
//  Ad-block filter engine using WebKit Content Rule Lists
//  Compatible with EasyList/uBlock Origin filter syntax
//

import Foundation
import WebKit

// MARK: - Filter Engine

/// Ad-block filter engine using WKContentRuleList
public actor ContentFilterEngine {
    public static let shared = ContentFilterEngine()

    private var ruleList: WKContentRuleList?
    private var isEnabled = true
    private let filterQueue = DispatchQueue(label: "com.jetbird.filters", qos: .utility)

    // Compiled filter lists (embedded as resources)
    private let easylistRules: String
    private let easyprivacyRules: String
    private let ublockRules: String
    private let customRules: String = ""

    private init() {
        // Load embedded filter lists
        self.easylistRules = Self.loadFilterList("easylist") ?? ""
        self.easyprivacyRules = Self.loadFilterList("easyprivacy") ?? ""
        self.ublockRules = Self.loadFilterList("ublock") ?? ""

        Task {
            await compileRules()
        }
    }

    /// Enable/disable filtering
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Check if filtering is enabled
    public var enabled: Bool {
        isEnabled
    }

    /// Get compiled rule list for WebView
    public var contentRuleList: WKContentRuleList? {
        ruleList
    }

    /// Recompile rules (e.g., after update)
    public func recompile() async {
        await compileRules()
    }

    /// Add custom rule
    public func addCustomRule(_ rule: String) async {
        // In a full implementation, this would append to customRules and recompile
        await compileRules()
    }

    /// Remove custom rule
    public func removeCustomRule(_ rule: String) async {
        await compileRules()
    }

    // MARK: - Private

    private func compileRules() async {
        let combinedRules = """
        [
        \(easylistRules),
        \(easyprivacyRules),
        \(ublockRules),
        \(customRules)
        ]
        """

        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "com.jetbird.adblock",
                encodedContentRuleList: combinedRules
            ) { [weak self] ruleList, error in
                if let error = error {
                    print("Filter compilation error: \(error)")
                } else {
                    self?.ruleList = ruleList
                }
                continuation.resume()
            }
        }
    }

    private static func loadFilterList(_ name: String) -> String? {
        // Load from embedded resources
        // In production, these would be bundled as .json files converted to rule list format
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        return convertToRuleList(json)
    }

    private static func convertToRuleList(_ filters: [[String: Any]]) -> String {
        var rules: [[String: Any]] = []
        var ruleIndex = 1

        for filter in filters {
            guard let trigger = filter["trigger"] as? [String: Any],
                  let action = filter["action"] as? [String: Any] else { continue }

            var rule: [String: Any] = [
                "trigger": trigger,
                "action": action
            ]

            // Add regex for url-filter if present
            if let urlFilter = trigger["url-filter"] as? String {
                rule["trigger"] = [
                    "url-filter": urlFilter,
                    "resource-type": trigger["resource-type"] ?? [],
                    "load-type": trigger["load-type"] ?? [],
                    "if-domain": trigger["if-domain"] ?? [],
                    "unless-domain": trigger["unless-domain"] ?? []
                ]
            }

            rules.append(rule)
            ruleIndex += 1
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: rules)
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            return "[]"
        }
    }
}

// MARK: - Filter List Parser (EasyList/uBlock format)

/// Parse EasyList/uBlock text format to WKContentRuleList JSON
public struct FilterListParser {
    public static func parse(_ text: String) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip comments and metadata
            if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[") {
                continue
            }

            // Parse rule
            if let rule = parseRule(trimmed) {
                rules.append(rule)
            }
        }

        return rules
    }

    private static func parseRule(_ line: String) -> [String: Any]? {
        // Exception rules (@@)
        if line.hasPrefix("@@") {
            return parseExceptionRule(String(line.dropFirst(2)))
        }

        // Element hiding (##, #@#)
        if line.contains("##") || line.contains("#@#") {
            return parseElementHidingRule(line)
        }

        // Network filtering (||, |, ^, $)
        return parseNetworkRule(line)
    }

    private static func parseExceptionRule(_ line: String) -> [String: Any]? {
        // @@||example.com^$document -> allow all on example.com
        var trigger: [String: Any] = ["url-filter": ".*"]
        var action: [String: Any] = ["type": "ignore-previous-rules"]

        // Parse options after $
        if let dollarIndex = line.firstIndex(of: "$") {
            let pattern = String(line[..<dollarIndex])
            let options = String(line[line.index(after: dollarIndex)...])

            trigger["url-filter"] = convertPattern(pattern)
            action = parseOptions(options)
        } else {
            trigger["url-filter"] = convertPattern(line)
        }

        return ["trigger": trigger, "action": action]
    }

    private static func parseNetworkRule(_ line: String) -> [String: Any]? {
        var pattern = line
        var options: [String] = []

        // Extract options
        if let dollarIndex = line.firstIndex(of: "$") {
            pattern = String(line[..<dollarIndex])
            options = String(line[line.index(after: dollarIndex)...])
                .components(separatedBy: ",")
        }

        // Convert pattern to regex
        let urlFilter = convertPattern(pattern)

        var trigger: [String: Any] = ["url-filter": urlFilter]
        var action: [String: Any] = ["type": "block"]

        // Parse options
        for option in options {
            switch option {
            case "third-party":
                trigger["load-type"] = ["third-party"]
            case "first-party":
                trigger["load-type"] = ["first-party"]
            case let opt where opt.hasPrefix("domain="):
                let domains = String(opt.dropFirst(7)).components(separatedBy: "|")
                trigger["if-domain"] = domains
            case let opt where opt.hasPrefix("~domain="):
                let domains = String(opt.dropFirst(8)).components(separatedBy: "|")
                trigger["unless-domain"] = domains
            case "script":
                trigger["resource-type"] = ["script"]
            case "image":
                trigger["resource-type"] = ["image"]
            case "stylesheet":
                trigger["resource-type"] = ["style-sheet"]
            case "xmlhttprequest", "fetch":
                trigger["resource-type"] = ["xml-http-request"]
            case "subdocument":
                trigger["resource-type"] = ["sub-frame"]
            case "document":
                action["type"] = "block"
            default:
                break
            }
        }

        return ["trigger": trigger, "action": action]
    }

    private static func parseElementHidingRule(_ line: String) -> [String: Any]? {
        // Element hiding is cosmetic - handled by CSS injection in WebView
        // For WKContentRuleList, we can't do cosmetic filtering directly
        // This would need a separate WKUserScript approach
        return nil
    }

    private static func convertPattern(_ pattern: String) -> String {
        var regex = pattern

        // Escape special regex chars except our wildcards
        regex = regex
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "+", with: "\\+")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "^", with: "\\^")
            .replacingOccurrences(of: "$", with: "\\$")

        // Convert wildcards
        regex = regex
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "||", with: "^(?:[^:]+:)?//(?:[^/]+\\.)?")
            .replacingOccurrences(of: "|", with: "^")
            .replacingOccurrences(of: "^", with: "(?:[?&/]|$)") // separator

        // Anchor
        if !regex.hasPrefix("^") {
            regex = ".*" + regex
        }
        if !regex.hasSuffix("$") {
            regex = regex + ".*"
        }

        return regex
    }

    private static func parseOptions(_ options: String) -> [String: Any] {
        var action: [String: Any] = ["type": "block"]

        for option in options.components(separatedBy: ",") {
            switch option {
            case "document":
                action["type"] = "block"
            case "elemhide":
                // Cosmetic - not supported in rule list
                break
            case "popup":
                action["type"] = "block"
            case "generichide":
                break
            case "genericblock":
                break
            default:
                break
            }
        }

        return action
    }
}

// MARK: - Filter List Updater

/// Download and update filter lists from upstream
public actor FilterListUpdater {
    public static let shared = FilterListUpdater()

    private let updateInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private var lastUpdate: Date?
    private let engine = ContentFilterEngine.shared

    // Upstream sources
    private let sources = [
        "easylist": "https://easylist.to/easylist/easylist.txt",
        "easyprivacy": "https://easylist.to/easylist/easyprivacy.txt",
        "ublock-ads": "https://raw.githubusercontent.com/uBlockOrigin/uAssets/main/filters/filters.txt",
        "ublock-privacy": "https://raw.githubusercontent.com/uBlockOrigin/uAssets/main/filters/privacy.txt",
        "ublock-mobile": "https://raw.githubusercontent.com/uBlockOrigin/uAssets/main/filters/filters-mobile.txt",
    ]

    private init() {
        lastUpdate = UserDefaults.standard.object(forKey: "jetbird.filter.lastUpdate") as? Date
    }

    /// Check and update if needed
    public func updateIfNeeded() async {
        guard shouldUpdate() else { return }
        await updateAll()
    }

    /// Force update all lists
    public func updateAll() async {
        for (name, urlString) in sources {
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let text = String(data: data, encoding: .utf8) else { continue }

                // Parse and save
                let rules = FilterListParser.parse(text)
                try await saveFilterList(name: name, rules: rules)

            } catch {
                print("Failed to update \(name): \(error)")
            }
        }

        lastUpdate = Date()
        UserDefaults.standard.set(lastUpdate, forKey: "jetbird.filter.lastUpdate")

        // Recompile engine
        await engine.recompile()
    }

    private func shouldUpdate() -> Bool {
        guard let last = lastUpdate else { return true }
        return Date().timeIntervalSince(last) > updateInterval
    }

    private func saveFilterList(name: String, rules: [[String: Any]]) async throws {
        let url = getFilterListURL(name: name)
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func getFilterListURL(name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Filters/\(name).json")
    }
}
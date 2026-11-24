//
//  ContentFilters.swift
//  JetBird
//
//  Ad-block using WebKit content rule lists. The bundled lists (Resources/filters/*.json)
//  are already in WKContentRuleList JSON format.
//

import Foundation
import WebKit

@MainActor
public final class ContentFilterEngine: ObservableObject {
    public static let shared = ContentFilterEngine()

    @Published public private(set) var ruleList: WKContentRuleList?
    private var isPreparing = false

    private init() {}

    /// Compile the bundled rule lists once.
    public func prepare() async {
        guard ruleList == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        var rules: [Any] = []
        for name in ["easylist", "easyprivacy", "ublock"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { continue }
            rules.append(contentsOf: array)
        }
        guard !rules.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return }

        ruleList = await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "com.jetbird.adblock",
                encodedContentRuleList: json
            ) { list, error in
                if let error = error { print("Filter compilation error: \(error)") }
                continuation.resume(returning: list)
            }
        }
    }
}

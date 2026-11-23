//
//  Localization.swift
//  JetBird
//
//  In-app language switching (Russian / English).
//  SwiftUI literals are localized through the `\.locale` environment value;
//  plain Strings go through `L(...)`, which reads the selected .lproj bundle.
//

import Foundation

enum Loc {
    private static let lock = NSLock()
    private static var bundle: Bundle = Bundle.main

    static let supported = ["ru", "en"]

    /// Switch the language used by `L(...)`.
    static func setLanguage(_ code: String) {
        var selected = Bundle.main
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            selected = languageBundle
        }
        lock.lock()
        bundle = selected
        lock.unlock()
    }

    static func tr(_ key: String) -> String {
        lock.lock()
        let current = bundle
        lock.unlock()
        return current.localizedString(forKey: key, value: key, table: nil)
    }
}

func L(_ key: String) -> String {
    Loc.tr(key)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Loc.tr(key), arguments: arguments)
}

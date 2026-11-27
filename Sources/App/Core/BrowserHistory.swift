//
//  BrowserHistory.swift
//  JetBird
//

import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    let url: String
    var title: String
    var date: Date
}

/// Browsing history (newest first), stored as JSON in Application Support.
@MainActor
final class BrowserHistoryStore: ObservableObject {
    static let shared = BrowserHistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 1000
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("browser-history.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func record(url: URL, title: String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let address = url.absoluteString
        var name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = url.host ?? address }

        if let first = entries.first, first.url == address {
            entries[0].title = name
            entries[0].date = Date()
        } else {
            entries.insert(HistoryEntry(url: address, title: name, date: Date()), at: 0)
            if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        }
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

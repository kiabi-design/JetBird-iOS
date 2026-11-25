//
//  BrowserHistory.swift
//  JetBird
//

import Foundation
import Combine

struct BrowserHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let url: String
    let title: String
    let date: Date

    init(id: UUID = UUID(), url: String, title: String, date: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.date = date
    }
}

@MainActor
final class BrowserHistoryStore: ObservableObject {
    static let shared = BrowserHistoryStore()

    @Published private(set) var entries: [BrowserHistoryEntry] = []

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("JetBird", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("browser_history.json")
        load()
    }

    func record(url: URL, title: String?) {
        let address = url.absoluteString
        guard !address.isEmpty, address != "about:blank" else { return }
        let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? (url.host ?? address)

        entries.removeAll { $0.url == address && Calendar.current.isDateInToday($0.date) }
        entries.insert(BrowserHistoryEntry(url: address, title: name, date: Date()), at: 0)
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data) else {
            return
        }
        entries = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: Data.WritingOptions.atomic)
    }
}

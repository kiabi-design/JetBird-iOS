//
//  DownloadFolder.swift
//  JetBird
//
//  Optional user-chosen download folder (security-scoped bookmark).
//  If nothing is chosen, files go to Documents/JetBird/<Category>, which is
//  visible in the Files app under "On My iPhone > JetBird".
//

import Foundation

final class DownloadFolderStore: @unchecked Sendable {
    static let shared = DownloadFolderStore()

    private static let key = "jetbird.downloadFolderBookmark.v1"
    private let lock = NSLock()
    private var accessedURL: URL?

    private init() {}

    /// The chosen folder, or nil for the default location.
    /// Security-scoped access stays open for the lifetime of the app.
    var folderURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        if let url = accessedURL { return url }
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
        if isStale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: Self.key)
        }
        return url
    }

    var folderName: String? {
        folderURL?.lastPathComponent
    }

    func select(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        let data: Data
        do {
            data = try url.bookmarkData()
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }

        lock.lock()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = started ? url : nil
        lock.unlock()

        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func reset() {
        lock.lock()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Default location: Documents/JetBird
    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JetBird", isDirectory: true)
    }
}

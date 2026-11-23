//
//  JetBirdApp.swift
//  JetBird
//

import SwiftUI
import UIKit

// MARK: - Settings store

@MainActor
final class AppSettingsStore: ObservableObject {
    private static let storageKey = "jetbird.settings.v1"

    @Published var settings: AppSettings {
        didSet {
            if !Loc.supported.contains(settings.language) { settings.language = "ru" }
            Loc.setLanguage(settings.language)
            save()
        }
    }

    /// Name of the user-chosen download folder (nil = default JetBird folder in Files)
    @Published private(set) var downloadFolderName: String?
    @Published var folderError: String?

    init() {
        var loaded = AppSettings()
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = saved
        }
        if !Loc.supported.contains(loaded.language) { loaded.language = "ru" }
        settings = loaded
        Loc.setLanguage(loaded.language)
        downloadFolderName = DownloadFolderStore.shared.folderName
    }

    var locale: Locale { Locale(identifier: settings.language) }

    func selectDownloadFolder(_ url: URL) {
        do {
            try DownloadFolderStore.shared.select(url)
            downloadFolderName = DownloadFolderStore.shared.folderName
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
    }

    func resetDownloadFolder() {
        DownloadFolderStore.shared.reset()
        downloadFolderName = nil
        folderError = nil
    }

    /// Opens the download folder in the Files app.
    func openDownloadFolder() {
        let folder = DownloadFolderStore.shared.folderURL ?? DownloadFolderStore.defaultRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoded = folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder.path
        if let url = URL(string: "shareddocuments://" + encoded) {
            UIApplication.shared.open(url)
        }
    }

    var colorScheme: ColorScheme? {
        switch settings.theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - App

@main
struct JetBirdApp: App {
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var settings = AppSettingsStore()
    @StateObject private var discovery = PSMTPDiscovery()
    @StateObject private var link = PS4LinkModel()
    @StateObject private var filters = ContentFilterEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloads)
                .environmentObject(settings)
                .environmentObject(discovery)
                .environmentObject(link)
                .environmentObject(filters)
                .environment(\.locale, settings.locale)
                .preferredColorScheme(settings.colorScheme)
                .task { await filters.prepare() }
        }
    }
}

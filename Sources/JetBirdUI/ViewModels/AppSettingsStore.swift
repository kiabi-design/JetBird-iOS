//
//  AppSettingsStore.swift
//  JetBirdUI
//
//  Persistent settings store
//

import Foundation
import SwiftUI
import JetBirdCore
import Combine

/// Observable settings store with persistence
@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var settings: AppSettings = AppSettings()

    private let userDefaults = UserDefaults.standard
    private let settingsKey = "jetbird.settings"

    // Computed properties for easy binding
    var transferMode: TransferMode {
        get { settings.transferMode }
        set { update { $0.transferMode = newValue } }
    }

    var downloadParts: Int {
        get { settings.downloadParts }
        set { update { $0.downloadParts = newValue } }
    }

    var saveFileOnPhone: Bool {
        get { settings.saveFileOnPhone }
        set { update { $0.saveFileOnPhone = newValue } }
    }

    var theme: AppSettings.AppTheme {
        get { settings.theme }
        set { update { $0.theme = newValue } }
    }

    var language: String {
        get { settings.language }
        set { update { $0.language = newValue } }
    }

    var enableAdBlock: Bool {
        get { settings.enableAdBlock }
        set { update { $0.enableAdBlock = newValue } }
    }

    var enableBackgroundDownloads: Bool {
        get { settings.enableBackgroundDownloads }
        set { update { $0.enableBackgroundDownloads = newValue } }
    }

    var showDesktopSite: Bool {
        get { settings.showDesktopSite }
        set { update { $0.showDesktopSite = newValue } }
    }

    var searchEngine: AppSettings.SearchEngine {
        get { settings.searchEngine }
        set { update { $0.searchEngine = newValue } }
    }

    var parallelInstallEnabled: Bool {
        get { settings.parallelInstallEnabled }
        set { update { $0.parallelInstallEnabled = newValue } }
    }

    var verifyDownloads: Bool {
        get { settings.verifyDownloads }
        set { update { $0.verifyDownloads = newValue } }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    init() {}

    func load() async {
        if let data = userDefaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }

        // Migrate legacy settings if needed
        await migrateIfNeeded()
    }

    func save() async {
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: settingsKey)
        }
    }

    func reset() async {
        settings = AppSettings()
        await save()
    }

    private func update(_ modify: (inout AppSettings) -> Void) {
        modify(&settings)
        Task { await save() }
    }

    private func migrateIfNeeded() async {
        // Migration logic for future versions
        let version = userDefaults.integer(forKey: "jetbird.settings.version")
        if version < 1 {
            // First run migrations
            userDefaults.set(1, forKey: "jetbird.settings.version")
        }
    }
}
//
//  JetBirdApp.swift
//  JetBird
//

import SwiftUI

// MARK: - Settings store

@MainActor
final class AppSettingsStore: ObservableObject {
    private static let storageKey = "jetbird.settings.v1"

    @Published var settings: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = AppSettings()
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
                .preferredColorScheme(settings.colorScheme)
                .task { await filters.prepare() }
        }
    }
}

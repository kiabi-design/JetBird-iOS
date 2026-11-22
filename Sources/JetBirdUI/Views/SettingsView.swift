//
//  SettingsView.swift
//  JetBirdUI
//
//  Settings screen
//

import SwiftUI
import JetBirdCore

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettingsStore
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) var dismiss

    @State private var showClearCache = false
    @State private var showResetSettings = false

    var body: some View {
        NavigationStack {
            Form {
                // Transfer Section
                Section("Transfer") {
                    Picker("Transfer Mode", selection: $settings.transferMode) {
                        ForEach(TransferMode.allCases.filter { $0.isAvailableOnIOS }) { mode in
                            Label(mode.displayName, systemImage: modeIcon(mode))
                                .tag(mode)
                        }
                    }

                    if settings.transferMode == .wireless {
                        NavigationLink("PS4 Connections") {
                            PS4ConnectionsSettingsView()
                        }
                    }

                    Stepper("Download Parts: \(settings.downloadParts)", value: $settings.downloadParts, in: 1...8)

                    Toggle("Save File on Phone", isOn: $settings.saveFileOnPhone)

                    Toggle("Parallel PKG Install", isOn: $settings.parallelInstallEnabled)

                    Toggle("Verify Downloads (SHA-256)", isOn: $settings.verifyDownloads)
                }

                // Downloads Section
                Section("Downloads") {
                    Toggle("Background Downloads", isOn: $settings.enableBackgroundDownloads)

                    NavigationLink("Download Folder") {
                        DownloadFolderView()
                    }
                }

                // Browser Section
                Section("Browser") {
                    Toggle("Ad Block", isOn: $settings.enableAdBlock)

                    Toggle("Desktop Site", isOn: $settings.showDesktopSite)

                    Picker("Search Engine", selection: $settings.searchEngine) {
                        ForEach(AppSettings.SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }

                    NavigationLink("Clear Browsing Data") {
                        ClearBrowsingDataView()
                    }
                }

                // Appearance Section
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppSettings.AppTheme.allCases) { theme in
                            Text(theme.rawValue.capitalized).tag(theme)
                        }
                    }

                    Picker("Language", selection: $settings.language) {
                        ForEach(availableLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }

                // Advanced Section
                Section("Advanced") {
                    Toggle("Battery Optimization Warning", isOn: $settings.batteryOptimizationWarningShown)

                    Button("Clear All Downloads Cache") {
                        showClearCache = true
                    }
                    .foregroundStyle(.red)

                    Button("Reset All Settings") {
                        showResetSettings = true
                    }
                    .foregroundStyle(.red)
                }

                // About Section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(JetBirdVersion) (\(JetBirdBuildNumber))")
                            .foregroundStyle(.secondary)
                    }

                    Link("Source Code (GitHub)", destination: URL(string: "https://github.com/nueex/JetBird")!)

                    Link("PS MTP Explorer", destination: URL(string: "https://github.com/nueex/ps-mtp-explorer")!)

                    Link("Report Issue", destination: URL(string: "https://github.com/nueex/JetBird/issues")!)

                    Link("License (GPL-3.0)", destination: URL(string: "https://github.com/nueex/JetBird/blob/main/LICENSE")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear cache?", isPresented: $showClearCache, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) {
                    Task { await clearCache() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all temporary download files.")
            }
            .confirmationDialog("Reset settings?", isPresented: $showResetSettings, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    Task { await settings.reset() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will reset all settings to defaults.")
            }
        }
    }

    private func modeIcon(_ mode: TransferMode) -> String {
        switch mode {
        case .none: return "iphone"
        case .usbTransfer: return "cable.connector"
        case .wireless: return "wifi"
        }
    }

    private func clearCache() async {
        // Clear temp files
        let tempDir = FileManager.default.temporaryDirectory
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
}

// MARK: - PS4 Connections Settings

struct PS4ConnectionsSettingsView: View {
    @EnvironmentObject var settings: AppSettingsStore
    @EnvironmentObject var psmtpDiscovery: PSMTPDiscovery

    @State private var connections: [PS4Connection] = []
    @State private var showAddConnection = false

    var body: some View {
        List {
            Section("Paired Consoles") {
                if connections.isEmpty {
                    Text("No PS4 consoles paired")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connections) { connection in
                        HStack {
                            Image(systemName: "playstation.logo")
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading) {
                                Text(connection.name)
                                Text(connection.ipAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if connection.isPaired {
                                Image(systemName: "link")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .onDelete { indices in
                        for index in indices {
                            // Remove pairing
                        }
                    }
                }
            }

            Section {
                Button("Scan for PS4") {
                    Task { await psmtpDiscovery.start() }
                }

                Button("Pair New PS4") {
                    showAddConnection = true
                }
            }
        }
        .navigationTitle("PS4 Connections")
        .sheet(isPresented: $showAddConnection) {
            PairingView()
        }
    }
}

// MARK: - Download Folder View

struct DownloadFolderView: View {
    @EnvironmentObject var settings: AppSettingsStore

    var body: some View {
        List {
            Section("Current Folder") {
                if let folder = settings.customDownloadFolder {
                    Text(folder.path)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("Default (Downloads/JetBird)")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Choose Custom Folder") {
                    // Show document picker
                }

                if settings.customDownloadFolder != nil {
                    Button("Use Default", role: .destructive) {
                        settings.settings.customDownloadFolder = nil
                        Task { await settings.save() }
                    }
                }
            }
        }
        .navigationTitle("Download Folder")
    }
}

// MARK: - Clear Browsing Data

struct ClearBrowsingDataView: View {
    @Environment(\.dismiss) var dismiss

    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var clearBookmarks = false

    var body: some View {
        Form {
            Section {
                Toggle("History", isOn: $clearHistory)
                Toggle("Cookies & Site Data", isOn: $clearCookies)
                Toggle("Cached Files", isOn: $clearCache)
                Toggle("Bookmarks", isOn: $clearBookmarks)
            }

            Section {
                Button("Clear Data") {
                    // Clear selected data
                    dismiss()
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Clear Browsing Data")
    }
}

// MARK: - Available Languages

private let availableLanguages = [
    (code: "en", name: "English"),
    (code: "fr", name: "Français"),
    (code: "ar", name: "العربية"),
    (code: "es", name: "Español"),
    (code: "ru", name: "Русский"),
    (code: "zh-Hans", name: "简体中文"),
    (code: "hi", name: "हिन्दी"),
]
//
//  SettingsView.swift
//  JetBird
//

import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppSettingsStore
    @State private var clearedMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Downloads") {
                    Stepper("Parts per download: \(store.settings.downloadParts)",
                            value: $store.settings.downloadParts, in: 1...8)
                }

                Section("Browser") {
                    Picker("Search engine", selection: $store.settings.searchEngine) {
                        ForEach(AppSettings.SearchEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    Toggle("Block ads and trackers", isOn: $store.settings.enableAdBlock)
                    Toggle("Request desktop sites", isOn: $store.settings.showDesktopSite)
                    Button("Clear browsing data", role: .destructive) {
                        Task {
                            await clearBrowsingData()
                            clearedMessage = "Browsing data cleared."
                        }
                    }
                    if let clearedMessage = clearedMessage {
                        Text(clearedMessage).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $store.settings.theme) {
                        Text("System").tag(AppSettings.AppTheme.system)
                        Text("Light").tag(AppSettings.AppTheme.light)
                        Text("Dark").tag(AppSettings.AppTheme.dark)
                    }
                    .pickerStyle(.segmented)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0").foregroundColor(.secondary)
                    }
                    Text("JetBird for iOS is free software released under the GPL-3.0-or-later license. It is a port of nueex/JetBird.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func clearBrowsingData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}

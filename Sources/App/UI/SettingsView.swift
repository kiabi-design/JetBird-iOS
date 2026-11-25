//
//  SettingsView.swift
//  JetBird
//

import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppSettingsStore
    @State private var clearedMessage: String?
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $store.settings.language) {
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Language")
                }

                Section {
                    Picker("Default destination in the Add form", selection: Binding(
                        get: { store.settings.defaultDestination ?? .phone },
                        set: { store.settings.defaultDestination = $0 }
                    )) {
                        ForEach(TransferDestination.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    Stepper("Parts per download: \(store.settings.downloadParts)",
                            value: $store.settings.downloadParts, in: 1...8)
                } header: {
                    Text("Downloads")
                }

                Section {
                    HStack {
                        Text("Save to")
                        Spacer()
                        Text(store.downloadFolderName ?? L("Files > JetBird"))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Choose folder...") { showFolderPicker = true }
                    if store.downloadFolderName != nil {
                        Button("Use default folder") { store.resetDownloadFolder() }
                    }
                    Button("Open in Files") { store.openDownloadFolder() }
                    if let error = store.folderError {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                } header: {
                    Text("Download folder")
                } footer: {
                    Text("By default files are saved to the Files app: On My iPhone > JetBird.")
                }

                Section {
                    Picker("Search engine", selection: $store.settings.searchEngine) {
                        ForEach(AppSettings.SearchEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    Toggle("Block ads and trackers", isOn: $store.settings.enableAdBlock)
                    Toggle("Open pop-ups in the background", isOn: Binding(
                        get: { store.settings.popupsInBackground ?? false },
                        set: { store.settings.popupsInBackground = $0 }
                    ))
                    Toggle("Request desktop sites", isOn: $store.settings.showDesktopSite)
                    Button("Clear browsing data", role: .destructive) {
                        Task {
                            await clearBrowsingData()
                            clearedMessage = L("Browsing data cleared.")
                        }
                    }
                    if let clearedMessage = clearedMessage {
                        Text(clearedMessage).font(.footnote).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Browser")
                }

                Section {
                    Picker("Theme", selection: $store.settings.theme) {
                        Text("System").tag(AppSettings.AppTheme.system)
                        Text("Light").tag(AppSettings.AppTheme.light)
                        Text("Dark").tag(AppSettings.AppTheme.dark)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0").foregroundColor(.secondary)
                    }
                    Text("JetBird for iOS is free software released under the GPL-3.0-or-later license. It is a port of nueex/JetBird.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    store.selectDownloadFolder(url)
                case .failure(let error):
                    store.folderError = error.localizedDescription
                }
            }
        }
    }

    private func clearBrowsingData() async {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}

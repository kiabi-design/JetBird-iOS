//
//  ContentView.swift
//  JetBird
//

import SwiftUI

struct ContentView: View {
    enum Tab: Hashable {
        case downloads, browser, transfers, settings
    }

    @State private var tab: Tab = .downloads

    var body: some View {
        TabView(selection: $tab) {
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(Tab.downloads)

            BrowserView(onDownloadQueued: { tab = .downloads })
                .tabItem { Label("Browser", systemImage: "globe") }
                .tag(Tab.browser)

            TransfersView()
                .tabItem { Label("Transfers", systemImage: "gamecontroller") }
                .tag(Tab.transfers)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}

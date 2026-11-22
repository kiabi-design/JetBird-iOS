//
//  ContentView.swift
//  JetBirdUI
//
//  Main app view with tab navigation
//

import SwiftUI
import JetBirdCore

struct ContentView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var settings: AppSettingsStore
    @EnvironmentObject var spake2Manager: Spake2Manager
    @EnvironmentObject var psmtpDiscovery: PSMTPDiscovery

    @State private var selectedTab: Tab = .downloads
    @State private var showSettings = false
    @State private var showAddDownload = false
    @State private var showBrowser = false
    @State private var showPairing = false

    enum Tab: String, CaseIterable {
        case downloads = "Downloads"
        case browser = "Browser"
        case transfers = "Transfers"

        var systemImage: String {
            switch self {
            case .downloads: return "arrow.down.circle"
            case .browser: return "safari"
            case .transfers: return "antenna.radiowaves.left.and.right"
            }
        }

        var filledSystemImage: String {
            switch self {
            case .downloads: return "arrow.down.circle.fill"
            case .browser: return "safari.fill"
            case .transfers: return "antenna.radiowaves.left.and.right.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Downloads Tab
            NavigationStack {
                DownloadsView()
                    .navigationTitle("Downloads")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gear")
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showAddDownload = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
            }
            .tabItem {
                Label(Tab.downloads.rawValue, systemImage: selectedTab == .downloads ? Tab.downloads.filledSystemImage : Tab.downloads.systemImage)
            }
            .tag(Tab.downloads)

            // Browser Tab
            NavigationStack {
                BrowserView()
                    .navigationTitle("Browser")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu {
                                Button("New Tab") { }
                                Button("Bookmarks") { }
                                Button("History") { }
                                Divider()
                                Button("Settings") { showSettings = true }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
            }
            .tabItem {
                Label(Tab.browser.rawValue, systemImage: selectedTab == .browser ? Tab.browser.filledSystemImage : Tab.browser.systemImage)
            }
            .tag(Tab.browser)

            // Transfers Tab (PS4 connections)
            NavigationStack {
                TransfersView()
                    .navigationTitle("PS4 Transfers")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gear")
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showPairing = true
                            } label: {
                                Label("Pair", systemImage: "qrcode.viewfinder")
                            }
                        }
                    }
            }
            .tabItem {
                Label(Tab.transfers.rawValue, systemImage: selectedTab == .transfers ? Tab.transfers.filledSystemImage : Tab.transfers.systemImage)
            }
            .tag(Tab.transfers)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddDownload) {
            AddDownloadView()
        }
        .sheet(isPresented: $showPairing) {
            PairingView()
        }
        .onChange(of: settings.transferMode) { _, newMode in
            Task {
                if newMode == .wireless {
                    await psmtpDiscovery.start()
                } else {
                    await psmtpDiscovery.stop()
                }
            }
        }
    }
}

// MARK: - Downloads View

struct DownloadsView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var settings: AppSettingsStore

    @State private var downloads: [DownloadInfo] = []
    @State private var showOnlyActive = false

    var filteredDownloads: [DownloadInfo] {
        if showOnlyActive {
            return downloads.filter { $0.state.isActive }
        }
        return downloads
    }

    var body: some View {
        List {
            if filteredDownloads.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Tap + to add a download")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filteredDownloads) { download in
                        DownloadRow(download: download)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if download.state.isActive {
                                    Button(role: .destructive) {
                                        Task { await downloadManager.cancelDownload(download.id) }
                                    } label: {
                                        Label("Cancel", systemImage: "xmark.circle")
                                    }
                                } else if download.state == .paused {
                                    Button {
                                        Task { await downloadManager.resumeDownload(download.id) }
                                    } label: {
                                        Label("Resume", systemImage: "play.circle")
                                    }
                                    .tint(.green)
                                }

                                Button(role: .destructive) {
                                    Task { await downloadManager.removeDownload(download.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if download.state == .downloading {
                                    Button {
                                        Task { await downloadManager.pauseDownload(download.id) }
                                    } label: {
                                        Label("Pause", systemImage: "pause.circle")
                                    }
                                    .tint(.orange)
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Downloads")
                        Spacer()
                        Toggle("Active Only", isOn: $showOnlyActive)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
        }
        .refreshable {
            await refreshDownloads()
        }
        .task {
            await refreshDownloads()
            // Observe changes
            for await _ in downloadManagerDownloadUpdates() {
                await refreshDownloads()
            }
        }
    }

    private func refreshDownloads() async {
        downloads = await downloadManager.getAllDownloads()
    }

    private func downloadManagerDownloadUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // In a real implementation, use a proper publisher
            // For now, poll periodically
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                    continuation.yield()
                }
            }
        }
    }
}

struct DownloadRow: View {
    let download: DownloadInfo
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: filename + state
            HStack {
                Image(systemName: download.category.systemImageName)
                    .foregroundStyle(categoryColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(download.filename)
                        .font(.headline)
                        .lineLimit(1)

                    Text(download.url.host() ?? "Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                StateBadge(state: download.state)
            }

            // Progress bar
            if download.state.isActive || download.state == .completed {
                ProgressView(value: download.progress)
                    .progressViewStyle(.linear)
                    .tint(progressColor)
            }

            // Stats row
            HStack {
                if download.totalSize > 0 {
                    Label(
                        "\(download.formattedDownloaded) / \(download.formattedSize)",
                        systemImage: "arrow.down.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if let speed = download.speed {
                    Label(speed, systemImage: "speedometer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if download.isParallelInstall {
                    Label("Parallel Install", systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                Label(download.destination.displayName, systemImage: destinationIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var categoryColor: Color {
        switch download.category {
        case .packages: return .blue
        case .videos: return .purple
        case .audio: return .orange
        case .images: return .pink
        case .documents: return .green
        case .compressed: return .brown
        case .other: return .gray
        }
    }

    private var progressColor: Color {
        switch download.state {
        case .downloading: return .blue
        case .verifying: return .orange
        case .installing: return .purple
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        default: return .gray
        }
    }

    private var destinationIcon: String {
        switch download.destination {
        case .phone: return "iphone"
        case .ps4: return "playstation.logo"
        case .both: return "iphone.and.arrow.forward"
        }
    }
}

struct StateBadge: View {
    let state: DownloadState

    var body: some View {
        Text(stateDisplayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.2))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
    }

    private var stateDisplayName: String {
        switch state {
        case .queued: return "Queued"
        case .connecting: return "Connecting"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .verifying: return "Verifying"
        case .installing: return "Installing"
        }
    }

    private var stateColor: Color {
        switch state {
        case .queued: return .gray
        case .connecting: return .blue
        case .downloading: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .verifying: return .orange
        case .installing: return .purple
        }
    }
}

// MARK: - Add Download View

struct AddDownloadView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var settings: AppSettingsStore
    @Environment(\.dismiss) var dismiss

    @State private var urlString = ""
    @State private var filename = ""
    @State private var headers: [String: String] = [:]
    @State private var parts = 4
    @State private var destination: TransferDestination = .phone
    @State private var isParallelInstall = false
    @State private var showAdvanced = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Download") {
                    TextField("URL", text: $urlString)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Filename (optional)", text: $filename)
                        .textContentType(.fileName)
                }

                Section("Options") {
                    Picker("Parts", selection: $parts) {
                        ForEach([1, 2, 4, 8], id: \.self) { n in
                            Text("\(n) part\(n > 1 ? "s" : "")").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Destination", selection: $destination) {
                        ForEach(TransferDestination.allCases) { dest in
                            Text(dest.displayName).tag(dest)
                        }
                    }

                    Toggle("Parallel PKG Install", isOn: $isParallelInstall)
                        .disabled(destination == .phone)
                }

                if showAdvanced {
                    Section("Advanced") {
                        ForEach(Array(headers.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                Spacer()
                                Text(headers[key] ?? "")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { indices in
                            for index in indices {
                                let key = Array(headers.keys.sorted())[index]
                                headers.removeValue(forKey: key)
                            }
                        }

                        Button("Add Header") {
                            // Show alert to add header
                        }
                    }
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Add Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task { await startDownload() }
                    }
                    .disabled(urlString.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Toggle("Advanced", isOn: $showAdvanced)
                }
            }
        }
    }

    private func startDownload() async {
        guard let url = URL(string: urlString) else {
            error = "Invalid URL"
            return
        }

        let finalFilename = filename.isEmpty ? url.lastPathComponent : filename

        await downloadManager.addDownload(
            url: url,
            filename: finalFilename,
            headers: headers,
            parts: parts,
            destination: destination,
            isParallelInstall: isParallelInstall
        )

        dismiss()
    }
}
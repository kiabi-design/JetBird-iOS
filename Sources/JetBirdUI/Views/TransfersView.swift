//
//  TransfersView.swift
//  JetBirdUI
//
//  PS4 Wireless Transfer management
//

import SwiftUI
import JetBirdCore

struct TransfersView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var settings: AppSettingsStore
    @EnvironmentObject var spake2Manager: Spake2Manager
    @EnvironmentObject var psmtpDiscovery: PSMTPDiscovery

    @State private var connections: [PS4Connection] = []
    @State private var showPairing = false
    @State private var showDirectDownload = false
    @State private var directDownloadURL = ""
    @State private var isDiscovering = false
    @State private var error: String?

    var body: some View {
        List {
            // Transfer mode picker
            Section("Transfer Mode") {
                Picker("Mode", selection: $settings.transferMode) {
                    ForEach(TransferMode.allCases.filter { $0.isAvailableOnIOS }) { mode in
                        Label(mode.displayName, systemImage: modeIcon(mode))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 8)
            }

            // Wireless Transfer section
            if settings.transferMode == .wireless {
                Section("PS4 Connections") {
                    if connections.isEmpty && !isDiscovering {
                        ContentUnavailableView(
                            "No PS4 Found",
                            systemImage: "playstation.logo",
                            description: Text("Make sure PS4 is on the same network with PS MTP Explorer running")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(connections) { connection in
                            ConnectionRow(connection: connection) {
                                Task { await handleConnectionTap(connection) }
                            }
                            .swipeActions {
                                if connection.isPaired {
                                    Button(role: .destructive) {
                                        Task { await unpair(connection) }
                                    } label: {
                                        Label("Unpair", systemImage: "link.badge.minus")
                                    }
                                }
                            }
                        }
                    }

                    if isDiscovering {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Scanning for PS4...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                    }
                }

                Section("Actions") {
                    Button {
                        showPairing = true
                    } label: {
                        Label("Pair New PS4 (QR Code)", systemImage: "qrcode.viewfinder")
                    }

                    Button {
                        showDirectDownload = true
                    } label: {
                        Label("Direct PS4 Download", systemImage: "arrow.down.to.line")
                    }

                    Button {
                        Task { await scanForPS4() }
                    } label: {
                        Label("Scan Network", systemImage: "magnifyingglass")
                    }
                    .disabled(isDiscovering)
                }
            }

            // Active PS4 transfers
            let ps4Downloads = downloadManager.getAllDownloads().filter { $0.destination != .phone }
            if !ps4Downloads.isEmpty {
                Section("Active Transfers") {
                    ForEach(ps4Downloads) { download in
                        TransferRow(download: download)
                    }
                }
            }

            // Info section
            Section("Info") {
                InfoRow(title: "Protocol", value: "PSMTP v3")
                InfoRow(title: "Port", value: "8080 (default)")
                InfoRow(title: "Security", value: "SPAKE2 + TLS 1.3")
                InfoRow(title: "Certificate Pinning", value: "Enabled")
            }
        }
        .navigationTitle("PS4 Transfers")
        .refreshable {
            await scanForPS4()
        }
        .sheet(isPresented: $showPairing) {
            PairingView()
        }
        .sheet(isPresented: $showDirectDownload) {
            DirectDownloadView()
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task {
            await scanForPS4()
        }
    }

    private func modeIcon(_ mode: TransferMode) -> String {
        switch mode {
        case .none: return "iphone"
        case .usbTransfer: return "cable.connector"
        case .wireless: return "wifi"
        }
    }

    private func scanForPS4() async {
        isDiscovering = true
        defer { isDiscovering = false }

        // In a real implementation, this would use PSMTPDiscovery
        // For now, simulate discovery
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Mock connections for testing
        // connections = discovered connections
    }

    private func handleConnectionTap(_ connection: PS4Connection) async {
        // Show connection details or initiate transfer
    }

    private func unpair(_ connection: PS4Connection) async {
        // Remove pairing
    }
}

struct ConnectionRow: View {
    let connection: PS4Connection
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "playstation.logo")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 12) {
                        Label(connection.ipAddress, systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if connection.isPaired {
                            Label("Paired", systemImage: "link")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Not Paired", systemImage: "link.badge.plus")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct TransferRow: View {
    let download: DownloadInfo
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "playstation.logo")
                    .foregroundStyle(.blue)

                VStack(alignment: .leading) {
                    Text(download.filename)
                        .font(.headline)
                        .lineLimit(1)

                    Text("PS4 Transfer • \(download.parts) parts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StateBadge(state: download.state)
            }

            if download.state.isActive {
                ProgressView(value: download.progress)
                    .tint(.blue)

                HStack {
                    Label(
                        "\(download.formattedDownloaded) / \(download.formattedSize)",
                        systemImage: "arrow.up.forward"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if download.isParallelInstall {
                        Label("Installing", systemImage: "shippingbox")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Direct Download View

struct DirectDownloadView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) var dismiss

    @State private var urlString = ""
    @State private var filename = ""
    @State private var headers: [String: String] = [:]
    @State private var isParallelInstall = false
    @State private var destination: TransferDestination = .ps4
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Download URL") {
                    TextField("HTTPS URL", text: $urlString)
                        .textContentType(.URL)
                        .autocapitalization(.none)

                    TextField("Filename (optional)", text: $filename)
                }

                Section("Options") {
                    Toggle("Parallel PKG Install", isOn: $isParallelInstall)

                    Picker("Destination", selection: $destination) {
                        ForEach(TransferDestination.allCases.filter { $0 != .phone }) { dest in
                            Text(dest.displayName).tag(dest)
                        }
                    }
                }

                Section("Headers (Optional)") {
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
                        // Add header
                    }
                }

                if let error = error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Direct PS4 Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send to PS4") {
                        Task { await sendDirectDownload() }
                    }
                    .disabled(urlString.isEmpty)
                }
            }
        }
    }

    private func sendDirectDownload() async {
        guard let url = URL(string: urlString), url.scheme == "https" else {
            error = "Invalid HTTPS URL"
            return
        }

        let finalFilename = filename.isEmpty ? url.lastPathComponent : filename

        let direct = DirectPS4Download(
            url: url,
            headers: headers,
            filename: finalFilename,
            isParallelInstall: isParallelInstall,
            destination: destination
        )

        // In real implementation, send via PSMTPConnection
        // await psmtpConnection.sendDirectDownload(direct)

        dismiss()
    }
}
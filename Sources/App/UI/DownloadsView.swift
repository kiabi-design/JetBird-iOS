//
//  DownloadsView.swift
//  JetBird
//

import SwiftUI
import UIKit

extension DownloadState {
    var label: String {
        switch self {
        case .queued: return L("Queued")
        case .connecting: return L("Connecting")
        case .downloading: return L("Downloading")
        case .paused: return L("Paused")
        case .completed: return L("Completed")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        case .verifying: return L("Finishing")
        case .installing: return L("Installing")
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var showAdd = false

    private var sorted: [DownloadInfo] {
        manager.downloads.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.downloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 56))
                            .foregroundColor(.secondary)
                        Text("No downloads yet")
                            .font(.headline)
                        Button("Add download") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(sorted) { item in
                            DownloadRow(info: item, speed: manager.speeds[item.id], location: manager.locationDescription(for: item.id))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        manager.remove(item.id, deleteFile: true)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        manager.remove(item.id, deleteFile: false)
                                    } label: {
                                        Label("Remove", systemImage: "xmark")
                                    }
                                    .tint(.gray)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear finished") { manager.clearFinished() }
                        .disabled(!manager.downloads.contains { $0.state.isTerminal })
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddDownloadView() }
        }
    }
}

struct DownloadRow: View {
    let info: DownloadInfo
    let speed: Int64?
    var location: String? = nil
    @EnvironmentObject private var manager: DownloadManager

    private var statusText: String {
        var parts = [info.state.label]
        switch info.state {
        case .downloading, .paused:
            if info.totalSize > 0 {
                parts.append(L("%@ of %@", info.formattedDownloaded, info.formattedSize))
            } else {
                parts.append(info.formattedDownloaded)
            }
        case .completed:
            if info.totalSize > 0 { parts.append(info.formattedSize) }
        default:
            break
        }
        if let speed = speed, speed > 0, info.state == .downloading {
            parts.append(ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.category.systemImageName)
                .font(.title2)
                .frame(width: 32)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(info.filename)
                    .font(.headline)
                    .lineLimit(2)

                if info.state.isActive || info.state == .paused {
                    if info.totalSize > 0 {
                        ProgressView(value: min(max(info.progress, 0), 1))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if info.state == .completed, let location = location {
                    Text(location)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if info.state == .failed, let message = info.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer(minLength: 0)
            actionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch info.state {
        case .queued, .connecting, .downloading:
            Button { manager.pause(info.id) } label: {
                Image(systemName: "pause.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
        case .paused:
            Button { manager.resume(info.id) } label: {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
        case .failed, .cancelled:
            Button { manager.retry(info.id) } label: {
                Image(systemName: "arrow.clockwise.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
        case .completed:
            if let url = manager.fileURL(for: info.id) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.title3)
                }
                .buttonStyle(.borderless)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Add download

struct AddDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var link: PS4LinkModel

    @State private var urlText = ""
    @State private var filename = ""
    @State private var parts = 4
    @State private var destination: TransferDestination = .phone
    @State private var parallelInstall = false
    @State private var sha256 = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Link") {
                    TextField("https://...", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from clipboard") {
                        if let text = UIPasteboard.general.string { urlText = text }
                    }
                    TextField("File name (optional)", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Options") {
                    Stepper("Parts: \(parts)", value: $parts, in: 1...8)
                    Picker("Destination", selection: $destination) {
                        ForEach(TransferDestination.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    if destination != .phone {
                        Toggle("Parallel PKG install", isOn: $parallelInstall)
                        if !link.isPaired {
                            Text("No PS4 is paired. Pair one in the Transfers tab first.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    TextField("SHA-256 (optional)", text: $sha256)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let errorText = errorText {
                    Section { Text(errorText).foregroundColor(.red) }
                }
            }
            .navigationTitle("Add Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                }
            }
            .onAppear { parts = settings.settings.downloadParts }
        }
    }

    private func add() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            errorText = L("Enter a valid http(s) link.")
            return
        }
        manager.addDownload(
            url: url,
            filename: filename,
            parts: parts,
            destination: destination,
            isParallelInstall: parallelInstall,
            sha256: sha256
        )
        dismiss()
    }
}

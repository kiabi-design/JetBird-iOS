//
//  FTPView.swift
//  JetBird
//
//  FTP file manager for the PS4 (browse, download, upload, rename, delete).
//

import SwiftUI
import UniformTypeIdentifiers

struct FTPView: View {
    @EnvironmentObject private var model: FTPModel

    var body: some View {
        NavigationStack {
            if model.isConnected {
                FTPBrowserView()
            } else {
                FTPConnectView()
            }
        }
    }
}

// MARK: - Connect

struct FTPConnectView: View {
    @EnvironmentObject private var model: FTPModel
    @EnvironmentObject private var link: PS4LinkModel

    var body: some View {
        Form {
            addressSection
            errorSection
            connectSection
        }
        .navigationTitle("FTP")
        .onAppear {
            if model.host.isEmpty { model.host = link.lastHost }
        }
    }

    private var addressSection: some View {
        Section {
            TextField("192.168.1.100", text: $model.host)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("2121", text: $model.port)
                .keyboardType(.numberPad)
            TextField("anonymous", text: $model.user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password (optional)", text: $model.password)
        } header: {
            Text("PS4 FTP server")
        } footer: {
            Text("Start the FTP server on the PS4 (for example in GoldHEN). Default port: 2121, no password.")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = model.message {
            Section {
                Text(message)
                    .foregroundColor(.red)
            }
        }
    }

    private var connectSection: some View {
        Section {
            Button(action: connect) {
                if model.state == .connecting {
                    HStack {
                        ProgressView()
                        Text("Connecting...")
                    }
                } else {
                    Text("Connect")
                }
            }
            .disabled(model.state == .connecting)
        }
    }

    private func connect() {
        Task { await model.connect() }
    }
}

// MARK: - Browser

struct FTPBrowserView: View {
    @EnvironmentObject private var model: FTPModel

    @State private var deleteTarget: FTPEntry?
    @State private var renameTarget: FTPEntry?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false

    var body: some View {
        fileList
            .navigationTitle("FTP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable { await model.refresh() }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType.item],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .alert("New folder", isPresented: $showNewFolder, actions: { newFolderActions })
            .alert("Rename", isPresented: renameBinding, actions: { renameActions })
            .confirmationDialog(
                "Delete?",
                isPresented: deleteBinding,
                titleVisibility: .visible,
                presenting: deleteTarget,
                actions: { entry in deleteActions(entry) },
                message: { entry in Text(entry.name) }
            )
    }

    // MARK: Pieces

    private var fileList: some View {
        List {
            pathSection
            errorSection
            entriesSection
            transfersSection
        }
    }

    private var pathSection: some View {
        Section {
            HStack(spacing: 12) {
                Button(action: { model.goUp() }) {
                    Image(systemName: "arrow.up.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(model.path == "/")

                Text(model.path)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 0)

                if model.isLoading {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = model.message {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
    }

    private var entriesSection: some View {
        Section {
            if model.entries.isEmpty && !model.isLoading {
                Text("This folder is empty")
                    .foregroundColor(.secondary)
            }
            ForEach(model.entries) { entry in
                row(for: entry)
            }
        } header: {
            Text("Files")
        }
    }

    @ViewBuilder
    private var transfersSection: some View {
        if !model.transfers.isEmpty {
            Section {
                ForEach(model.transfers) { transfer in
                    FTPTransferRow(transfer: transfer, onCancel: { model.cancelTransfer(transfer.id) })
                }
                Button("Clear finished", action: { model.clearFinishedTransfers() })
            } header: {
                Text("Transfers")
            }
        }
    }

    private func row(for entry: FTPEntry) -> some View {
        FTPEntryRow(entry: entry, onTap: { model.tap(entry) })
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    deleteTarget = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    renameText = entry.name
                    renameTarget = entry
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .leading) {
                Button {
                    model.download(entry)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Disconnect", action: { model.disconnect() })
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button("Upload files", action: { showImporter = true })
                Button("New folder", action: {
                    newFolderName = ""
                    showNewFolder = true
                })
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    // MARK: Dialogs

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    @ViewBuilder
    private var newFolderActions: some View {
        TextField("Folder name", text: $newFolderName)
        Button("Create", action: { model.makeFolder(named: newFolderName) })
        Button("Cancel", role: .cancel, action: {})
    }

    @ViewBuilder
    private var renameActions: some View {
        TextField("New name", text: $renameText)
        Button("Rename", action: confirmRename)
        Button("Cancel", role: .cancel, action: {})
    }

    @ViewBuilder
    private func deleteActions(_ entry: FTPEntry) -> some View {
        Button("Delete", role: .destructive, action: { model.delete(entry) })
        Button("Cancel", role: .cancel, action: {})
    }

    private func confirmRename() {
        if let entry = renameTarget {
            model.rename(entry, to: renameText)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            model.upload(urls)
        case .failure(let error):
            model.message = error.localizedDescription
        }
    }
}

// MARK: - Rows

struct FTPEntryRow: View {
    let entry: FTPEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundColor(entry.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        var parts: [String] = []
        if !entry.isDirectory, let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if !entry.modified.isEmpty {
            parts.append(entry.modified)
        }
        return parts.joined(separator: " · ")
    }
}

struct FTPTransferRow: View {
    let transfer: FTPTransfer
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name)
                    .lineLimit(1)
                if transfer.status == .running && transfer.total > 0 {
                    ProgressView(value: fraction)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            Spacer(minLength: 0)
            if transfer.status == .running {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var fraction: Double {
        guard transfer.total > 0 else { return 0 }
        return min(max(Double(transfer.bytes) / Double(transfer.total), 0), 1)
    }

    private var statusColor: Color {
        if case .failed = transfer.status { return Color.red }
        return Color.secondary
    }

    private var statusText: String {
        switch transfer.status {
        case .running:
            let done = ByteCountFormatter.string(fromByteCount: transfer.bytes, countStyle: .file)
            if transfer.total > 0 {
                let total = ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file)
                return L("%@ of %@", done, total)
            }
            return done
        case .done:
            return L("Completed")
        case .failed(let message):
            return message
        case .cancelled:
            return L("Cancelled")
        }
    }
}

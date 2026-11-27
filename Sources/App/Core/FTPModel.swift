//
//  FTPModel.swift
//  JetBird
//
//  State of the FTP tab: one "browser" connection for listing and file operations,
//  and a separate connection for every upload/download so browsing keeps working.
//

import Foundation

struct FTPTransfer: Identifiable {
    enum Status: Equatable {
        case running
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let name: String
    let isUpload: Bool
    var bytes: Int64 = 0
    var total: Int64 = 0
    var status: Status = .running
}

private struct FTPListing: Sendable {
    let path: String
    let entries: [FTPEntry]
}

@MainActor
final class FTPModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private static let hostKey = "jetbird.ftp.host"
    private static let portKey = "jetbird.ftp.port"
    private static let userKey = "jetbird.ftp.user"

    @Published var host: String
    @Published var port: String
    @Published var user: String
    @Published var password = ""

    @Published private(set) var state: State = .disconnected
    @Published private(set) var path = "/"
    @Published private(set) var entries: [FTPEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var transfers: [FTPTransfer] = []
    @Published var message: String?

    private var browser: FTPClient?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: Self.hostKey) ?? ""
        port = defaults.string(forKey: Self.portKey) ?? "2121"
        user = defaults.string(forKey: Self.userKey) ?? "anonymous"
    }

    var isConnected: Bool { state == .connected }

    // MARK: Connection

    private func makeClient() async throws -> FTPClient {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portNumber = UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 2121
        let login = user.trimmingCharacters(in: .whitespaces)
        let client = FTPClient(host: cleanHost, port: portNumber)
        do {
            try await client.connect(
                user: login.isEmpty ? "anonymous" : login,
                password: password.isEmpty ? "anonymous@" : password
            )
        } catch {
            await client.quit()
            throw error
        }
        return client
    }

    func connect() async {
        guard state != .connecting else { return }
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            message = L("Enter the PS4 IP address.")
            return
        }
        guard let portNumber = UInt16(port.trimmingCharacters(in: .whitespaces)), portNumber > 0 else {
            message = L("Enter a valid port.")
            return
        }

        message = nil
        state = .connecting
        let defaults = UserDefaults.standard
        defaults.set(cleanHost, forKey: Self.hostKey)
        defaults.set(String(portNumber), forKey: Self.portKey)
        defaults.set(user, forKey: Self.userKey)

        do {
            let client = try await makeClient()
            browser = client
            let start = (try? await client.pwd()) ?? "/"
            state = .connected
            await load(start)
        } catch {
            state = .disconnected
            message = error.localizedDescription
        }
    }

    func disconnect() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        let client = browser
        browser = nil
        Task { await client?.quit() }
        state = .disconnected
        entries = []
        path = "/"
        message = nil
    }

    /// Runs an operation on the browser connection; reconnects once if the connection was dropped.
    private func withBrowser<T: Sendable>(_ operation: @escaping @Sendable (FTPClient) async throws -> T) async throws -> T {
        if let client = browser, !client.isClosed {
            do {
                return try await operation(client)
            } catch {
                if !client.isClosed { throw error }
            }
        }
        let fresh = try await makeClient()
        browser = fresh
        return try await operation(fresh)
    }

    // MARK: Browsing

    func load(_ target: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await withBrowser { (client: FTPClient) -> FTPListing in
                try await client.cwd(target)
                let current = (try? await client.pwd()) ?? target
                let items = try await client.list()
                return FTPListing(path: current, entries: items)
            }
            path = listing.path
            entries = listing.entries.sorted { first, second in
                if first.isDirectory != second.isDirectory { return first.isDirectory }
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func refresh() async {
        await load(path)
    }

    func goUp() {
        let target = FTPPath.parent(path)
        Task { await load(target) }
    }

    func tap(_ entry: FTPEntry) {
        if entry.isDirectory {
            let target = FTPPath.join(path, entry.name)
            Task { await load(target) }
        } else {
            download(entry)
        }
    }

    // MARK: File operations

    private func validName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.contains("/") { return nil }
        return name
    }

    func makeFolder(named value: String) {
        guard let name = validName(value) else {
            message = L("Enter a valid name.")
            return
        }
        let full = FTPPath.join(path, name)
        Task {
            do {
                try await withBrowser { (client: FTPClient) -> Bool in
                    try await client.makeDirectory(full)
                    return true
                }
                await refresh()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func rename(_ entry: FTPEntry, to value: String) {
        guard let name = validName(value) else {
            message = L("Enter a valid name.")
            return
        }
        let from = FTPPath.join(path, entry.name)
        let to = FTPPath.join(path, name)
        Task {
            do {
                try await withBrowser { (client: FTPClient) -> Bool in
                    try await client.rename(from: from, to: to)
                    return true
                }
                await refresh()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func delete(_ entry: FTPEntry) {
        let full = FTPPath.join(path, entry.name)
        let isDirectory = entry.isDirectory
        Task {
            do {
                try await withBrowser { (client: FTPClient) -> Bool in
                    if isDirectory {
                        try await client.deleteRecursively(full)
                    } else {
                        try await client.delete(full)
                    }
                    return true
                }
                await load(path)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: Transfers

    private func addTransfer(name: String, upload: Bool, total: Int64) -> UUID {
        var transfer = FTPTransfer(name: name, isUpload: upload)
        transfer.total = total
        transfers.insert(transfer, at: 0)
        return transfer.id
    }

    private func updateTransfer(_ id: UUID, _ change: (inout FTPTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func finishTransfer(_ id: UUID, status: FTPTransfer.Status) {
        updateTransfer(id) { $0.status = status }
        tasks[id] = nil
    }

    private func progressHandler(for id: UUID) -> @Sendable (Int64) -> Void {
        return { [weak self] done in
            Task { @MainActor in
                self?.updateTransfer(id) { $0.bytes = done }
            }
        }
    }

    func cancelTransfer(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.status != .running }
    }

    private static func localFolder() -> URL {
        let folder = DownloadFolderStore.shared.folderURL
            ?? DownloadFolderStore.defaultRoot.appendingPathComponent("FTP", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension

        var candidate = folder.appendingPathComponent(safe)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    func download(_ entry: FTPEntry) {
        let remote = FTPPath.join(path, entry.name)
        let name = entry.name
        let isDirectory = entry.isDirectory
        let id = addTransfer(name: name, upload: false, total: entry.size ?? 0)
        let destination = Self.uniqueURL(in: Self.localFolder(), name: name)
        let progress = progressHandler(for: id)

        tasks[id] = Task {
            do {
                let client = try await self.makeClient()
                do {
                    if isDirectory {
                        try await client.downloadDirectory(remote: remote, to: destination, counter: FTPByteCounter(), progress: progress)
                    } else {
                        try await client.download(remote: remote, to: destination, progress: progress)
                    }
                } catch {
                    await client.quit()
                    throw error
                }
                await client.quit()
                self.finishTransfer(id, status: .done)
            } catch is CancellationError {
                self.finishTransfer(id, status: .cancelled)
            } catch {
                self.finishTransfer(id, status: .failed(error.localizedDescription))
            }
        }
    }

    func upload(_ urls: [URL]) {
        let targetFolder = path
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            let remote = FTPPath.join(targetFolder, name)
            let id = addTransfer(name: name, upload: true, total: size)
            let progress = progressHandler(for: id)

            tasks[id] = Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let client = try await self.makeClient()
                    do {
                        try await client.upload(local: url, remote: remote, progress: progress)
                    } catch {
                        await client.quit()
                        throw error
                    }
                    await client.quit()
                    self.finishTransfer(id, status: .done)
                    if self.path == targetFolder { await self.refresh() }
                } catch is CancellationError {
                    self.finishTransfer(id, status: .cancelled)
                } catch {
                    self.finishTransfer(id, status: .failed(error.localizedDescription))
                }
            }
        }
    }
}

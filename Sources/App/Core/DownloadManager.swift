//
//  DownloadManager.swift
//  JetBird
//
//  Multi-part (HTTP Range) download manager with pause/resume, a concurrency
//  limit, optional SHA-256 verification and hand-off to a paired PS4.
//  Downloads continue for a short time after the app is backgrounded
//  (UIApplication background task); they are not durable across app termination.
//

import Foundation
import CryptoKit
import UIKit

// MARK: - URLSession delegate (runs off the main actor)

final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Target {
        let id: UUID
        let part: Int
        let destination: URL
        let expectPartialContent: Bool
    }

    private let lock = NSLock()
    private var targets: [Int: Target] = [:]
    private var fileErrors: [Int: Error] = [:]

    var onProgress: (@Sendable (UUID, Int, Int64) -> Void)?
    var onPartFinished: (@Sendable (UUID, Int, Error?) -> Void)?

    func register(_ task: URLSessionTask, target: Target) {
        lock.lock()
        targets[task.taskIdentifier] = target
        lock.unlock()
    }

    private func target(for task: URLSessionTask) -> Target? {
        lock.lock(); defer { lock.unlock() }
        return targets[task.taskIdentifier]
    }

    private func recordError(_ error: Error, for task: URLSessionTask) {
        lock.lock()
        fileErrors[task.taskIdentifier] = error
        lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let target = target(for: downloadTask) else { return }
        onProgress?(target.id, target.part, totalBytesWritten)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let target = target(for: downloadTask) else { return }

        if let http = downloadTask.response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                recordError(JetBirdError.downloadFailed("HTTP \(http.statusCode)"), for: downloadTask)
                return
            }
            if target.expectPartialContent && http.statusCode != 206 {
                recordError(JetBirdError.downloadFailed(L("Server ignored the Range request")), for: downloadTask)
                return
            }
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target.destination)
            try fm.moveItem(at: location, to: target.destination)
        } catch {
            recordError(error, for: downloadTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let target = targets.removeValue(forKey: task.taskIdentifier)
        let fileError = fileErrors.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let target = target else { return }
        onPartFinished?(target.id, target.part, error ?? fileError)
    }
}

// MARK: - Manager

@MainActor
public final class DownloadManager: ObservableObject {
    public static let shared = DownloadManager()

    @Published public private(set) var downloads: [DownloadInfo] = []
    /// Current speed in bytes/second per download
    @Published public private(set) var speeds: [UUID: Int64] = [:]

    public var maxConcurrent = 3
    public var minPartSize: Int64 = 1024 * 1024
    /// Set by the pairing flow; used for PS4 / Phone+PS4 destinations
    var ps4Client: PS4Client?
    private var explicitNames: Set<UUID> = []

    private let delegate: DownloadSessionDelegate
    private let session: URLSession
    private let storeURL: URL

    private var requestHeaders: [UUID: [String: String]] = [:]
    private var partStates: [UUID: [DownloadPart]] = [:]
    private var tasks: [UUID: [Int: URLSessionDownloadTask]] = [:]
    private var resumeBlobs: [UUID: [Int: Data]] = [:]
    private var samples: [UUID: (time: Date, bytes: Int64)] = [:]
    private var running: Set<UUID> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let sessionDelegate = DownloadSessionDelegate()
        delegate = sessionDelegate
        session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("downloads.json")

        delegate.onProgress = { [weak self] id, part, bytes in
            Task { @MainActor in self?.handleProgress(id, part: part, bytes: bytes) }
        }
        delegate.onPartFinished = { [weak self] id, part, error in
            Task { @MainActor in self?.handlePartFinished(id, part: part, error: error) }
        }
        load()
    }

    // MARK: Public API

    @discardableResult
    public func addDownload(
        url: URL,
        filename: String? = nil,
        headers: [String: String] = [:],
        parts: Int = 4,
        destination: TransferDestination = .phone,
        isParallelInstall: Bool = false,
        sha256: String? = nil
    ) -> DownloadInfo {
        var name = (filename ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = url.lastPathComponent }
        if name.isEmpty || name == "/" { name = "download" }
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")

        let hash = (sha256 ?? "").trimmingCharacters(in: .whitespaces)
        let info = DownloadInfo(
            url: url,
            filename: name,
            parts: min(max(parts, 1), 8),
            category: FileCategory.from(mimeType: nil, filename: name),
            destination: destination,
            sha256Hash: hash.isEmpty ? nil : hash,
            isParallelInstall: isParallelInstall
        )
        downloads.append(info)
        if !(filename ?? "").trimmingCharacters(in: .whitespaces).isEmpty { explicitNames.insert(info.id) }
        requestHeaders[info.id] = headers
        save()
        pump()
        return info
    }

    public func pause(_ id: UUID) {
        guard let info = lookup(id), info.state.isActive || info.state == .queued else { return }
        update(id) { $0.state = .paused }
        for (index, task) in tasks[id] ?? [:] {
            task.cancel(byProducingResumeData: { [weak self] data in
                guard let data = data else { return }
                Task { @MainActor in self?.resumeBlobs[id, default: [:]][index] = data }
            })
        }
        tasks[id] = nil
        speeds[id] = nil
        finishRunning(id)
    }

    public func resume(_ id: UUID) {
        guard let info = lookup(id), info.state == .paused else { return }
        update(id) { $0.state = .queued; $0.errorMessage = nil }
        pump()
    }

    public func retry(_ id: UUID) {
        guard let info = lookup(id), info.state == .failed || info.state == .cancelled else { return }
        cleanupParts(id)
        partStates[id] = nil
        update(id) { $0.state = .queued; $0.errorMessage = nil; $0.downloadedSize = 0 }
        pump()
    }

    public func remove(_ id: UUID, deleteFile: Bool = false) {
        for task in (tasks[id] ?? [:]).values { task.cancel() }
        tasks[id] = nil
        cleanupParts(id)
        if deleteFile, let url = fileURL(for: id) { try? FileManager.default.removeItem(at: url) }
        downloads.removeAll { $0.id == id }
        partStates[id] = nil
        requestHeaders[id] = nil
        speeds[id] = nil
        finishRunning(id)
        save()
    }

    public func clearFinished() {
        for info in downloads where info.state.isTerminal { remove(info.id) }
    }

    public func fileURL(for id: UUID) -> URL? {
        guard let path = lookup(id)?.localRelativePath else { return nil }
        let url: URL
        if path.hasPrefix(Self.customPrefix) {
            guard let folder = DownloadFolderStore.shared.folderURL else { return nil }
            url = folder.appendingPathComponent(String(path.dropFirst(Self.customPrefix.count)))
        } else {
            url = Self.documentsURL.appendingPathComponent(path)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Human-readable location of a finished download.
    public func locationDescription(for id: UUID) -> String? {
        guard let info = lookup(id) else { return nil }
        if info.state == .completed && info.destination == .ps4 {
            return L("Sent to PS4. The console downloads the file itself.")
        }
        guard let path = info.localRelativePath else { return nil }
        if path.hasPrefix(Self.customPrefix) {
            return L("Folder: %@", DownloadFolderStore.shared.folderName ?? L("Chosen folder"))
        }
        return L("Files > On My iPhone > JetBird > %@", info.category.rawValue)
    }

    // MARK: Queue

    private func pump() {
        while running.count < maxConcurrent,
              let next = downloads.first(where: { $0.state == .queued && !running.contains($0.id) }) {
            running.insert(next.id)
            let id = next.id
            Task { await self.run(id) }
        }
    }

    private func finishRunning(_ id: UUID) {
        running.remove(id)
        pump()
        if running.isEmpty { endBackgroundTask() }
    }

    // MARK: Running a download

    private func run(_ id: UUID) async {
        guard let info = lookup(id), info.state == .queued else { finishRunning(id); return }
        beginBackgroundTask()
        update(id) { $0.state = .connecting }

        // Direct PS4 Download: the console fetches the HTTPS link itself
        if info.destination == .ps4 || info.destination == .both {
            do {
                try await handoffToPS4(info)
                if info.destination == .ps4 {
                    update(id) { $0.state = .completed }
                    save()
                    finishRunning(id)
                    return
                }
            } catch {
                if info.destination == .ps4 {
                    fail(id, error)
                    return
                }
                // Phone + PS4: keep going with the phone download
            }
            guard self.lookup(id)?.state == .connecting else { finishRunning(id); return }
        }

        // Resume of an existing download: restart incomplete parts only
        if let existing = partStates[id], !existing.isEmpty {
            update(id) { $0.state = .downloading }
            for index in existing.indices where existing[index].state != .completed {
                partStates[id]?[index].state = .downloading
                startPart(id, index)
            }
            return
        }

        // Probe the server
        var supportsRange = false
        var total: Int64 = -1
        var mime: String?
        do {
            var request = URLRequest(url: info.url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 20
            for (key, value) in requestHeaders[id] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                supportsRange = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased() == "bytes"
                total = http.expectedContentLength > 0 ? http.expectedContentLength : -1
                mime = http.mimeType
            }
        } catch {
            // Some servers reject HEAD; fall back to a single GET
        }

        guard let current = self.lookup(id), current.state == .connecting else { finishRunning(id); return }

        var count = 1
        if supportsRange && total > minPartSize * 2 {
            count = max(1, min(current.parts, Int(total / minPartSize)))
        }
        partStates[id] = makeParts(total: total, count: count)
        update(id) {
            if total > 0 { $0.totalSize = total }
            $0.mimeType = mime
            if $0.category == .other { $0.category = FileCategory.from(mimeType: mime, filename: $0.filename) }
            $0.state = .downloading
        }
        samples[id] = (Date(), 0)
        for index in 0..<count { startPart(id, index) }
    }

    private func makeParts(total: Int64, count: Int) -> [DownloadPart] {
        guard count > 1, total > 0 else {
            return [DownloadPart(index: 0, startByte: 0, endByte: max(total - 1, -1), downloadedBytes: 0, state: .downloading)]
        }
        let size = total / Int64(count)
        return (0..<count).map { i in
            let start = Int64(i) * size
            let end = i == count - 1 ? total - 1 : start + size - 1
            return DownloadPart(index: i, startByte: start, endByte: end, downloadedBytes: 0, state: .downloading)
        }
    }

    private func startPart(_ id: UUID, _ index: Int) {
        guard let info = lookup(id), let parts = partStates[id], parts.indices.contains(index) else { return }
        let ranged = parts.count > 1
        let part = parts[index]

        let task: URLSessionDownloadTask
        if let blob = resumeBlobs[id]?[index] {
            resumeBlobs[id]?[index] = nil
            task = session.downloadTask(withResumeData: blob)
        } else {
            var request = URLRequest(url: info.url)
            for (key, value) in requestHeaders[id] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            if ranged { request.setValue("bytes=\(part.startByte)-\(part.endByte)", forHTTPHeaderField: "Range") }
            task = session.downloadTask(with: request)
            partStates[id]?[index].downloadedBytes = 0
        }

        delegate.register(task, target: DownloadSessionDelegate.Target(
            id: id, part: index, destination: partFile(id, index), expectPartialContent: ranged))
        tasks[id, default: [:]][index] = task
        task.resume()
    }

    // MARK: PS4 hand-off

    private func handoffToPS4(_ info: DownloadInfo) async throws {
        guard let client = ps4Client else {
            throw PS4Error(L("Pair with this PS4 in the Transfers tab, then retry."))
        }
        guard info.url.scheme?.lowercased() == "https", info.url.host != nil else {
            throw PS4Error(L("PS4 Direct Download needs an HTTPS link."))
        }

        let extra = requestHeaders[info.id] ?? [:]
        var resolved = info.url
        var size: Int64 = -1
        var suggested: String?
        do {
            var request = URLRequest(url: info.url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 20
            for (key, value) in extra { request.setValue(value, forHTTPHeaderField: key) }
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                resolved = http.url ?? info.url
                if http.expectedContentLength > 0 { size = http.expectedContentLength }
                suggested = http.suggestedFilename
            }
        } catch {
            // Some servers reject HEAD; the console will still try the original link
        }

        var name = Self.cleanFilename(explicitNames.contains(info.id) ? info.filename : (suggested ?? info.filename))
        if name.isEmpty { name = "download" }
        if info.isParallelInstall, !name.lowercased().hasSuffix(".pkg") {
            name = name.utf8.count <= 196 ? name + ".pkg" : "download.pkg"
        }

        let fields = [resolved.absoluteString, extra["User-Agent"] ?? "", extra["Referer"] ?? "", extra["Cookie"] ?? ""]
        let invalid = fields.contains { field in
            field.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }
        guard !invalid else { throw PS4Error(L("The browser supplied an invalid request header.")) }
        let request = Data((fields.joined(separator: "\u{0}") + "\u{0}").utf8)
        guard request.count <= PS4Wire.maxRequestSize else {
            throw PS4Error(L("The browser link and headers exceed the PS4 receiver limit."))
        }

        update(info.id) {
            $0.filename = name
            if size > 0 { $0.totalSize = size }
        }
        try await client.handoff(name: name, size: size, request: request, install: info.isParallelInstall)
    }

    nonisolated private static func cleanFilename(_ value: String) -> String {
        var leaf = value.components(separatedBy: "/").last ?? value
        leaf = leaf.components(separatedBy: "\\").last ?? leaf
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|\u{FFFD}"))
        let scalars = leaf.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !invalid.contains($0) }
        var cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.utf8.count <= 200 { return cleaned }

        // Too long: shorten the base name, keep a short extension
        let ext = (cleaned as NSString).pathExtension
        let suffix = (!ext.isEmpty && ext.utf8.count <= 16) ? "." + ext : ""
        let base = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
        var shortened = ""
        var budget = 200 - suffix.utf8.count
        for character in base {
            let size = String(character).utf8.count
            if budget - size < 0 { break }
            shortened.append(character)
            budget -= size
        }
        return shortened.trimmingCharacters(in: .whitespaces) + suffix
    }

    // MARK: Delegate callbacks

    private func handleProgress(_ id: UUID, part: Int, bytes: Int64) {
        guard partStates[id]?.indices.contains(part) == true else { return }
        partStates[id]?[part].downloadedBytes = bytes
        let total = partStates[id]?.reduce(Int64(0)) { $0 + $1.downloadedBytes } ?? 0
        update(id) { $0.downloadedSize = total }

        let now = Date()
        if let sample = samples[id] {
            let elapsed = now.timeIntervalSince(sample.time)
            if elapsed >= 1 {
                speeds[id] = max(0, Int64(Double(total - sample.bytes) / elapsed))
                samples[id] = (now, total)
            }
        } else {
            samples[id] = (now, total)
        }
    }

    private func handlePartFinished(_ id: UUID, part: Int, error: Error?) {
        tasks[id]?[part] = nil
        guard let info = lookup(id), info.state == .downloading else { return }

        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            fail(id, error)
            return
        }

        partStates[id]?[part].state = .completed
        if let parts = partStates[id], parts.allSatisfy({ $0.state == .completed }) {
            Task { await self.finalize(id) }
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        for task in (tasks[id] ?? [:]).values { task.cancel() }
        tasks[id] = nil
        speeds[id] = nil
        update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
        save()
        finishRunning(id)
    }

    // MARK: Finishing

    private func finalize(_ id: UUID) async {
        guard let info = lookup(id), info.state == .downloading else { return }
        update(id) { $0.state = .verifying }

        let count = partStates[id]?.count ?? 0
        let partURLs = (0..<count).map { partFile(id, $0) }
        let customFolder = DownloadFolderStore.shared.folderURL
        let destination = uniqueDestination(for: info, customFolder: customFolder)
        let expected = info.sha256Hash

        do {
            try await Task.detached(priority: .utility) {
                try DownloadManager.merge(parts: partURLs, into: destination, expectedSHA256: expected)
            }.value

            let relative: String
            if customFolder != nil {
                relative = Self.customPrefix + destination.lastPathComponent
            } else {
                relative = destination.path.replacingOccurrences(of: Self.documentsURL.path + "/", with: "")
            }
            update(id) {
                $0.state = .completed
                $0.downloadedSize = $0.totalSize > 0 ? $0.totalSize : $0.downloadedSize
                $0.localRelativePath = relative
                $0.filename = destination.lastPathComponent
            }
            speeds[id] = nil
            partStates[id] = nil
            tasks[id] = nil
            cleanupParts(id)
            save()
            finishRunning(id)
        } catch {
            fail(id, error)
        }
    }

    nonisolated private static func merge(parts: [URL], into destination: URL, expectedSHA256: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if parts.count == 1 {
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: parts[0], to: destination)
            } catch {
                try fm.copyItem(at: parts[0], to: destination)
                try? fm.removeItem(at: parts[0])
            }
        } else {
            fm.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            for part in parts {
                let input = try FileHandle(forReadingFrom: part)
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                try? input.close()
                try? fm.removeItem(at: part)
            }
        }

        if let expected = expectedSHA256, !expected.isEmpty {
            let actual = try sha256Hex(of: destination)
            if actual.lowercased() != expected.lowercased() {
                try? fm.removeItem(at: destination)
                throw JetBirdError.fileCorrupted
            }
        }
    }

    nonisolated private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Files

    private static let customPrefix = "@custom/"

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func partDirectory(_ id: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("JetBirdParts/\(id.uuidString)", isDirectory: true)
    }

    private func partFile(_ id: UUID, _ index: Int) -> URL {
        partDirectory(id).appendingPathComponent("part\(index).tmp")
    }

    private func cleanupParts(_ id: UUID) {
        try? FileManager.default.removeItem(at: partDirectory(id))
    }

    private func uniqueDestination(for info: DownloadInfo, customFolder: URL?) -> URL {
        let directory = customFolder
            ?? DownloadFolderStore.defaultRoot.appendingPathComponent(info.category.rawValue, isDirectory: true)
        let base = (info.filename as NSString).deletingPathExtension
        let ext = (info.filename as NSString).pathExtension

        var candidate = directory.appendingPathComponent(info.filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: State helpers

    private func lookup(_ id: UUID) -> DownloadInfo? {
        downloads.first { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout DownloadInfo) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[index])
        downloads[index].updatedAt = Date()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(downloads) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              var saved = try? JSONDecoder().decode([DownloadInfo].self, from: data) else { return }
        for index in saved.indices where !saved[index].state.isTerminal {
            saved[index].state = .failed
            saved[index].errorMessage = L("Interrupted (app was closed)")
        }
        downloads = saved
    }

    // MARK: Background time

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "JetBirdDownloads") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

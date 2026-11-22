//
//  DownloadManager.swift
//  JetBirdCore
//
//  Multi-part download manager with background support
//  Ported from Android TransferWorker/TransferService logic
//

import Foundation
import Network
import UniformTypeIdentifiers
import BackgroundTasks

// MARK: - Download Manager

/// Main download manager handling multi-part downloads, queuing, and background execution
public actor DownloadManager {
    public static let shared = DownloadManager()

    // Configuration
    public var maxConcurrentDownloads: Int = 3
    public var defaultParts: Int = 4
    public var maxParts: Int = 8
    public var minPartSize: Int64 = 1024 * 1024 // 1 MB minimum per part

    // State
    private var downloads: [UUID: DownloadTask] = [:]
    private var activeCount: Int = 0
    private var queue: [UUID] = []
    private let fileManager = FileManager.default
    private let session: URLSession
    private let backgroundSession: URLSession

    // Callbacks
    public var onProgress: ((UUID, Double, Int64, String?) -> Void)? // id, progress, speed, eta
    public var onStateChange: ((UUID, DownloadState) -> Void)?
    public var onCompletion: ((UUID, Result<URL, Error>) -> Void)?

    private init() {
        // Foreground session
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = maxParts
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)

        // Background session
        let bgConfig = URLSessionConfiguration.background(withIdentifier: "com.jetbird.background")
        bgConfig.httpMaximumConnectionsPerHost = maxParts
        bgConfig.isDiscretionary = true
        bgConfig.sessionSendsLaunchEvents = true
        self.backgroundSession = URLSession(configuration: bgConfig, delegate: nil, delegateQueue: nil)

        // Register background task
        registerBackgroundTask()
    }

    // MARK: - Public API

    /// Add a new download
    public func addDownload(
        url: URL,
        filename: String? = nil,
        headers: [String: String] = [:],
        parts: Int? = nil,
        destination: TransferDestination = .phone,
        category: FileCategory? = nil,
        isParallelInstall: Bool = false,
        resumeData: Data? = nil
    ) async -> DownloadInfo {
        let finalFilename = filename ?? url.lastPathComponent
        let finalCategory = category ?? FileCategory.from(mimeType: nil, filename: finalFilename)
        let finalParts = min(max(parts ?? defaultParts, 1), maxParts)

        let info = DownloadInfo(
            url: url,
            filename: finalFilename,
            parts: finalParts,
            category: finalCategory,
            destination: destination,
            resumeData: resumeData,
            isParallelInstall: isParallelInstall
        )

        let task = DownloadTask(info: info, headers: headers, manager: self)
        downloads[info.id] = task
        queue.append(info.id)

        await processQueue()

        return info
    }

    /// Pause a download
    public func pauseDownload(_ id: UUID) async {
        guard let task = downloads[id] else { return }
        await task.pause()
        if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
        }
    }

    /// Resume a paused download
    public func resumeDownload(_ id: UUID) async {
        guard let task = downloads[id] else { return }
        if task.info.state == .paused {
            queue.insert(id, at: 0)
            await processQueue()
        }
    }

    /// Cancel a download
    public func cancelDownload(_ id: UUID) async {
        guard let task = downloads[id] else { return }
        await task.cancel()
        downloads.removeValue(forKey: id)
        queue.removeAll { $0 == id }
    }

    /// Remove completed/failed download from history
    public func removeDownload(_ id: UUID) async {
        downloads.removeValue(forKey: id)
        queue.removeAll { $0 == id }
    }

    /// Get download info
    public func getDownload(_ id: UUID) -> DownloadInfo? {
        downloads[id]?.info
    }

    /// Get all downloads
    public func getAllDownloads() -> [DownloadInfo] {
        downloads.values.map { $0.info }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Get active downloads
    public func getActiveDownloads() -> [DownloadInfo] {
        downloads.values
            .filter { $0.info.state.isActive }
            .map { $0.info }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Clear completed downloads
    public func clearCompleted() async {
        let completed = downloads.filter { $0.value.info.state.isTerminal }
        for (id, _) in completed {
            downloads.removeValue(forKey: id)
        }
    }

    /// Set maximum concurrent downloads
    public func setMaxConcurrent(_ count: Int) async {
        maxConcurrentDownloads = max(1, count)
        await processQueue()
    }

    // MARK: - Queue Processing

    private func processQueue() async {
        while activeCount < maxConcurrentDownloads,
              let nextId = queue.first,
              let task = downloads[nextId],
              task.info.state == .queued {
            queue.removeFirst()
            activeCount += 1
            Task {
                await task.start()
                activeCount -= 1
                await processQueue()
            }
        }
    }

    // MARK: - Background Task

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.jetbird.background-download", using: nil) { task in
            self.handleBackgroundTask(task as! BGProcessingTask)
        }
    }

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        task.expirationHandler = {
            // Cancel all background downloads
            Task { await self.cancelAllBackgroundDownloads() }
        }

        // Schedule next background task
        scheduleBackgroundTask()

        // Continue active downloads in background
        // This is handled automatically by URLSession background configuration

        task.setTaskCompleted(success: true)
    }

    private func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: "com.jetbird.background-download")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule background task: \(error)")
        }
    }

    private func cancelAllBackgroundDownloads() async {
        for (_, task) in downloads where task.info.state.isActive {
            await task.cancel()
        }
    }

    // MARK: - File Management

    /// Get download directory for category
    public func downloadDirectory(for category: FileCategory, customFolder: URL?) -> URL {
        if let custom = customFolder {
            return custom.appendingPathComponent(category.rawValue, isDirectory: true)
        }

        let baseURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("JetBird/\(category.rawValue)", isDirectory: true)
    }

    /// Ensure directory exists
    public func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Download Task

/// Individual download task with multi-part support
actor DownloadTask {
    let info: DownloadInfo
    let headers: [String: String]
    weak var manager: DownloadManager?

    private var parts: [DownloadPart] = []
    private var partTasks: [Int: URLSessionDownloadTask] = [:]
    private var startTime: Date?
    private var lastProgressTime: Date?
    private var lastDownloadedBytes: Int64 = 0
    private var isCancelled = false
    private var isPaused = false
    private var resumeDataMap: [Int: Data] = [:]

    init(info: DownloadInfo, headers: [String: String], manager: DownloadManager) {
        self.info = info
        self.headers = headers
        self.manager = manager
    }

    var currentInfo: DownloadInfo {
        var updated = info
        updated.downloadedSize = parts.reduce(0) { $0 + $1.downloadedBytes }
        updated.state = computeState()
        updated.updatedAt = Date()
        return updated
    }

    func start() async {
        guard !isCancelled else { return }

        // Update state to connecting
        await updateState(.connecting)

        do {
            // HEAD request to get file info
            let (_, response) = try await headRequest()

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw JetBirdError.downloadFailed("HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0 )")
            }

            // Check if server supports range requests
            let supportsRange = httpResponse.allHeaderFields["Accept-Ranges"] as? String == "bytes"
            let totalSize = httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : -1

            // Update total size if not known
            var updatedInfo = info
            if totalSize > 0 {
                updatedInfo.totalSize = totalSize
            }
            updatedInfo.mimeType = httpResponse.mimeType

            // Create parts
            if supportsRange && totalSize > 0 && info.parts > 1 {
                parts = createParts(totalSize: totalSize, partCount: info.parts)
            } else {
                // Single part fallback
                parts = [DownloadPart(
                    index: 0,
                    startByte: 0,
                    endByte: totalSize - 1,
                    downloadedBytes: 0,
                    state: .queued
                )]
            }

            // Create download directory
            let downloadDir = await manager?.downloadDirectory(for: info.category, customFolder: nil) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            try await manager?.ensureDirectory(downloadDir)

            // Start downloading parts
            await updateState(.downloading)
            startTime = Date()
            lastProgressTime = Date()

            await downloadParts()

        } catch {
            await updateState(.failed)
            await manager?.onCompletion?(info.id, .failure(error))
        }
    }

    private func headRequest() async throws -> (Data, URLResponse) {
        var request = URLRequest(url: info.url)
        request.httpMethod = "HEAD"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = URLSession.shared
        return try await session.data(for: request)
    }

    private func createParts(totalSize: Int64, partCount: Int) -> [DownloadPart] {
        let partSize = totalSize / Int64(partCount)
        var parts: [DownloadPart] = []

        for i in 0..<partCount {
            let start = Int64(i) * partSize
            let end = i == partCount - 1 ? totalSize - 1 : start + partSize - 1
            parts.append(DownloadPart(
                index: i,
                startByte: start,
                endByte: end,
                downloadedBytes: 0,
                state: .queued
            ))
        }

        return parts
    }

    private func downloadParts() async {
        await withTaskGroup(of: Void.self) { group in
            for (index, part) in parts.enumerated() {
                group.addTask { await self.downloadPart(index: index) }
            }

            // Progress reporting
            group.addTask { await self.reportProgress() }
        }

        // All parts completed
        if !isCancelled && !isPaused {
            await verifyAndComplete()
        }
    }

    private func downloadPart(index: Int) async {
        var part = parts[index]
        guard part.state != .completed else { return }

        part.state = .downloading
        parts[index] = part

        var request = URLRequest(url: info.url)
        request.httpMethod = "GET"

        // Range header
        let rangeStart = part.startByte + part.downloadedBytes
        if rangeStart <= part.endByte {
            request.setValue("bytes=\(rangeStart)-\(part.endByte)", forHTTPHeaderField: "Range")
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let session = info.destination == .phone ? URLSession.shared : URLSession.shared
            // For background, use background session when app is backgrounded

            let (asyncBytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
                throw JetBirdError.downloadFailed("HTTP \(httpResponse.statusCode)")
            }

            // Write to file
            let downloadDir = await manager?.downloadDirectory(for: info.category, customFolder: nil) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let partFile = downloadDir.appendingPathComponent("\(info.id)_part\(index).tmp")

            let fileHandle = try FileHandle(forWritingTo: partFile)
            try fileHandle.seekToEnd()

            for try await byte in asyncBytes {
                if isCancelled || isPaused {
                    // Save resume data
                    resumeDataMap[index] = try await saveResumeData(for: request)
                    break
                }

                try fileHandle.write(contentsOf: [byte])
                part.downloadedBytes += 1
                parts[index] = part
            }

            try fileHandle.close()

            if !isCancelled && !isPaused {
                part.state = .completed
                parts[index] = part
            }

        } catch {
            if !isCancelled {
                part.state = .failed
                parts[index] = part
                await updateState(.failed)
                await manager?.onCompletion?(info.id, .failure(error))
            }
        }
    }

    private func saveResumeData(for request: URLRequest) async throws -> Data {
        // Create a download task to get resume data
        let task = URLSession.shared.downloadTask(with: request)
        task.resume()

        // Wait a bit then cancel to get resume data
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        task.cancel()

        // Note: In real implementation, use URLSessionDownloadDelegate to get resume data
        return Data()
    }

    private func reportProgress() async {
        while !isCancelled && !parts.allSatisfy({ $0.state == .completed || $0.state == .failed }) {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

            let totalDownloaded = parts.reduce(0) { $0 + $1.downloadedBytes }
            let progress = info.totalSize > 0 ? Double(totalDownloaded) / Double(info.totalSize) : 0

            // Calculate speed
            let now = Date()
            if let lastTime = lastProgressTime {
                let elapsed = now.timeIntervalSince(lastTime)
                let bytesSinceLast = totalDownloaded - lastDownloadedBytes
                let speed = Int64(Double(bytesSinceLast) / elapsed)
                let eta = speed > 0 && info.totalSize > totalDownloaded ? (info.totalSize - totalDownloaded) / speed : nil

                let speedStr = speed > 0 ? ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s" : nil
                let etaStr = eta.map { "\($0)s" }

                await manager?.onProgress?(info.id, progress, speed, etaStr)
            }

            lastProgressTime = now
            lastDownloadedBytes = totalDownloaded
        }
    }

    private func verifyAndComplete() async {
        await updateState(.verifying)

        // Merge parts into final file
        let downloadDir = await manager?.downloadDirectory(for: info.category, customFolder: nil) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let finalFile = downloadDir.appendingPathComponent(info.filename)

        do {
            let outputHandle = try FileHandle(forWritingTo: finalFile)

            for index in parts.indices {
                let partFile = downloadDir.appendingPathComponent("\(info.id)_part\(index).tmp")
                if fileManager.fileExists(atPath: partFile.path) {
                    let data = try Data(contentsOf: partFile)
                    try outputHandle.write(contentsOf: data)
                    try fileManager.removeItem(at: partFile)
                }
            }

            try outputHandle.close()

            // Verify checksum if available
            if let expectedHash = info.sha256Hash {
                let actualHash = try await computeSHA256(finalFile)
                if actualHash != expectedHash {
                    try fileManager.removeItem(at: finalFile)
                    throw JetBirdError.fileCorrupted
                }
            }

            await updateState(.completed)
            await manager?.onCompletion?(info.id, .success(finalFile))

        } catch {
            await updateState(.failed)
            await manager?.onCompletion?(info.id, .failure(error))
        }
    }

    private func computeSHA256(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func pause() async {
        isPaused = true
        // Cancel all part tasks
        for (_, task) in partTasks {
            task.cancel()
        }
        await updateState(.paused)
    }

    func cancel() async {
        isCancelled = true
        for (_, task) in partTasks {
            task.cancel()
        }
        // Clean up temp files
        let downloadDir = await manager?.downloadDirectory(for: info.category, customFolder: nil) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        for index in parts.indices {
            let partFile = downloadDir.appendingPathComponent("\(info.id)_part\(index).tmp")
            try? fileManager.removeItem(at: partFile)
        }
        await updateState(.cancelled)
    }

    private func computeState() -> DownloadState {
        if isCancelled { return .cancelled }
        if isPaused { return .paused }
        if parts.allSatisfy({ $0.state == .completed }) { return .completed }
        if parts.contains(where: { $0.state == .failed }) { return .failed }
        if parts.contains(where: { $0.state == .downloading }) { return .downloading }
        if parts.contains(where: { $0.state == .connecting }) { return .connecting }
        return .queued
    }

    private func updateState(_ state: DownloadState) async {
        var updatedInfo = info
        updatedInfo.state = state
        updatedInfo.updatedAt = Date()

        // Since info is immutable, we notify via callback
        await manager?.onStateChange?(info.id, state)
    }
}
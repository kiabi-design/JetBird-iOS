//
//  Types.swift
//  JetBird
//
//  Core type definitions for JetBird iOS
//  Ported from nueex/JetBird (GPL-3.0-or-later)
//

import Foundation

// MARK: - Transfer Mode

/// Transfer mode matching Android app
public enum TransferMode: Int, CaseIterable, Codable, Sendable {
    case none = 0           // Phone-only downloads
    case usbTransfer = 1    // USB (not supported on iOS)
    case wireless = 2       // Wi-Fi + SPAKE2 pairing

    public var displayName: String {
        switch self {
        case .none: return "Phone Only"
        case .usbTransfer: return "USB Transfer"
        case .wireless: return "Wireless Transfer"
        }
    }

    public var isAvailableOnIOS: Bool {
        switch self {
        case .none, .wireless: return true
        case .usbTransfer: return false
        }
    }
}

// MARK: - Download State

/// Download states matching Android TransferWorker states
public enum DownloadState: Int, CaseIterable, Codable, Sendable {
    case queued = 0
    case connecting = 1
    case downloading = 2
    case paused = 3
    case completed = 4
    case failed = 5
    case cancelled = 6
    case verifying = 7
    case installing = 8       // Parallel PKG install

    public var isActive: Bool {
        switch self {
        case .connecting, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - Download Info

/// Complete download metadata
public struct DownloadInfo: Codable, Sendable, Identifiable {
    public let id: UUID
    public var url: URL
    public var filename: String
    public var totalSize: Int64
    public var downloadedSize: Int64
    public var state: DownloadState
    public var parts: Int
    public var mimeType: String?
    public var category: FileCategory
    public var destination: TransferDestination
    public var createdAt: Date
    public var updatedAt: Date
    public var errorMessage: String?
    public var resumeData: Data?
    public var sha256Hash: String?
    public var isParallelInstall: Bool
    /// Path of the finished file relative to the Documents directory
    public var localRelativePath: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        totalSize: Int64 = -1,
        downloadedSize: Int64 = 0,
        state: DownloadState = .queued,
        parts: Int = 4,
        mimeType: String? = nil,
        category: FileCategory = .other,
        destination: TransferDestination = .phone,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        errorMessage: String? = nil,
        resumeData: Data? = nil,
        sha256Hash: String? = nil,
        isParallelInstall: Bool = false,
        localRelativePath: String? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.totalSize = totalSize
        self.downloadedSize = downloadedSize
        self.state = state
        self.parts = parts
        self.mimeType = mimeType
        self.category = category
        self.destination = destination
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.resumeData = resumeData
        self.sha256Hash = sha256Hash
        self.isParallelInstall = isParallelInstall
        self.localRelativePath = localRelativePath
    }

    public var progress: Double {
        guard totalSize > 0 else { return 0 }
        return Double(downloadedSize) / Double(totalSize)
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    public var formattedDownloaded: String {
        ByteCountFormatter.string(fromByteCount: downloadedSize, countStyle: .file)
    }

}

// MARK: - File Category

/// Auto-categorization matching Android app
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case compressed = "Compressed"
    case packages = "Packages"
    case videos = "Videos"
    case audio = "Audio"
    case images = "Images"
    case documents = "Documents"
    case other = "Other"

    public static func from(mimeType: String?, filename: String) -> FileCategory {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType?.lowercased() ?? ""

        if mime.hasPrefix("video/") || ["mp4", "mkv", "avi", "mov", "webm"].contains(ext) {
            return .videos
        }
        if mime.hasPrefix("audio/") || ["mp3", "flac", "wav", "ogg", "m4a", "aac"].contains(ext) {
            return .audio
        }
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"].contains(ext) {
            return .images
        }
        if ["pdf", "doc", "docx", "txt", "rtf", "epub", "md"].contains(ext) {
            return .documents
        }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst"].contains(ext) {
            return .compressed
        }
        if ["pkg"].contains(ext) {
            return .packages
        }
        return .other
    }

    public var systemImageName: String {
        switch self {
        case .compressed: return "doc.zipper"
        case .packages: return "shippingbox"
        case .videos: return "video"
        case .audio: return "music.note"
        case .images: return "photo"
        case .documents: return "doc.text"
        case .other: return "doc"
        }
    }
}

// MARK: - Transfer Destination

/// Where the file goes
public enum TransferDestination: String, CaseIterable, Codable, Sendable {
    case phone = "phone"
    case ps4 = "ps4"
    case both = "both"

    public var displayName: String {
        switch self {
        case .phone: return "Phone Only"
        case .ps4: return "PS4 Only (Stream)"
        case .both: return "Phone + PS4"
        }
    }
}

// MARK: - PS4 Connection Info

/// PS4 connection details for Wireless/Direct transfer
public struct PS4Connection: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var ipAddress: String
    public var port: Int
    public var certificateHash: String  // SHA-256 of cert for pinning
    public var isPaired: Bool
    public var lastConnected: Date?
    public var transferMode: TransferMode

    public init(
        id: UUID = UUID(),
        name: String,
        ipAddress: String,
        port: Int = 8080,
        certificateHash: String,
        isPaired: Bool = false,
        lastConnected: Date? = nil,
        transferMode: TransferMode = .wireless
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.certificateHash = certificateHash
        self.isPaired = isPaired
        self.lastConnected = lastConnected
        self.transferMode = transferMode
    }

    public var endpoint: String {
        "\(ipAddress):\(port)"
    }
}

// MARK: - SPAKE2 Pairing Data

/// SPAKE2 pairing session data
public struct Spake2PairingData: Sendable {
    public let code: UInt32           // 6-digit code
    public let pin: Data              // 16-byte PIN from QR
    public let scalar: Data           // 32-byte private scalar
    public let ourPoint: Data         // 65-byte our public point
    public var theirPoint: Data?      // 65-byte peer public point
    public var sessionKey: Data?      // 32-byte derived session key
    public var proofs: Data?          // 64-byte confirmation proofs

    public init(
        code: UInt32,
        pin: Data,
        scalar: Data,
        ourPoint: Data,
        theirPoint: Data? = nil,
        sessionKey: Data? = nil,
        proofs: Data? = nil
    ) {
        self.code = code
        self.pin = pin
        self.scalar = scalar
        self.ourPoint = ourPoint
        self.theirPoint = theirPoint
        self.sessionKey = sessionKey
        self.proofs = proofs
    }
}

// MARK: - Download Part

/// Multi-part download segment
public struct DownloadPart: Codable, Sendable, Equatable {
    public let index: Int
    public let startByte: Int64
    public let endByte: Int64
    public var downloadedBytes: Int64
    public var state: DownloadState
    public var taskIdentifier: Int?

    public var expectedSize: Int64 {
        endByte - startByte + 1
    }

    public var progress: Double {
        guard expectedSize > 0 else { return 0 }
        return Double(downloadedBytes) / Double(expectedSize)
    }
}

// MARK: - Browser Types

/// Browser tab
public struct BrowserTab: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var favicon: Data?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var createdAt: Date
    public var lastVisited: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String = "",
        favicon: Data? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        createdAt: Date = Date(),
        lastVisited: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.favicon = favicon
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.createdAt = createdAt
        self.lastVisited = lastVisited
    }
}

/// Browser bookmark
public struct Bookmark: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var folder: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        folder: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.folder = folder
        self.createdAt = createdAt
    }
}

/// Browser history entry
public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var visitCount: Int
    public var lastVisited: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        visitCount: Int = 1,
        lastVisited: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisited = lastVisited
    }
}

// MARK: - Settings

/// App settings matching Android SharedPreferences
public struct AppSettings: Codable, Sendable, Equatable {
    public var transferMode: TransferMode = .none
    public var downloadParts: Int = 4
    public var saveFileOnPhone: Bool = false
    public var customDownloadFolder: URL?
    public var theme: AppTheme = .system
    public var language: String = Locale.current.languageCode ?? "en"
    public var enableAdBlock: Bool = true
    public var enableBackgroundDownloads: Bool = true
    public var batteryOptimizationWarningShown: Bool = false
    public var autoClearBrowserData: Bool = false
    public var showDesktopSite: Bool = false
    public var searchEngine: SearchEngine = .google
    public var parallelInstallEnabled: Bool = true
    public var verifyDownloads: Bool = true

    public enum AppTheme: String, CaseIterable, Codable, Sendable {
        case light, dark, system
    }

    public enum SearchEngine: String, CaseIterable, Codable, Sendable {
        case google = "https://www.google.com/search?q=%@"
        case bing = "https://www.bing.com/search?q=%@"
        case duckduckgo = "https://duckduckgo.com/?q=%@"

        public var displayName: String {
            switch self {
            case .google: return "Google"
            case .bing: return "Bing"
            case .duckduckgo: return "DuckDuckGo"
            }
        }

        public func searchURL(query: String) -> URL {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = String(format: rawValue, encoded)
            return URL(string: urlString)!
        }
    }
}

// MARK: - Direct PS4 Download

/// Direct download handoff payload
public struct DirectPS4Download: Codable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let filename: String
    public let totalSize: Int64?
    public let isParallelInstall: Bool
    public let destination: TransferDestination

    public init(
        url: URL,
        headers: [String: String],
        filename: String,
        totalSize: Int64? = nil,
        isParallelInstall: Bool = false,
        destination: TransferDestination = .ps4
    ) {
        self.url = url
        self.headers = headers
        self.filename = filename
        self.totalSize = totalSize
        self.isParallelInstall = isParallelInstall
        self.destination = destination
    }
}

// MARK: - Errors

public enum JetBirdError: LocalizedError, Sendable {
    case networkUnavailable
    case invalidURL
    case downloadFailed(String)
    case pairingFailed(String)
    case certificatePinningFailed
    case insufficientStorage
    case fileCorrupted
    case ps4NotFound
    case ps4ConnectionFailed(String)
    case spake2Error(String)
    case tlsError(String)
    case backgroundTaskExpired
    case userCancelled
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable: return "Network unavailable"
        case .invalidURL: return "Invalid URL"
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .pairingFailed(let msg): return "Pairing failed: \(msg)"
        case .certificatePinningFailed: return "Certificate pinning validation failed"
        case .insufficientStorage: return "Insufficient storage space"
        case .fileCorrupted: return "Downloaded file is corrupted"
        case .ps4NotFound: return "PS4 not found on network"
        case .ps4ConnectionFailed(let msg): return "PS4 connection failed: \(msg)"
        case .spake2Error(let msg): return "SPAKE2 error: \(msg)"
        case .tlsError(let msg): return "TLS error: \(msg)"
        case .backgroundTaskExpired: return "Background task expired"
        case .userCancelled: return "Cancelled by user"
        case .unknown(let msg): return "Unknown error: \(msg)"
        }
    }
}
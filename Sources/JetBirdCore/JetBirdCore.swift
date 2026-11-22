//
//  JetBirdCore.swift
//  JetBirdCore
//
//  Main module entry point
//

import Foundation

// Re-export all public types
@_exported import struct JetBirdCore.Models.Types.TransferMode
@_exported import struct JetBirdCore.Models.Types.DownloadState
@_exported import struct JetBirdCore.Models.Types.DownloadInfo
@_exported import struct JetBirdCore.Models.Types.FileCategory
@_exported import struct JetBirdCore.Models.Types.TransferDestination
@_exported import struct JetBirdCore.Models.Types.PS4Connection
@_exported import struct JetBirdCore.Models.Types.Spake2PairingData
@_exported import struct JetBirdCore.Models.Types.DownloadPart
@_exported import struct JetBirdCore.Models.Types.BrowserTab
@_exported import struct JetBirdCore.Models.Types.Bookmark
@_exported import struct JetBirdCore.Models.Types.HistoryEntry
@_exported import struct JetBirdCore.Models.Types.AppSettings
@_exported import struct JetBirdCore.Models.Types.DirectPS4Download
@_exported import enum JetBirdCore.Models.Types.JetBirdError

@_exported import class JetBirdCore.Crypto.Spake2.Spake2Session
@_exported import actor JetBirdCore.Crypto.Spake2.Spake2Manager

@_exported import struct JetBirdCore.Protocol.PSMTPProtocol.PSMTPMessage
@_exported import actor JetBirdCore.Protocol.PSMTPProtocol.PSMTPConnection
@_exported import actor JetBirdCore.Protocol.PSMTPProtocol.PSMTPDiscovery
@_exported import enum JetBirdCore.Protocol.PSMTPProtocol.PSMTPError

@_exported import actor JetBirdCore.DownloadManager.DownloadManager
@_exported import actor JetBirdCore.DownloadManager.DownloadTask

@_exported import actor JetBirdCore.Browser.ContentFilters.ContentFilterEngine
@_exported import struct JetBirdCore.Browser.ContentFilters.FilterListParser
@_exported import actor JetBirdCore.Browser.ContentFilters.FilterListUpdater

// MARK: - Version

public let JetBirdVersion = "1.0.0"
public let JetBirdBuildNumber = 1
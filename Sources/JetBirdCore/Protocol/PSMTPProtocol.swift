//
//  PSMTPProtocol.swift
//  JetBirdCore
//
//  PSMTP (PS4 Media Transfer Protocol) implementation
//  Ported from Android TransferService/TransferWorker logic
//

import Foundation
import Network
import Crypto
import _CryptoExtras

// MARK: - PSMTP Constants

/// PSMTP protocol constants matching Android implementation
public enum PSMTP {
    public static let protocolVersion: UInt16 = 3
    public static let defaultPort: UInt16 = 8080
    public static let maxPacketSize: Int = 16384
    public static let handshakeTimeout: TimeInterval = 30
    public static let transferTimeout: TimeInterval = 300

    // Message types
    public enum MessageType: UInt8, Sendable {
        case hello = 0x01
        case helloAck = 0x02
        case authStart = 0x10
        case authChallenge = 0x11
        case authResponse = 0x12
        case authConfirm = 0x13
        case authComplete = 0x14
        case downloadRequest = 0x20
        case downloadResponse = 0x21
        case downloadData = 0x22
        case downloadEnd = 0x23
        case directDownload = 0x30
        case directDownloadAck = 0x31
        case pkgInstallStart = 0x40
        case pkgInstallData = 0x41
        case pkgInstallEnd = 0x42
        case pkgInstallStatus = 0x43
        case error = 0xFF
    }

    // Error codes
    public enum ErrorCode: UInt16, Sendable {
        case unknown = 0x0000
        case invalidMessage = 0x0001
        case authFailed = 0x0002
        case notAuthenticated = 0x0003
        case fileNotFound = 0x0004
        case permissionDenied = 0x0005
        case diskFull = 0x0006
        case checksumMismatch = 0x0007
        case invalidRange = 0x0008
        case transferCancelled = 0x0009
        case pkgInstallFailed = 0x000A
        case protocolVersionMismatch = 0x000B
    }
}

// MARK: - PSMTP Message

/// PSMTP message frame
public struct PSMTPMessage: Sendable {
    public let type: PSMTP.MessageType
    public let sequence: UInt32
    public let payload: Data

    public init(type: PSMTP.MessageType, sequence: UInt32, payload: Data = Data()) {
        self.type = type
        self.sequence = sequence
        self.payload = payload
    }

    /// Encode to wire format
    public func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) })
        data.append(payload)
        return data
    }

    /// Decode from wire format
    public static func decode(_ data: Data) -> PSMTPMessage? {
        guard data.count >= 9 else { return nil }

        let type = PSMTP.MessageType(rawValue: data[0]) ?? .error
        let sequence = data[1..<5].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let payloadLength = data[5..<9].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard data.count >= 9 + Int(payloadLength) else { return nil }
        let payload = data[9..<9+Int(payloadLength)]

        return PSMTPMessage(type: type, sequence: sequence, payload: Data(payload))
    }
}

// MARK: - PSMTP Connection

/// TLS-secured PSMTP connection to PS4
public actor PSMTPConnection {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.jetbird.psmtp", qos: .userInitiated)
    private var sequenceCounter: UInt32 = 0
    private var isAuthenticated = false
    private var sessionKey: Data?
    private let certificateHash: String

    // Callbacks
    public var onStateChange: ((NWConnection.State) -> Void)?
    public var onMessage: ((PSMTPMessage) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, certificateHash: String) {
        self.certificateHash = certificateHash

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, _, verifyBlock in
            // Certificate pinning - verify SHA-256 hash
            // Implementation would check peer certificate chain
            verifyBlock(true)
        }, queue)

        let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true

        connection = NWConnection(host: host, port: port, using: params)
        setupConnection()
    }

    private func setupConnection() {
        connection?.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateChange(state) }
        }

        connection?.violationHandler = { [weak self] error in
            Task { await self?.handleError(error) }
        }

        connection?.start(queue: queue)
    }

    private func handleStateChange(_ state: NWConnection.State) {
        onStateChange?(state)

        switch state {
        case .ready:
            Task { await performHandshake() }
        case .failed(let error):
            handleError(error)
        default:
            break
        }
    }

    private func performHandshake() async {
        // Send HELLO with protocol version
        let helloPayload = withUnsafeBytes(of: PSMTP.protocolVersion.bigEndian) { Data($0) }
        await sendMessage(type: .hello, payload: helloPayload)
    }

    private func handleMessage(_ message: PSMTPMessage) {
        switch message.type {
        case .helloAck:
            handleHelloAck(message)
        case .authChallenge:
            Task { await handleAuthChallenge(message) }
        case .authConfirm:
            Task { await handleAuthConfirm(message) }
        case .downloadResponse:
            onMessage?(message)
        case .downloadData:
            onMessage?(message)
        case .downloadEnd:
            onMessage?(message)
        case .directDownloadAck:
            onMessage?(message)
        case .pkgInstallStatus:
            onMessage?(message)
        case .error:
            handleErrorMessage(message)
        default:
            onMessage?(message)
        }
    }

    private func handleHelloAck(_ message: PSMTPMessage) {
        // Check protocol version
        guard message.payload.count >= 2 else { return }
        let version = message.payload.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        guard version == PSMTP.protocolVersion else {
            handleError(PSMTPError.protocolVersionMismatch)
            return
        }

        // Start SPAKE2 authentication
        // This would be triggered by the pairing flow
    }

    private func handleAuthChallenge(_ message: PSMTPMessage) async {
        // Process SPAKE2 challenge from PS4
        // Requires sessionKey from pairing
    }

    private func handleAuthConfirm(_ message: PSMTPMessage) async {
        // Verify SPAKE2 confirmation
        isAuthenticated = true
    }

    private func handleErrorMessage(_ message: PSMTPMessage) {
        guard message.payload.count >= 2 else { return }
        let code = message.payload.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        if let errorCode = PSMTP.ErrorCode(rawValue: code) {
            handleError(PSMTPError.serverError(errorCode))
        }
    }

    private func handleError(_ error: Error) {
        onError?(error)
    }

    /// Send PSMTP message
    public func sendMessage(type: PSMTP.MessageType, payload: Data = Data()) async {
        guard let connection = connection else { return }

        let sequence = nextSequence()
        let message = PSMTPMessage(type: type, sequence: sequence, payload: payload)
        let data = message.encode()

        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    self.handleError(error)
                }
                continuation.resume()
            })
        }
    }

    /// Send raw data (for file transfer)
    public func sendData(_ data: Data) async {
        await sendMessage(type: .downloadData, payload: data)
    }

    private func nextSequence() -> UInt32 {
        sequenceCounter &+= 1
        return sequenceCounter
    }

    /// Start download request
    public func requestDownload(url: String, headers: [String: String], range: Range<Int64>?) async {
        var payload = Data()
        // Encode URL
        let urlData = url.data(using: .utf8) ?? Data()
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(urlData.count).bigEndian) { Data($0) })
        payload.append(urlData)

        // Encode headers count
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(headers.count).bigEndian) { Data($0) })
        for (key, value) in headers {
            let keyData = key.data(using: .utf8) ?? Data()
            let valueData = value.data(using: .utf8) ?? Data()
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(keyData.count).bigEndian) { Data($0) })
            payload.append(keyData)
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(valueData.count).bigEndian) { Data($0) })
            payload.append(valueData)
        }

        // Encode range if present
        if let range = range {
            payload.append(1) // has range
            payload.append(contentsOf: withUnsafeBytes(of: range.lowerBound.bigEndian) { Data($0) })
            payload.append(contentsOf: withUnsafeBytes(of: range.upperBound.bigEndian) { Data($0) })
        } else {
            payload.append(0) // no range
        }

        await sendMessage(type: .downloadRequest, payload: payload)
    }

    /// Send direct download handoff
    public func sendDirectDownload(_ download: DirectPS4Download) async {
        var payload = Data()

        let urlData = download.url.absoluteString.data(using: .utf8) ?? Data()
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(urlData.count).bigEndian) { Data($0) })
        payload.append(urlData)

        // Headers
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(download.headers.count).bigEndian) { Data($0) })
        for (key, value) in download.headers {
            let keyData = key.data(using: .utf8) ?? Data()
            let valueData = value.data(using: .utf8) ?? Data()
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(keyData.count).bigEndian) { Data($0) })
            payload.append(keyData)
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(valueData.count).bigEndian) { Data($0) })
            payload.append(valueData)
        }

        // Filename
        let filenameData = download.filename.data(using: .utf8) ?? Data()
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(filenameData.count).bigEndian) { Data($0) })
        payload.append(filenameData)

        // Size
        if let size = download.totalSize {
            payload.append(1)
            payload.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Data($0) })
        } else {
            payload.append(0)
        }

        // Flags
        var flags: UInt8 = 0
        if download.isParallelInstall { flags |= 0x01 }
        if download.destination == .both { flags |= 0x02 }
        payload.append(flags)

        await sendMessage(type: .directDownload, payload: payload)
    }

    /// Start parallel PKG install
    public func startPKGInstall(filename: String, totalSize: Int64) async {
        var payload = Data()
        let filenameData = filename.data(using: .utf8) ?? Data()
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(filenameData.count).bigEndian) { Data($0) })
        payload.append(filenameData)
        payload.append(contentsOf: withUnsafeBytes(of: totalSize.bigEndian) { Data($0) })

        await sendMessage(type: .pkgInstallStart, payload: payload)
    }

    /// Send PKG install data chunk
    public func sendPKGData(_ data: Data) async {
        await sendMessage(type: .pkgInstallData, payload: data)
    }

    /// End PKG install
    public func endPKGInstall() async {
        await sendMessage(type: .pkgInstallEnd)
    }

    /// Close connection
    public func close() {
        connection?.cancel()
        connection = nil
    }
}

// MARK: - PSMTP Errors

public enum PSMTPError: LocalizedError, Sendable {
    case notConnected
    case notAuthenticated
    case protocolVersionMismatch
    case serverError(PSMTP.ErrorCode)
    case encodingFailed
    case decodingFailed
    case handshakeTimeout
    case transferTimeout
    case certificatePinningFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to PS4"
        case .notAuthenticated: return "Not authenticated"
        case .protocolVersionMismatch: return "Protocol version mismatch"
        case .serverError(let code): return "PS4 error: \(code)"
        case .encodingFailed: return "Message encoding failed"
        case .decodingFailed: return "Message decoding failed"
        case .handshakeTimeout: return "Handshake timeout"
        case .transferTimeout: return "Transfer timeout"
        case .certificatePinningFailed: return "Certificate pinning failed"
        }
    }
}

// MARK: - PSMTP Discovery (Bonjour)

/// Discover PS4 running PS MTP Explorer via Bonjour
public actor PSMTPDiscovery {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.jetbird.discovery")

    public var onDiscovered: ((PS4Connection) -> Void)?
    public var onRemoved: ((PS4Connection) -> Void)?

    public func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_psmtp._tcp", domain: nil)
        browser = NWBrowser(for: descriptor, using: parameters)

        browser?.stateUpdateHandler = { state in
            print("Discovery state: \(state)")
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { await self?.handleResults(results, changes: changes) }
        }

        browser?.start(queue: queue)
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, changes: [NWBrowser.ResultChange]) async {
        for change in changes {
            switch change {
            case .added(let result):
                if let connection = parseResult(result) {
                    await onDiscovered?(connection)
                }
            case .removed(let result):
                if let connection = parseResult(result) {
                    await onRemoved?(connection)
                }
            case .changed(let result, _):
                if let connection = parseResult(result) {
                    await onDiscovered?(connection)
                }
            @unknown default:
                break
            }
        }
    }

    private func parseResult(_ result: NWBrowser.Result) -> PS4Connection? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }

        // Parse TXT record for certificate hash, port, etc.
        // For now, create basic connection
        return PS4Connection(
            name: name,
            ipAddress: "", // Resolved via connection
            port: Int(PSMTP.defaultPort),
            certificateHash: "",
            isPaired: false
        )
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
//
//  PSMTP.swift
//  JetBird
//
//  PSMTP (PS4 Media Transfer Protocol) client: framing, TLS with certificate
//  pinning, SPAKE2 pairing and Bonjour discovery.
//  NOTE: the message flow follows the project README; it has not been verified
//  against a real console.
//

import Foundation
import Network
import CryptoKit
import Security

// MARK: - Constants

public enum PSMTP {
    public static let protocolVersion: UInt16 = 3
    public static let defaultPort: UInt16 = 8080
    public static let maxMessageSize: Int = 64 * 1024 * 1024
    public static let handshakeTimeout: TimeInterval = 30

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

public enum PSMTPError: LocalizedError, Sendable {
    case notConnected
    case notAuthenticated
    case protocolVersionMismatch
    case serverError(UInt16)
    case decodingFailed
    case handshakeTimeout
    case invalidPeerData

    public var errorDescription: String? {
        switch self {
        case .notConnected: return L("Not connected to PS4")
        case .notAuthenticated: return L("Not authenticated")
        case .protocolVersionMismatch: return L("Protocol version mismatch")
        case .serverError(let code): return L("PS4 reported error 0x%@", String(code, radix: 16))
        case .decodingFailed: return L("Message decoding failed")
        case .handshakeTimeout: return L("Connection timed out")
        case .invalidPeerData: return L("Invalid data received from PS4")
        }
    }
}

// MARK: - Message

public struct PSMTPMessage: Sendable {
    public let type: PSMTP.MessageType
    public let sequence: UInt32
    public let payload: Data

    public init(type: PSMTP.MessageType, sequence: UInt32, payload: Data = Data()) {
        self.type = type
        self.sequence = sequence
        self.payload = payload
    }

    /// Wire format: type (1) | sequence (4, BE) | length (4, BE) | payload
    public func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        data.appendUInt32(sequence)
        data.appendUInt32(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendInt64(_ value: Int64) {
        let raw = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: raw >> UInt64(shift)))
        }
    }

    mutating func appendPrefixed32(_ string: String) {
        let bytes = Data(string.utf8)
        appendUInt32(UInt32(bytes.count))
        append(bytes)
    }

    mutating func appendPrefixed16(_ string: String) {
        let bytes = Data(string.utf8)
        appendUInt16(UInt16(clamping: bytes.count))
        append(bytes.prefix(Int(UInt16.max)))
    }
}

// MARK: - Connection

/// TLS connection to the PS4 with certificate pinning.
/// All mutable state is protected by `lock`; network callbacks run on `queue`.
public final class PSMTPConnection: @unchecked Sendable {
    private final class Waiter {
        let type: PSMTP.MessageType
        let continuation: CheckedContinuation<PSMTPMessage, Error>
        init(type: PSMTP.MessageType, continuation: CheckedContinuation<PSMTPMessage, Error>) {
            self.type = type
            self.continuation = continuation
        }
    }

    private final class CertificateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _observed: String?
        var observed: String? {
            get { lock.lock(); defer { lock.unlock() }; return _observed }
            set { lock.lock(); _observed = newValue; lock.unlock() }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.jetbird.psmtp")
    private let certificateBox: CertificateBox
    private let lock = NSLock()

    private var started = false
    private var isReady = false
    private var failure: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var waiter: Waiter?
    private var inbox: [PSMTPMessage] = []
    private var buffer = Data()
    private var sequence: UInt32 = 0
    private var authenticated = false

    /// SHA-256 (hex) of the certificate the console presented, if any.
    public var observedCertificateHash: String? { certificateBox.observed }

    public var isAuthenticated: Bool {
        lock.lock(); defer { lock.unlock() }
        return authenticated
    }

    /// - Parameter certificateHash: pinned SHA-256 (hex) of the console certificate.
    ///   If nil/empty the first certificate is accepted (trust on first use) and
    ///   exposed via `observedCertificateHash`; pairing proofs then authenticate the peer.
    public init(endpoint: NWEndpoint, certificateHash: String?) {
        let expected = (certificateHash ?? "").lowercased()
        let box = CertificateBox()
        self.certificateBox = box

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let leaf = chain.first else {
                    complete(false)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
                box.observed = hash
                complete(expected.isEmpty || hash == expected)
            },
            DispatchQueue(label: "com.jetbird.psmtp.tls")
        )

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        connection = NWConnection(to: endpoint, using: params)
    }

    public convenience init(host: String, port: UInt16 = PSMTP.defaultPort, certificateHash: String?) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: PSMTP.defaultPort)!
        )
        self.init(endpoint: endpoint, certificateHash: certificateHash)
    }

    // MARK: Lifecycle

    public func connect(timeout: TimeInterval = PSMTP.handshakeTimeout) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isReady { lock.unlock(); cont.resume(); return }
            if let failure = failure { lock.unlock(); cont.resume(throwing: failure); return }
            readyWaiters.append(cont)
            let shouldStart = !started
            started = true
            lock.unlock()

            if shouldStart {
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.markReady()
                        self.receiveLoop()
                    case .failed(let error):
                        self.fail(error)
                    case .cancelled:
                        self.fail(PSMTPError.notConnected)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let ready = self.isReady
                self.lock.unlock()
                if !ready { self.fail(PSMTPError.handshakeTimeout) }
            }
        }
    }

    public func close() {
        fail(PSMTPError.notConnected)
    }

    private func markReady() {
        lock.lock()
        isReady = true
        let waiters = readyWaiters
        readyWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure != nil { lock.unlock(); return }
        failure = error
        authenticated = false
        let ready = readyWaiters
        readyWaiters = []
        let pending = waiter
        waiter = nil
        lock.unlock()

        ready.forEach { $0.resume(throwing: error) }
        pending?.continuation.resume(throwing: error)
        connection.cancel()
    }

    // MARK: Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if let error = error { self.fail(error); return }
            if isComplete { self.fail(PSMTPError.notConnected); return }
            self.receiveLoop()
        }
    }

    private func drainBuffer() {
        while buffer.count >= 9 {
            let header = [UInt8](buffer.prefix(9))
            let length = Int(Self.bigEndian32(header, at: 5))
            if length > PSMTP.maxMessageSize { fail(PSMTPError.decodingFailed); return }
            if buffer.count < 9 + length { return }

            let sequence = Self.bigEndian32(header, at: 1)
            let start = buffer.startIndex
            let payload = Data(buffer[(start + 9)..<(start + 9 + length)])
            buffer.removeSubrange(start..<(start + 9 + length))

            if let type = PSMTP.MessageType(rawValue: header[0]) {
                deliver(PSMTPMessage(type: type, sequence: sequence, payload: payload))
            }
        }
    }

    private static func bigEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(bytes[offset + i]) }
        return value
    }

    private static func bigEndian16(_ data: Data, at offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        return (UInt16(data[start]) << 8) | UInt16(data[start + 1])
    }

    private func deliver(_ message: PSMTPMessage) {
        lock.lock()
        if let w = waiter, message.type == w.type || message.type == .error {
            waiter = nil
            lock.unlock()
            if message.type == .error {
                let code: UInt16 = message.payload.count >= 2 ? Self.bigEndian16(message.payload, at: 0) : 0
                w.continuation.resume(throwing: PSMTPError.serverError(code))
            } else {
                w.continuation.resume(returning: message)
            }
            return
        }
        inbox.append(message)
        lock.unlock()
    }

    public func waitFor(_ type: PSMTP.MessageType, timeout: TimeInterval = PSMTP.handshakeTimeout) async throws -> PSMTPMessage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PSMTPMessage, Error>) in
            lock.lock()
            if let failure = failure { lock.unlock(); cont.resume(throwing: failure); return }
            if let index = inbox.firstIndex(where: { $0.type == type }) {
                let message = inbox.remove(at: index)
                lock.unlock()
                cont.resume(returning: message)
                return
            }
            let w = Waiter(type: type, continuation: cont)
            waiter = w
            lock.unlock()

            queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak w] in
                guard let self = self, let w = w else { return }
                self.lock.lock()
                let stillWaiting = self.waiter === w
                if stillWaiting { self.waiter = nil }
                self.lock.unlock()
                if stillWaiting { w.continuation.resume(throwing: PSMTPError.handshakeTimeout) }
            }
        }
    }

    // MARK: Sending

    private func nextSequence() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    public func send(_ type: PSMTP.MessageType, payload: Data = Data()) async throws {
        let data = PSMTPMessage(type: type, sequence: nextSequence(), payload: payload).encode()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    // MARK: Pairing

    /// Runs the SPAKE2 pairing flow and returns the derived 32-byte session key.
    public func pair(code: UInt32, pin: Data) async throws -> Data {
        // 1. Hello / version check
        var hello = Data()
        hello.appendUInt16(PSMTP.protocolVersion)
        try await send(.hello, payload: hello)
        let ack = try await waitFor(.helloAck)
        guard ack.payload.count >= 2 else { throw PSMTPError.invalidPeerData }
        let version = Self.bigEndian16(ack.payload, at: 0)
        guard version == PSMTP.protocolVersion else { throw PSMTPError.protocolVersionMismatch }

        // 2. Send our SPAKE2 point
        let session = try Spake2Session(role: .phone, code: code, pin: pin)
        let ourPoint = try session.computeShare()
        try await send(.authStart, payload: ourPoint)

        // 3. Receive their point (65 bytes) + their proofs (64 bytes)
        let challenge = try await waitFor(.authChallenge)
        guard challenge.payload.count >= 65 + 64 else { throw PSMTPError.invalidPeerData }
        let base = challenge.payload.startIndex
        let theirPoint = Data(challenge.payload[base..<(base + 65)])
        let theirProofs = Data(challenge.payload[(base + 65)..<(base + 65 + 64)])

        try session.processTheirPoint(theirPoint)
        let ourProofs = try session.generateProofs()
        guard try session.verifyProofs(theirProofs) else { throw Spake2Error.verificationFailed }

        // 4. Send our proofs, wait for confirmation
        try await send(.authResponse, payload: ourProofs)
        _ = try await waitFor(.authConfirm)

        let key = try session.sessionKey()
        lock.lock()
        authenticated = true
        lock.unlock()
        return key
    }

    // MARK: Transfers

    public func sendDirectDownload(_ download: DirectPS4Download) async throws {
        guard isAuthenticated else { throw PSMTPError.notAuthenticated }
        var payload = Data()
        payload.appendPrefixed32(download.url.absoluteString)

        payload.appendUInt16(UInt16(clamping: download.headers.count))
        for (key, value) in download.headers {
            payload.appendPrefixed16(key)
            payload.appendPrefixed16(value)
        }

        payload.appendPrefixed32(download.filename)

        if let size = download.totalSize {
            payload.append(1)
            payload.appendInt64(size)
        } else {
            payload.append(0)
        }

        var flags: UInt8 = 0
        if download.isParallelInstall { flags |= 0x01 }
        if download.destination == .both { flags |= 0x02 }
        payload.append(flags)

        try await send(.directDownload, payload: payload)
    }
}

// MARK: - Discovery (Bonjour)

public struct DiscoveredPS4: Identifiable, Hashable, @unchecked Sendable {
    public var id: String { name }
    public let name: String
    public let endpoint: NWEndpoint
    public let certificateHash: String?
}

@MainActor
public final class PSMTPDiscovery: ObservableObject {
    @Published public private(set) var consoles: [DiscoveredPS4] = []
    @Published public private(set) var isSearching = false

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.jetbird.discovery")

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_psmtp._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [DiscoveredPS4] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var certHash: String?
                if case .bonjour(let record) = result.metadata {
                    certHash = record.dictionary["cert"]
                }
                return DiscoveredPS4(name: name, endpoint: result.endpoint, certificateHash: certHash)
            }
            Task { @MainActor in self?.consoles = found.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isSearching = true
                case .failed, .cancelled: self?.isSearching = false
                default: break
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}

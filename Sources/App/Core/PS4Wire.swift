//
//  PS4Wire.swift
//  JetBird
//
//  Wireless transfer protocol of PS MTP Explorer, ported from nueex/JetBird
//  (WirelessDestination.kt, Destination.kt, lan_spake.c). GPL-3.0-or-later.
//
//  Summary of the protocol:
//   * TCP port 41984, TLS 1.2. The console certificate is identified by the first
//     16 bytes of the SHA-256 of its DER encoding ("pin"); no CA validation.
//   * QR pairing:   "PSMTP1:<ipv4>:<64 hex>"  ->  pin (16 bytes) + secret (16 bytes).
//   * Hello:        "PSL1" | secret(16) | transfer(1 byte)   ->   "PSR1" | status(int32)
//   * Manual pair:  TLS without pin, send "PSM3", read the console SPAKE2 point (65 bytes),
//                   the console shows a 6-digit code; the phone then sends
//                   share(65) + proof(32) and receives status, proof(32), secret(16).
//   * Direct download hand-off: see PS4Client.handoff.
//

import Foundation
import Network
import CryptoKit
import Security

// MARK: - Constants

enum PS4Wire {
    static let port: UInt16 = 41984
    static let multipartALPN = "psmtp-parts/1"

    static let hello: UInt32 = 0x50534c31          // "PSL1"
    static let helloInstall: UInt32 = 0x50534c32   // "PSL2"
    static let pair: UInt32 = 0x50534d33           // "PSM3"
    static let reply: UInt32 = 0x50535231          // "PSR1"
    static let storageRequest: UInt32 = 0x50535131 // "PSQ1"
    static let storageReply: UInt32 = 0x50535331   // "PSS1"

    static let connectTimeout: TimeInterval = 12
    static let ioTimeout: TimeInterval = 22
    static let handoffTimeout: TimeInterval = 60
    static let maxRequestSize = 16384
}

// MARK: - Errors

struct PS4Error: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func ps4ReplyMessage(_ code: Int32) -> String {
    let value = Int(code)
    if (0x10064...0x10257).contains(value) {
        let http = value - 0x10000
        switch http {
        case 401, 403:
            return L("The download server denied access from the PS4 (HTTP %ld). The link may require a new login or have expired.", http)
        case 404, 410:
            return L("The download server could not find the file (HTTP %ld).", http)
        default:
            return L("The PS4 received HTTP %ld when opening the download link.", http)
        }
    }
    if code < 0 {
        let raw = UInt32(bitPattern: code)
        let reason: String
        switch raw {
        case 0x80990077, 0x80990065, 0x80990061, 0x80990078, 0x8099006b:
            reason = L("The package failed the PS4 integrity check.")
        case 0x8099003a, 0x80990074:
            reason = L("The PS4 installer could not read the package.")
        case 0x80990039, 0x80990021:
            reason = L("There is not enough PS4 storage to install this package.")
        case 0x80990064, 0x80990066, 0x80990067, 0x80990068, 0x8099007a:
            reason = L("The update package does not match the installed base game.")
        case 0x80990015, 0x80990086:
            reason = L("An installation task already exists for this content.")
        case 0x80990088:
            reason = L("This package conflicts with installed content.")
        default:
            reason = L("The PS4 system installer rejected the package.")
        }
        return L("%@ System error 0x%@.", reason, String(format: "%08x", raw))
    }
    switch code {
    case 1: return L("The PS4 rejected or cancelled the request.")
    case 2: return L("There is not enough free space on the PS4.")
    case 3: return L("A file with that name already exists on the PS4.")
    case 4: return L("The PS4 could not verify the received file or its expected size.")
    case 5: return L("The PS4 could not write the file to storage.")
    case 7: return L("The PS4 installer rejected the transfer without providing an error code.")
    case 9: return L("The PS4 could not establish an HTTPS connection to the download server.")
    case 10: return L("The download server did not respond to the PS4 in time.")
    case 11: return L("The PS4 received a web page, incomplete file, or unexpected response. Try a fresh direct download link.")
    case 12: return L("The download link did not return a complete PS4 package.")
    case 13: return L("The PS4 already has an HTTPS download or update check running.")
    case 14: return L("The PS4 could not initialize its HTTPS download support.")
    case 15: return L("This update package requires its matching base game to be installed first.")
    case 16: return L("The PS4 could not start or finish the installation.")
    case 17: return L("The PS4 has no internet connection.")
    default: return L("Unexpected PS4 transfer response (code %ld).", value)
    }
}

// MARK: - Data helpers

extension Data {
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

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        var result: UInt32 = 0
        for index in 0..<4 {
            result = (result << 8) | UInt32(self[startIndex + offset + index])
        }
        return result
    }

    func bigEndianInt64(at offset: Int) -> Int64 {
        var result: UInt64 = 0
        for index in 0..<8 {
            result = (result << 8) | UInt64(self[startIndex + offset + index])
        }
        return Int64(bitPattern: result)
    }
}

private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
}

/// Private or link-local IPv4 address (the PS4 must be on the local network).
func isLocalIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    var bytes: [Int] = []
    for part in parts {
        guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(part), number <= 255 else { return false }
        bytes.append(number)
    }
    if bytes[0] == 10 { return true }
    if bytes[0] == 172 && (16...31).contains(bytes[1]) { return true }
    if bytes[0] == 192 && bytes[1] == 168 { return true }
    if bytes[0] == 169 && bytes[1] == 254 { return true }
    return false
}

// MARK: - TLS link

/// One TLS connection to the console. All reads/writes are exact-length and time-limited.
final class PS4Link: @unchecked Sendable {
    private final class CertificateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var value: Data? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// Makes sure exactly one of "result" or "timeout" resumes a continuation.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func complete() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.jetbird.ps4link")
    private let certificateBox: CertificateBox

    /// First 16 bytes of the SHA-256 of the certificate the console presented.
    var peerFingerprint: Data? { certificateBox.value }

    /// - Parameters:
    ///   - expectedFingerprint: pinned 16-byte fingerprint, or nil to accept any certificate
    ///     (used for manual pairing, where the SPAKE2 proofs authenticate the console).
    ///   - transfer: advertise the "psmtp-parts/1" ALPN protocol (hand-off / storage connections).
    init(host: String, expectedFingerprint: Data?, transfer: Bool) {
        let box = CertificateBox()
        certificateBox = box

        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        if transfer {
            sec_protocol_options_add_tls_application_protocol(options, PS4Wire.multipartALPN)
        }
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            let fingerprint = Data(SHA256.hash(data: der).prefix(16))
            box.value = fingerprint
            if let expected = expectedFingerprint {
                complete(constantTimeEqual(fingerprint, expected))
            } else {
                complete(true)
            }
        }, DispatchQueue(label: "com.jetbird.ps4link.tls"))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: PS4Wire.port)!
        )
        connection = NWConnection(to: endpoint, using: parameters)
    }

    static func describe(_ error: NWError) -> PS4Error {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return PS4Error(L("The PS4 receiver is not accepting connections. Enable Wireless Transfer on the console."))
        case .posix(let code) where code == .ETIMEDOUT || code == .EHOSTUNREACH:
            return PS4Error(L("The PS4 did not respond over Wi-Fi. Open Wireless Transfer on the console and retry."))
        case .tls:
            return PS4Error(L("Could not verify the paired PS4. Open Wireless Transfer on the console and pair again."))
        default:
            return PS4Error(L("The wireless connection closed before the PS4 accepted the request. Pair again if the console ended the session.") + " (\(error))")
        }
    }

    func connect(timeout: TimeInterval = PS4Wire.connectTimeout) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = Gate()

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if gate.complete() {
                    continuation.resume(throwing: PS4Error(L("The PS4 did not respond over Wi-Fi. Open Wireless Transfer on the console and retry.")))
                    self?.connection.cancel()
                }
            }

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if gate.complete() { continuation.resume() }
                case .failed(let error):
                    if gate.complete() { continuation.resume(throwing: PS4Link.describe(error)) }
                case .waiting(let error):
                    // The local-network permission prompt also shows up as "waiting";
                    // only give up early on definite network errors.
                    if case .posix(let code) = error,
                       code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH || code == .ENETDOWN {
                        if gate.complete() {
                            continuation.resume(throwing: PS4Link.describe(error))
                            self?.connection.cancel()
                        }
                    }
                case .cancelled:
                    if gate.complete() {
                        continuation.resume(throwing: PS4Error(L("The wireless connection closed before the PS4 accepted the request. Pair again if the console ended the session.")))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: PS4Link.describe(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func readExactly(_ count: Int, timeout: TimeInterval = PS4Wire.ioTimeout) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = Gate()

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if gate.complete() {
                    continuation.resume(throwing: PS4Error(L("The PS4 did not respond over Wi-Fi. Open Wireless Transfer on the console and retry.")))
                    self?.connection.cancel()
                }
            }

            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                guard gate.complete() else { return }
                if let error = error {
                    continuation.resume(throwing: PS4Link.describe(error))
                } else if let data = data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: PS4Error(L("The wireless connection closed before the PS4 accepted the request. Pair again if the console ended the session.")))
                }
            }
        }
    }

    /// "PSR1" | status(int32 BE)
    func readReply(timeout: TimeInterval = PS4Wire.ioTimeout) async throws -> Int32 {
        let bytes = try await readExactly(8, timeout: timeout)
        guard bytes.bigEndianUInt32(at: 0) == PS4Wire.reply else {
            throw PS4Error(L("Unsupported PS4 wireless receiver."))
        }
        return Int32(bitPattern: bytes.bigEndianUInt32(at: 4))
    }

    func close() {
        connection.cancel()
    }
}

// MARK: - SPAKE2 (native C library from the original app)

enum PairingCrypto {
    /// Phone-side SPAKE2 share (65-byte SEC1 point); nil if the scalar is not valid.
    static func share(code: UInt32, scalar: [UInt8]) -> [UInt8]? {
        guard scalar.count == 32 else { return nil }
        var point = [UInt8](repeating: 0, count: 65)
        let ok: Int32 = scalar.withUnsafeBufferPointer { s in
            point.withUnsafeMutableBufferPointer { p in
                psmtp_spake_share(code, s.baseAddress!, 1, p.baseAddress!)
            }
        }
        return ok != 0 ? point : nil
    }

    /// 64 bytes: proofs[0..<32] is sent to the console, proofs[32..<64] is expected back.
    static func proofs(code: UInt32, scalar: [UInt8], phone: [UInt8], console: [UInt8], pin: [UInt8]) -> [UInt8]? {
        guard scalar.count == 32, phone.count == 65, console.count == 65, pin.count == 16 else { return nil }
        var out = [UInt8](repeating: 0, count: 64)
        let ok: Int32 = scalar.withUnsafeBufferPointer { s in
            phone.withUnsafeBufferPointer { a in
                console.withUnsafeBufferPointer { b in
                    pin.withUnsafeBufferPointer { f in
                        out.withUnsafeMutableBufferPointer { o in
                            psmtp_spake_confirm(code, s.baseAddress!, 1, a.baseAddress!, b.baseAddress!, f.baseAddress!, o.baseAddress!)
                        }
                    }
                }
            }
        }
        return ok != 0 ? out : nil
    }
}

// MARK: - Credentials

struct PS4Credentials: Codable, Equatable, Sendable {
    let host: String
    let pin: Data      // 16 bytes
    let secret: Data   // 16 bytes

    /// QR payload: "PSMTP1:<ipv4>:<64 hex characters>"
    static func fromQR(_ value: String) -> PS4Credentials? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 96 else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "PSMTP1", isLocalIPv4(parts[1]) else { return nil }

        let hex = parts[2].filter { !$0.isWhitespace && $0 != "-" }
        guard hex.count == 64, let bytes = Data(hexString: hex) else { return nil }
        return PS4Credentials(host: parts[1], pin: bytes.prefix(16), secret: bytes.suffix(16))
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

/// Stores the pairing in the Keychain (falls back to UserDefaults if the Keychain is unavailable,
/// e.g. for some sideloaded builds).
enum PS4CredentialStore {
    private static let service = "com.jetbird.ps4"
    private static let account = "wireless-pair"
    private static let fallbackKey = "jetbird.ps4.credentials.fallback"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ credentials: PS4Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            UserDefaults.standard.set(data, forKey: fallbackKey)
        }
    }

    static func load() -> PS4Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let credentials = try? JSONDecoder().decode(PS4Credentials.self, from: data) {
            return credentials
        }
        if let data = UserDefaults.standard.data(forKey: fallbackKey) {
            return try? JSONDecoder().decode(PS4Credentials.self, from: data)
        }
        return nil
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }
}

// MARK: - Client

struct ConsoleStorage: Equatable, Sendable {
    let available: Int64
    let total: Int64
}

struct PS4Client: Sendable {
    let credentials: PS4Credentials

    var host: String { credentials.host }

    /// TLS + "PSL1" hello. `transfer` connections also negotiate the multipart ALPN protocol.
    func open(transfer: Bool) async throws -> PS4Link {
        let link = PS4Link(host: credentials.host, expectedFingerprint: credentials.pin, transfer: transfer)
        do {
            try await link.connect()
            var hello = Data()
            hello.appendUInt32(PS4Wire.hello)
            hello.append(credentials.secret)
            hello.append(transfer ? 1 : 0)
            try await link.send(hello)
            let status = try await link.readReply()
            guard status == 0 else { throw PS4Error(ps4ReplyMessage(status)) }
            return link
        } catch {
            link.close()
            throw error
        }
    }

    /// Checks that the console is reachable and still accepts this pairing.
    func probe() async throws {
        let link = try await open(transfer: false)
        link.close()
    }

    func storage() async throws -> ConsoleStorage? {
        let link = try await open(transfer: true)
        defer { link.close() }
        var request = Data()
        request.appendUInt32(PS4Wire.storageRequest)
        request.append(Data(count: 12))
        try await link.send(request)
        let frame = try await link.readExactly(24, timeout: 4)
        guard frame.bigEndianUInt32(at: 0) == PS4Wire.storageReply,
              frame.bigEndianUInt32(at: 4) == 0 else { return nil }
        let available = frame.bigEndianInt64(at: 8)
        let total = frame.bigEndianInt64(at: 16)
        guard available >= 0, total > 0, available <= total else { return nil }
        return ConsoleStorage(available: available, total: total)
    }

    /// Direct PS4 Download: the console downloads `request` (url, user agent, referer, cookie
    /// separated by NUL bytes) itself.
    func handoff(name: String, size: Int64, request: Data, install: Bool) async throws {
        let link = try await open(transfer: true)
        defer { link.close() }

        let encodedName = Data(name.utf8)
        var header = Data()
        header.appendUInt32(install ? PS4Wire.helloInstall : PS4Wire.hello)
        header.appendUInt32(UInt32(encodedName.count))
        header.appendInt64(size)
        try await link.send(header)

        let ready = try await link.readReply()
        if ready == 7 {
            throw PS4Error(L("The PS4 receiver does not support Direct PS4 Download. Update PS MTP Explorer."))
        }
        guard ready == 0 else { throw PS4Error(ps4ReplyMessage(ready)) }

        var body = encodedName
        body.appendUInt32(UInt32(request.count))
        body.append(request)
        try await link.send(body)

        do {
            let status = try await link.readReply(timeout: PS4Wire.handoffTimeout)
            guard status == 0 else { throw PS4Error(ps4ReplyMessage(status)) }
        } catch let error as PS4Error {
            throw error
        } catch {
            throw PS4Error(L("The PS4 connection closed before confirmation. Check the download or installation on the console before retrying."))
        }
    }
}

// MARK: - Manual pairing (six-digit code)

final class PS4ManualPairing: @unchecked Sendable {
    private let host: String
    private let link: PS4Link
    private let pin: Data
    private let console: Data

    private init(host: String, link: PS4Link, pin: Data, console: Data) {
        self.host = host
        self.link = link
        self.pin = pin
        self.console = console
    }

    /// Connects and asks the console to show a six-digit code ("PSM3").
    static func open(host: String) async throws -> PS4ManualPairing {
        let link = PS4Link(host: host, expectedFingerprint: nil, transfer: false)
        do {
            try await link.connect()
            guard let pin = link.peerFingerprint else {
                throw PS4Error(L("Could not verify the paired PS4. Open Wireless Transfer on the console and pair again."))
            }
            var request = Data()
            request.appendUInt32(PS4Wire.pair)
            try await link.send(request)
            let console = try await link.readExactly(65)
            return PS4ManualPairing(host: host, link: link, pin: pin, console: console)
        } catch {
            link.close()
            throw error
        }
    }

    static func isValid(code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    func finish(code entered: String) async throws -> PS4Credentials {
        guard Self.isValid(code: entered), let code = UInt32(entered) else {
            throw PS4Error(L("Enter the six digits shown on your PS4."))
        }

        var scalar = [UInt8](repeating: 0, count: 32)
        var phone: [UInt8]?
        repeat {
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &scalar) == errSecSuccess else {
                throw PS4Error(L("Cryptographic operation failed"))
            }
            phone = PairingCrypto.share(code: code, scalar: scalar)
        } while phone == nil

        guard let share = phone,
              let proofs = PairingCrypto.proofs(code: code, scalar: scalar, phone: share,
                                                console: [UInt8](console), pin: [UInt8](pin)) else {
            scalar = [UInt8](repeating: 0, count: 32)
            throw PS4Error(L("The PS4 returned an invalid pairing message."))
        }
        scalar = [UInt8](repeating: 0, count: 32)

        var message = Data(share)
        message.append(Data(proofs[0..<32]))
        try await link.send(message)

        let status = try await link.readReply()
        guard status == 0 else { throw PS4Error(ps4ReplyMessage(status)) }

        let reply = try await link.readExactly(32)
        guard constantTimeEqual(Data(proofs[32..<64]), reply) else {
            throw PS4Error(L("The pairing code could not authenticate this PS4."))
        }
        let secret = try await link.readExactly(16)
        link.close()
        return PS4Credentials(host: host, pin: pin, secret: secret)
    }

    func close() {
        link.close()
    }
}

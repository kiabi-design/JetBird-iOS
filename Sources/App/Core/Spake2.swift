//
//  Spake2.swift
//  JetBird
//
//  Swift wrapper for Rust SPAKE2 (RFC 9382) implementation
//  Ported from native/lan_spake.c (GPL-3.0-or-later)
//

import Foundation
import CJetBirdSpake2

/// Return codes of the Rust library (jetbird_spake2.h), as plain Int32.
/// The C enums are imported into Swift as structs, so we mirror the raw values here.
enum SpakeC {
    static let success: Int32 = 0
    static let invalidCode: Int32 = -1
    static let invalidScalar: Int32 = -2
    static let cryptoFailure: Int32 = -3
    static let invalidInput: Int32 = -4
    static let bufferTooSmall: Int32 = -5
}

// MARK: - SPAKE2 Errors

public enum Spake2Error: LocalizedError, Sendable {
    case invalidCode
    case invalidScalar
    case cryptoFailure
    case invalidInput
    case bufferTooSmall
    case sessionNotCreated
    case verificationFailed
    case invalidRole

    public var errorDescription: String? {
        switch self {
        case .invalidCode: return L("Invalid pairing code (must be 0-999999)")
        case .invalidScalar: return L("Invalid scalar (must be in [1, n-1])")
        case .cryptoFailure: return L("Cryptographic operation failed")
        case .invalidInput: return L("Invalid input parameters")
        case .bufferTooSmall: return L("Output buffer too small")
        case .sessionNotCreated: return L("Session not created")
        case .verificationFailed: return L("Proof verification failed")
        case .invalidRole: return L("Invalid role")
        }
    }

    init?(from code: Int32) {
        switch code {
        case SpakeC.success: return nil
        case SpakeC.invalidCode: self = .invalidCode
        case SpakeC.invalidScalar: self = .invalidScalar
        case SpakeC.cryptoFailure: self = .cryptoFailure
        case SpakeC.invalidInput: self = .invalidInput
        case SpakeC.bufferTooSmall: self = .bufferTooSmall
        default: self = .cryptoFailure
        }
    }
}

// MARK: - SPAKE2 Role

public enum Spake2Role: Sendable {
    case phone    // Client (iPhone)
    case console  // Server (PS4)

    var cValue: Int32 {
        switch self {
        case .phone: return 1
        case .console: return 2
        }
    }
}

// MARK: - SPAKE2 Session

/// SPAKE2 pairing session
/// Manages the complete pairing flow: share -> process -> verify -> session key
public final class Spake2Session: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let role: Spake2Role
    private let code: UInt32
    private let pin: Data

    /// Create new SPAKE2 session
    /// - Parameters:
    ///   - role: Phone (client) or Console (server)
    ///   - code: 6-digit pairing code (0-999999)
    ///   - pin: 16-byte PIN from QR code
    public init(role: Spake2Role, code: UInt32, pin: Data) throws {
        guard code < 1_000_000 else { throw Spake2Error.invalidCode }
        guard pin.count == 16 else { throw Spake2Error.invalidInput }

        self.role = role
        self.code = code
        self.pin = pin

        // Generate random scalar
        var scalar = Data(count: 32)
        let result = scalar.withUnsafeMutableBytes { bytes in
            jetbird_spake2_random_scalar(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard result == SpakeC.success else { throw Spake2Error.cryptoFailure }

        // Validate scalar
        let valid = scalar.withUnsafeBytes { bytes in
            jetbird_spake2_validate_scalar(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard valid == 1 else { throw Spake2Error.invalidScalar }

        // Create session
        handle = scalar.withUnsafeBytes { scalarBytes in
            pin.withUnsafeBytes { pinBytes in
                jetbird_spake2_create(
                    role.cValue,
                    code,
                    scalarBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    pinBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }

        guard handle != nil else { throw Spake2Error.sessionNotCreated }
    }

    deinit {
        if let handle = handle {
            jetbird_spake2_destroy(handle)
        }
    }

    /// Compute our public point to share with peer (65 bytes SEC1 uncompressed)
    public func computeShare() throws -> Data {
        guard let handle = handle else { throw Spake2Error.sessionNotCreated }

        var point = Data(count: 65)
        let result = point.withUnsafeMutableBytes { bytes in
            jetbird_spake2_compute_share(handle, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        guard result == SpakeC.success else { throw Spake2Error.cryptoFailure }
        return point
    }

    /// Process peer's public point and compute shared secret
    public func processTheirPoint(_ theirPoint: Data) throws {
        guard let handle = handle else { throw Spake2Error.sessionNotCreated }
        guard theirPoint.count == 65 else { throw Spake2Error.invalidInput }

        let result = theirPoint.withUnsafeBytes { bytes in
            jetbird_spake2_process_their_point(handle, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        guard result == SpakeC.success else { throw Spake2Error.cryptoFailure }
    }

    /// Generate confirmation proofs (64 bytes)
    public func generateProofs() throws -> Data {
        guard let handle = handle else { throw Spake2Error.sessionNotCreated }

        var proofs = Data(count: 64)
        let result = proofs.withUnsafeMutableBytes { bytes in
            jetbird_spake2_generate_proofs(handle, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        guard result == SpakeC.success else { throw Spake2Error.cryptoFailure }
        return proofs
    }

    /// Verify peer's proofs
    public func verifyProofs(_ proofs: Data) throws -> Bool {
        guard let handle = handle else { throw Spake2Error.sessionNotCreated }
        guard proofs.count == 64 else { throw Spake2Error.invalidInput }

        let result = proofs.withUnsafeBytes { bytes in
            jetbird_spake2_verify_proofs(handle, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        return result == 1
    }

    /// Get derived session key (32 bytes)
    public func sessionKey() throws -> Data {
        guard let handle = handle else { throw Spake2Error.sessionNotCreated }

        var key = Data(count: 32)
        let result = key.withUnsafeMutableBytes { bytes in
            jetbird_spake2_session_key(handle, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        guard result == SpakeC.success else { throw Spake2Error.cryptoFailure }
        return key
    }

    /// Complete pairing flow: generate our point, process theirs, verify proofs
    /// Returns (ourPoint, sessionKey)
    public func completePairing(theirPoint: Data, theirProofs: Data) throws -> (ourPoint: Data, sessionKey: Data) {
        let ourPoint = try computeShare()
        try processTheirPoint(theirPoint)
        _ = try generateProofs()

        guard try verifyProofs(theirProofs) else {
            throw Spake2Error.verificationFailed
        }

        let key = try sessionKey()
        return (ourPoint, key)
    }
}

// MARK: - SPAKE2 Manager (High-level API)

/// High-level SPAKE2 pairing manager
public actor Spake2Manager {
    private var session: Spake2Session?
    private var pairingData: Spake2PairingData?

    public init() {}

    /// Start pairing as phone (client)
    /// - Parameters:
    ///   - code: 6-digit code from PS4
    ///   - pin: 16-byte PIN from QR code
    /// - Returns: Our public point to send to PS4
    public func startPairingAsPhone(code: UInt32, pin: Data) async throws -> Data {
        let session = try Spake2Session(role: .phone, code: code, pin: pin)
        let ourPoint = try session.computeShare()

        self.session = session
        self.pairingData = Spake2PairingData(
            code: code,
            pin: pin,
            scalar: Data(),  // Not stored for security
            ourPoint: ourPoint
        )

        return ourPoint
    }

    /// Start pairing as console (server) - for testing
    public func startPairingAsConsole(code: UInt32, pin: Data) async throws -> Data {
        let session = try Spake2Session(role: .console, code: code, pin: pin)
        let ourPoint = try session.computeShare()

        self.session = session
        self.pairingData = Spake2PairingData(
            code: code,
            pin: pin,
            scalar: Data(),
            ourPoint: ourPoint
        )

        return ourPoint
    }

    /// Complete pairing with peer's point and proofs
    /// - Parameters:
    ///   - theirPoint: 65-byte peer public point
    ///   - theirProofs: 64-byte peer confirmation proofs
    /// - Returns: Derived session key (32 bytes)
    public func completePairing(theirPoint: Data, theirProofs: Data) async throws -> Data {
        guard let session = session else { throw Spake2Error.sessionNotCreated }

        try session.processTheirPoint(theirPoint)
        let ourProofs = try session.generateProofs()

        guard try session.verifyProofs(theirProofs) else {
            throw Spake2Error.verificationFailed
        }

        let sessionKey = try session.sessionKey()

        // Update pairing data
        pairingData?.theirPoint = theirPoint
        pairingData?.sessionKey = sessionKey
        pairingData?.proofs = ourProofs

        return sessionKey
    }

    /// Get our public point
    public var ourPoint: Data? {
        pairingData?.ourPoint
    }

    /// Get pairing code
    public var code: UInt32? {
        pairingData?.code
    }

    /// Get session key if established
    public var sessionKey: Data? {
        pairingData?.sessionKey
    }

    /// Reset session
    public func reset() {
        session = nil
        pairingData = nil
    }
}

// MARK: - QR Code Helpers

extension Spake2Manager {
    /// Generate QR code data for pairing
    /// Format: "jetbird://pair?code=123456&pin=<base64>"
    public func generateQRCodeData() -> String? {
        guard let code = code,
              let pin = pairingData?.pin else { return nil }

        let pinBase64 = pin.base64EncodedString()
        return "jetbird://pair?code=\(code)&pin=\(pinBase64)"
    }

    /// Parse QR code data
    /// - Returns: (code, pin)
    public static func parseQRCode(_ string: String) -> (UInt32, Data)? {
        guard string.hasPrefix("jetbird://pair") else { return nil }

        guard let url = URL(string: string),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let codeString = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let code = UInt32(codeString),
              let pinString = components.queryItems?.first(where: { $0.name == "pin" })?.value,
              let pin = Data(base64Encoded: pinString),
              pin.count == 16 else { return nil }

        return (code, pin)
    }
}
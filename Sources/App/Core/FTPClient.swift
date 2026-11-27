//
//  FTPClient.swift
//  JetBird
//
//  Small FTP client (passive mode) for PS4 FTP servers such as the one in GoldHEN.
//

import Foundation
import Network

// MARK: - Types

struct FTPError: LocalizedError, Sendable {
    let message: String
    let code: Int?

    init(_ message: String, code: Int? = nil) {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }
}

struct FTPEntry: Identifiable, Hashable, Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: String

    var id: String { name }
}

enum FTPPath {
    static func join(_ base: String, _ name: String) -> String {
        if base.isEmpty || base == "/" { return "/" + name }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }

    static func parent(_ path: String) -> String {
        var parts = path.split(separator: "/").map { String($0) }
        if !parts.isEmpty { parts.removeLast() }
        return "/" + parts.joined(separator: "/")
    }
}

/// Sums up bytes over several files of one transfer.
final class FTPByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ amount: Int64) {
        lock.lock()
        stored += amount
        lock.unlock()
    }
}

// MARK: - Socket

final class FTPSocket: @unchecked Sendable {
    /// Makes sure exactly one of "result" or "timeout" resumes a continuation.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func complete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.jetbird.ftp.socket")

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let fallbackPort = NWEndpoint.Port(rawValue: 21)!
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? fallbackPort
        )
        connection = NWConnection(to: endpoint, using: parameters)
    }

    static func describe(_ error: NWError) -> FTPError {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return FTPError(L("The PS4 FTP server is not running or the port is wrong."))
        case .posix(let code) where code == .ETIMEDOUT || code == .EHOSTUNREACH:
            return FTPError(L("The PS4 did not respond. Check the IP address and the Wi-Fi network."))
        default:
            return FTPError(L("FTP connection error: %@", "\(error)"))
        }
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = Gate()

            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                if gate.complete() {
                    continuation.resume(throwing: FTPError(L("The PS4 did not respond. Check the IP address and the Wi-Fi network.")))
                    self?.connection.cancel()
                }
            }

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if gate.complete() { continuation.resume() }
                case .failed(let error):
                    if gate.complete() { continuation.resume(throwing: FTPSocket.describe(error)) }
                case .waiting(let error):
                    // The local-network permission prompt also shows up as "waiting"
                    if case .posix(let code) = error,
                       code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH {
                        if gate.complete() {
                            continuation.resume(throwing: FTPSocket.describe(error))
                            self?.connection.cancel()
                        }
                    }
                case .cancelled:
                    if gate.complete() {
                        continuation.resume(throwing: FTPError(L("The FTP connection was closed.")))
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
                    continuation.resume(throwing: FTPSocket.describe(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Returns nil when the other side closed the connection.
    func receive(max: Int, timeout: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let gate = Gate()

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if gate.complete() {
                    continuation.resume(throwing: FTPError(L("The PS4 FTP server stopped responding.")))
                    self?.connection.cancel()
                }
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                guard gate.complete() else { return }
                if let error = error {
                    continuation.resume(throwing: FTPSocket.describe(error))
                } else if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Sends FIN so the server sees the end of an upload.
    func finishSending() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func close() {
        connection.cancel()
    }
}

// MARK: - Client

struct FTPReply: Sendable {
    let code: Int
    let text: String
}

/// One FTP session (control connection). Use one operation at a time.
final class FTPClient: @unchecked Sendable {
    let host: String
    private let control: FTPSocket
    private var buffer = Data()
    private(set) var isClosed = false

    init(host: String, port: UInt16) {
        self.host = host
        control = FTPSocket(host: host, port: port)
    }

    // MARK: Session

    func connect(user: String, password: String) async throws {
        try await control.connect()
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw Self.error(for: greeting) }

        var reply = try await command("USER " + user)
        if reply.code == 331 || reply.code == 332 {
            reply = try await command("PASS " + password)
        }
        guard reply.code == 230 else {
            throw FTPError(L("The FTP server refused the login."), code: reply.code)
        }
        _ = try? await command("TYPE I")
    }

    func quit() async {
        if !isClosed { _ = try? await command("QUIT") }
        isClosed = true
        control.close()
    }

    // MARK: Control channel

    private func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                return line
            }
            do {
                guard let chunk = try await control.receive(max: 4096, timeout: 25) else {
                    isClosed = true
                    throw FTPError(L("The FTP connection was closed."))
                }
                buffer.append(chunk)
            } catch {
                isClosed = true
                throw error
            }
        }
    }

    private func readReply() async throws -> FTPReply {
        var lines: [String] = []
        var multilineCode: String?

        while true {
            let line = try await readLine()
            lines.append(line)
            guard line.count >= 3 else { continue }

            let prefix = String(line.prefix(3))
            guard let code = Int(prefix) else { continue }
            let separator: Character = line.count > 3 ? line[line.index(line.startIndex, offsetBy: 3)] : " "

            if let open = multilineCode {
                if prefix == open && separator == " " {
                    return FTPReply(code: code, text: lines.joined(separator: "\n"))
                }
            } else if separator == "-" {
                multilineCode = prefix
            } else {
                return FTPReply(code: code, text: lines.joined(separator: "\n"))
            }
        }
    }

    private func command(_ text: String) async throws -> FTPReply {
        do {
            try await control.send(Data((text + "\r\n").utf8))
        } catch {
            isClosed = true
            throw error
        }
        return try await readReply()
    }

    private static func error(for reply: FTPReply) -> FTPError {
        switch reply.code {
        case 530:
            return FTPError(L("The FTP server refused the login."), code: reply.code)
        case 550, 553:
            return FTPError(L("The PS4 refused the operation (file not found or no permission)."), code: reply.code)
        case 425, 426:
            return FTPError(L("The FTP data connection failed. Try again."), code: reply.code)
        default:
            let firstLine = reply.text.split(separator: "\n").first.map { String($0) } ?? ""
            return FTPError(L("FTP error %ld: %@", reply.code, firstLine), code: reply.code)
        }
    }

    // MARK: Data channel (passive mode)

    private func openDataConnection() async throws -> FTPSocket {
        let reply = try await command("PASV")
        guard reply.code == 227 else {
            throw FTPError(L("The FTP server does not support passive mode."), code: reply.code)
        }
        let digitsAndCommas = CharacterSet(charactersIn: "0123456789,")
        let tokens = reply.text.components(separatedBy: digitsAndCommas.inverted)
        guard let token = tokens.first(where: { $0.filter { $0 == "," }.count == 5 }) else {
            throw FTPError(L("The FTP server sent an invalid passive-mode reply."))
        }
        let numbers = token.split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 6 else {
            throw FTPError(L("The FTP server sent an invalid passive-mode reply."))
        }
        let port = numbers[4] * 256 + numbers[5]
        guard port > 0, port <= 65535 else {
            throw FTPError(L("The FTP server sent an invalid passive-mode reply."))
        }

        // Always connect to the address we already use (servers often report 0.0.0.0)
        let socket = FTPSocket(host: host, port: UInt16(port))
        try await socket.connect()
        return socket
    }

    // MARK: Navigation

    func pwd() async throws -> String {
        let reply = try await command("PWD")
        guard reply.code == 257 else { throw Self.error(for: reply) }
        let parts = reply.text.components(separatedBy: "\"")
        if parts.count >= 2, !parts[1].isEmpty { return parts[1] }
        return "/"
    }

    func cwd(_ path: String) async throws {
        let reply = try await command("CWD " + path)
        guard reply.code == 250 || reply.code == 200 else { throw Self.error(for: reply) }
    }

    func list() async throws -> [FTPEntry] {
        let data = try await openDataConnection()
        defer { data.close() }

        let start = try await command("LIST")
        guard start.code == 125 || start.code == 150 else { throw Self.error(for: start) }

        var raw = Data()
        while let chunk = try await data.receive(max: 65536, timeout: 30) {
            raw.append(chunk)
        }
        data.close()

        let end = try await readReply()
        guard end.code == 226 || end.code == 250 else { throw Self.error(for: end) }
        return Self.parseListing(String(decoding: raw, as: UTF8.self))
    }

    static func parseListing(_ text: String) -> [FTPEntry] {
        var result: [FTPEntry] = []
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for rawLine in lines {
            let line = String(rawLine)
            if line.hasPrefix("total") { continue }

            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count == 9, let kind = parts[0].first, "-dlscbp".contains(kind) else { continue }

            var name = String(parts[8])
            if kind == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            if name == "." || name == ".." || name.isEmpty { continue }

            let modified = "\(parts[5]) \(parts[6]) \(parts[7])"
            result.append(FTPEntry(
                name: name,
                isDirectory: kind == "d",
                size: Int64(parts[4]),
                modified: modified
            ))
        }
        return result
    }

    // MARK: Changes

    func delete(_ path: String) async throws {
        let reply = try await command("DELE " + path)
        guard reply.code == 250 else { throw Self.error(for: reply) }
    }

    func removeDirectory(_ path: String) async throws {
        let reply = try await command("RMD " + path)
        guard reply.code == 250 else { throw Self.error(for: reply) }
    }

    func makeDirectory(_ path: String) async throws {
        let reply = try await command("MKD " + path)
        guard reply.code == 257 || reply.code == 250 else { throw Self.error(for: reply) }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        let first = try await command("RNFR " + oldPath)
        guard first.code == 350 else { throw Self.error(for: first) }
        let second = try await command("RNTO " + newPath)
        guard second.code == 250 else { throw Self.error(for: second) }
    }

    func deleteRecursively(_ path: String) async throws {
        try await cwd(path)
        let items = try await list()
        for item in items {
            try Task.checkCancellation()
            let child = FTPPath.join(path, item.name)
            if item.isDirectory {
                try await deleteRecursively(child)
            } else {
                try await delete(child)
            }
        }
        try await cwd("/")
        try await removeDirectory(path)
    }

    // MARK: Transfers

    /// Returns the number of bytes received.
    @discardableResult
    func download(remote: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: local.path, contents: nil)
        let handle = try FileHandle(forWritingTo: local)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? fileManager.removeItem(at: local) }
        }

        let data = try await openDataConnection()
        defer { data.close() }

        let start = try await command("RETR " + remote)
        guard start.code == 125 || start.code == 150 else { throw Self.error(for: start) }

        var total: Int64 = 0
        while let chunk = try await data.receive(max: 262_144, timeout: 30) {
            try handle.write(contentsOf: chunk)
            total += Int64(chunk.count)
            progress(total)
            try Task.checkCancellation()
        }
        data.close()

        let end = try await readReply()
        guard end.code == 226 || end.code == 250 else { throw Self.error(for: end) }
        succeeded = true
        return total
    }

    func downloadDirectory(remote: String, to localDirectory: URL, counter: FTPByteCounter,
                           progress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        try await cwd(remote)
        let items = try await list()

        for item in items {
            try Task.checkCancellation()
            let childRemote = FTPPath.join(remote, item.name)
            let safeName = item.name.replacingOccurrences(of: "/", with: "_")
            let childLocal = localDirectory.appendingPathComponent(safeName)

            if item.isDirectory {
                try await downloadDirectory(remote: childRemote, to: childLocal, counter: counter, progress: progress)
            } else {
                let base = counter.value
                let received = try await download(remote: childRemote, to: childLocal) { done in
                    progress(base + done)
                }
                counter.add(received)
            }
        }
    }

    func upload(local: URL, remote: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }

        let data = try await openDataConnection()
        defer { data.close() }

        let start = try await command("STOR " + remote)
        guard start.code == 125 || start.code == 150 else { throw Self.error(for: start) }

        var sent: Int64 = 0
        while let chunk = try handle.read(upToCount: 262_144), !chunk.isEmpty {
            try await data.send(chunk)
            sent += Int64(chunk.count)
            progress(sent)
            try Task.checkCancellation()
        }
        await data.finishSending()
        data.close()

        let end = try await readReply()
        guard end.code == 226 || end.code == 250 else { throw Self.error(for: end) }
    }
}

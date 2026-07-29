import CryptoKit
import Foundation

// MARK: - Algorithms

/// The three checksums RomM publishes per file. RommpleTV validates every one
/// the server supplies: a hash the server sent and we ignored is a corruption we
/// chose not to catch.
public enum FileIntegrityAlgorithm: String, Sendable, Equatable, CaseIterable {
    case sha1
    case md5
    case crc32

    /// How many hexadecimal characters a well-formed digest has.
    public var hexadecimalLength: Int {
        switch self {
        case .sha1: return 40
        case .md5: return 32
        case .crc32: return 8
        }
    }

    /// Name for a message someone reads on a television.
    public var displayName: String {
        switch self {
        case .sha1: return "SHA-1"
        case .md5: return "MD5"
        case .crc32: return "CRC-32"
        }
    }
}

// MARK: - Errors

/// Every way a download can fail an integrity check. The cases are deliberately
/// fine-grained: each names the single rule that fired and carries what was
/// expected against what was seen, so a caller can explain the failure to
/// someone sitting on a couch and a test can pin one rule at a time.
public enum FileIntegrityError: Error, Equatable, Sendable, LocalizedError {

    /// Why a digest the *server* supplied is not a digest.
    public enum DigestProblem: String, Sendable {
        /// A non-nil empty string. The server said something; it just wasn't a
        /// checksum. That is not the same as sending no checksum at all.
        case empty
        /// Leading or trailing whitespace. Rejected rather than trimmed: a
        /// downloader that trims is a downloader that will one day accept
        /// something it should not have.
        case whitespace
        case wrongLength
        case nonHexadecimal
    }

    case malformedDigest(FileIntegrityAlgorithm, problem: DigestProblem)
    case negativeExpectedSize(Int64)
    case notAnHTTPResponse
    case httpStatus(Int)
    case bodyTooShort(expected: Int64, actual: Int64)
    /// The body ran past the expected size. `seenAtLeast` is what had arrived
    /// when the download was abandoned, which is one byte past `expected` — the
    /// overrun is refused on the byte that causes it, not after reading a body
    /// that may be arbitrarily large.
    case bodyTooLong(expected: Int64, seenAtLeast: Int64)
    case digestMismatch(FileIntegrityAlgorithm, expected: String, actual: String)
    /// Something that is not a regular file already occupies the part path — a
    /// directory, a symlink, a device node. Never followed, never replaced.
    case partPathBlocked(String)
    case partFileNotWritable(String)

    public var errorDescription: String? {
        switch self {
        case let .malformedDigest(algorithm, problem):
            let detail: String
            switch problem {
            case .empty:
                detail = "is empty"
            case .whitespace:
                detail = "has whitespace around it"
            case .wrongLength:
                detail = "is not \(algorithm.hexadecimalLength) characters long"
            case .nonHexadecimal:
                detail = "contains characters that are not hexadecimal"
            }
            return "The server's \(algorithm.displayName) checksum for this file \(detail), "
                + "so the download cannot be verified."
        case let .negativeExpectedSize(size):
            return "The server reported a negative size (\(size) bytes) for this file."
        case .notAnHTTPResponse:
            return "The server's reply to this download was not an HTTP response."
        case let .httpStatus(status):
            return "The server refused this download with HTTP status \(status)."
        case let .bodyTooShort(expected, actual):
            return "This download ended early: \(expected) bytes were expected, "
                + "\(actual) arrived."
        case let .bodyTooLong(expected, seenAtLeast):
            return "This download ran long: \(expected) bytes were expected, "
                + "at least \(seenAtLeast) arrived."
        case let .digestMismatch(algorithm, expected, actual):
            return "This download's \(algorithm.displayName) is \(actual), but the server said "
                + "\(expected), so the file was discarded."
        case let .partPathBlocked(name):
            return "Something that is not a file is already at \(name), "
                + "so this download has nowhere to go."
        case let .partFileNotWritable(name):
            return "RommpleTV could not create the download file \(name)."
        }
    }
}

// MARK: - CRC-32

/// Incremental IEEE CRC-32 (reflected polynomial `0xEDB88320`, initial and final
/// XOR `0xFFFFFFFF`) — the variant RomM's `crc_hash` uses, and the one whose
/// published check value over `"123456789"` is `0xCBF43926`.
struct CRC32 {
    /// Byte-at-a-time table, built once. Building a table is not computing a
    /// digest: the check values this is measured against come from the CRC
    /// catalogue, not from here.
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var state = self.state
        for byte in buffer {
            state = CRC32.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
        }
        self.state = state
    }

    var checksum: UInt32 { state ^ 0xFFFF_FFFF }
}

// MARK: - Digests

/// What a file actually turned out to be. Digests are lowercase hexadecimal of
/// the documented width — SHA-1 40 characters, MD5 32, CRC-32 8, zero-padded, so
/// a comparison against a normalized expectation is a plain string comparison.
public struct FileDigest: Equatable, Sendable {
    public let size: Int64
    public let sha1: String
    public let md5: String
    public let crc32: String
}

/// Hashes bytes as they go past.
///
/// Nothing here ever holds more than the caller's current chunk: the whole point
/// is that a 480 MB disc is digested on an Apple TV without a 480 MB buffer.
/// All three algorithms run over the same pass, because the alternative — three
/// passes over a file in the cache — is three chances for the system to purge it
/// underneath us.
public struct IncrementalFileDigest: Sendable {
    private var sha1 = Insecure.SHA1()
    private var md5 = Insecure.MD5()
    private var crc32 = CRC32()
    private var byteCount: Int64 = 0

    public init() {}

    public mutating func update<Bytes: DataProtocol>(_ bytes: Bytes) {
        sha1.update(data: bytes)
        md5.update(data: bytes)
        for region in bytes.regions {
            region.withUnsafeBytes { crc32.update($0) }
        }
        byteCount += Int64(bytes.count)
    }

    public func finalized() -> FileDigest {
        let crcBytes = withUnsafeBytes(of: crc32.checksum.bigEndian) { Array($0) }
        return FileDigest(size: byteCount,
                          sha1: Self.hexadecimal(sha1.finalize()),
                          md5: Self.hexadecimal(md5.finalize()),
                          crc32: Self.hexadecimal(crcBytes))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lowercase, two characters per byte, no leading zero suppression — MD5 of
    /// `"a"` starts `0c` and a CRC-32 of zero is `00000000`.
    private static func hexadecimal<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        var characters: [UInt8] = []
        characters.reserveCapacity(40)
        for byte in bytes {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}

// MARK: - What the server said the file is

/// The server's claim about one file, validated at construction.
///
/// The initializer throws, which is what makes "a malformed digest is rejected
/// before the download starts" structural rather than a matter of call order:
/// `StreamingFileDownloader.download` cannot be called without one of these, and
/// one of these cannot be built from a digest that is not a digest.
///
/// A non-nil malformed digest is an **error**, never a missing checksum. `nil`
/// means the server has no checksum of that kind; `""`, `"none"` and
/// `" da39…"` mean the server sent something this client does not understand,
/// and guessing which is which is how an unverified file gets treated as a
/// verified one.
public struct ExpectedFileIntegrity: Sendable, Equatable {
    public let size: Int64
    /// Normalized to lowercase hexadecimal, or nil when the server supplied none.
    public let sha1: String?
    public let md5: String?
    public let crc32: String?

    public init(size: Int64, sha1: String? = nil, md5: String? = nil,
                crc32: String? = nil) throws {
        guard size >= 0 else { throw FileIntegrityError.negativeExpectedSize(size) }
        self.size = size
        self.sha1 = try Self.normalized(sha1, as: .sha1)
        self.md5 = try Self.normalized(md5, as: .md5)
        self.crc32 = try Self.normalized(crc32, as: .crc32)
    }

    /// One file of a multi-file ROM, as RomM described it. This is the mapping
    /// from RomM's field names (`crc_hash`, `md5_hash`, `sha1_hash`) to the
    /// algorithms, in one place, so no caller has to get it right twice.
    public init(_ file: RomFile) throws {
        try self.init(size: file.sizeBytes, sha1: file.sha1Hash, md5: file.md5Hash,
                      crc32: file.crcHash)
    }

    /// A BIOS image, which carries the same three fields under a different size key.
    public init(_ firmware: RommFirmware) throws {
        try self.init(size: firmware.fileSizeBytes, sha1: firmware.sha1Hash,
                      md5: firmware.md5Hash, crc32: firmware.crcHash)
    }

    /// Checks the byte count and **every** supplied digest, in a fixed order
    /// (size, SHA-1, MD5, CRC-32) so a failure is reproducible. Absent digests
    /// are not checked; present ones always are.
    public func verify(_ digest: FileDigest) throws {
        guard digest.size == size else {
            throw digest.size < size
                ? FileIntegrityError.bodyTooShort(expected: size, actual: digest.size)
                : FileIntegrityError.bodyTooLong(expected: size, seenAtLeast: digest.size)
        }
        if let sha1, sha1 != digest.sha1 {
            throw FileIntegrityError.digestMismatch(.sha1, expected: sha1, actual: digest.sha1)
        }
        if let md5, md5 != digest.md5 {
            throw FileIntegrityError.digestMismatch(.md5, expected: md5, actual: digest.md5)
        }
        if let crc32, crc32 != digest.crc32 {
            throw FileIntegrityError.digestMismatch(.crc32, expected: crc32, actual: digest.crc32)
        }
    }

    /// The rules, in the order that produces the most useful message: emptiness,
    /// then padding, then length, then alphabet. Whitespace is checked before
    /// length because a padded digest can still be the right number of
    /// characters, and "there is a space in it" is a better answer than "it is
    /// the wrong length".
    private static func normalized(_ value: String?,
                                   as algorithm: FileIntegrityAlgorithm) throws -> String? {
        guard let value else { return nil }
        guard !value.isEmpty else {
            throw FileIntegrityError.malformedDigest(algorithm, problem: .empty)
        }
        if value.first!.isWhitespace || value.last!.isWhitespace {
            throw FileIntegrityError.malformedDigest(algorithm, problem: .whitespace)
        }
        guard value.count == algorithm.hexadecimalLength else {
            throw FileIntegrityError.malformedDigest(algorithm, problem: .wrongLength)
        }
        // ASCII hexadecimal only. `Character.isHexDigit` is true for full-width
        // and other Unicode digit forms, which are not what a digest is written in.
        let hexadecimal = value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
                || (0x61...0x66).contains(byte)
        }
        guard hexadecimal else {
            throw FileIntegrityError.malformedDigest(algorithm, problem: .nonHexadecimal)
        }
        return value.lowercased()
    }
}

// MARK: - The downloader

/// Streams one file to a `.part` file, hashing as it goes, and refuses anything
/// that does not match what the server said it was sending.
///
/// Contract, because Task 6's package store is built on it:
///
/// - The body is written to `partURL` **as it arrives**; at most
///   `bufferByteCount` bytes are ever held in memory, regardless of file size.
/// - On success the file is left at `partURL`. This downloader never renames:
///   promoting a verified part file to its final name is the caller's decision,
///   and that is what stops a purge or a crash from leaving something that looks
///   complete.
/// - On **any** failure — bad status, wrong size, wrong digest, transport error,
///   cancellation — a part file this call created is removed. A non-2xx status
///   is refused before the file is touched at all, so a part file left by an
///   earlier attempt survives a failed request rather than being truncated by it.
/// - No directories are created. The parent of `partURL` must exist; on the
///   PlayStation path it is made by `CueStaging.prepareDestination`, which
///   performs symlink checks this file deliberately does not duplicate.
public struct StreamingFileDownloader: Sendable {

    /// 64 KiB: large enough that the write syscall is not the bottleneck, small
    /// enough that a dozen concurrent transfers do not matter on an Apple TV.
    public static let defaultBufferByteCount = 64 << 10

    public let bufferByteCount: Int
    private let session: URLSession

    public init(session: URLSession = .shared,
                bufferByteCount: Int = StreamingFileDownloader.defaultBufferByteCount) {
        self.session = session
        self.bufferByteCount = max(1, bufferByteCount)
    }

    /// Fetches `request` into `partURL` and returns what the bytes turned out to
    /// be. Throws `FileIntegrityError` for every check this file owns, and
    /// `CancellationError` if the task is cancelled mid-body.
    ///
    /// `progress` reports cumulative bytes written. It is monotonic, never
    /// exceeds `expected.size`, and its last value is the final byte count.
    public func download(
        request: URLRequest,
        to partURL: URL,
        expected: ExpectedFileIntegrity,
        progress: @Sendable (Int64) -> Void
    ) async throws -> FileDigest {
        // `bytes(for:)` is the one await that sits outside the write loop, and
        // Foundation reports a cancellation here as `URLError.cancelled` rather
        // than `CancellationError`. A caller decides between "the player backed
        // out, say nothing" and "show a network error" on the error's type, so
        // that must not depend on whether the cancellation arrived before or
        // after the first byte. This is the request/header half of the same
        // normalization `write` does for the body.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        // Both refusals below abandon `bytes` without ever iterating it. That is
        // safe, and measured rather than assumed: `AsyncBytes` applies
        // backpressure by leaving its data task *suspended* until the iterator
        // asks for bytes, and Foundation stops the load when the un-iterated
        // sequence is deallocated. No body is fetched for a response that has
        // already been refused, so there is nothing here to cancel by hand.
        guard let http = response as? HTTPURLResponse else {
            throw FileIntegrityError.notAnHTTPResponse
        }
        // Before anything is written, and before a byte of the body is read.
        guard (200..<300).contains(http.statusCode) else {
            throw FileIntegrityError.httpStatus(http.statusCode)
        }
        return try await write(bytes, to: partURL, expected: expected, progress: progress)
    }

    /// The write loop, over any source of bytes.
    ///
    /// `URLSession.bytes(for:)` is one such source; the seam exists so the loop
    /// can be driven by a source that does not cooperate — one that never
    /// suspends at a cancellation point, or that refuses to produce its next
    /// block until the previous one is visible on disk. Neither claim this
    /// function makes about streaming or cancellation is testable through
    /// `URLSession` alone.
    func write<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        to partURL: URL,
        expected: ExpectedFileIntegrity,
        progress: @Sendable (Int64) -> Void
    ) async throws -> FileDigest where Bytes.Element == UInt8 {
        let handle = try Self.createPartFile(at: partURL)
        var digest = IncrementalFileDigest()
        var buffer = Data()
        buffer.reserveCapacity(bufferByteCount)
        var written: Int64 = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            digest.update(buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            progress(written)
        }

        do {
            for try await byte in bytes {
                buffer.append(byte)
                // Refuse the overrun on the byte that causes it: a hostile or
                // broken server must not be able to spend the whole cache.
                let seen = written + Int64(buffer.count)
                guard seen <= expected.size else {
                    throw FileIntegrityError.bodyTooLong(expected: expected.size, seenAtLeast: seen)
                }
                if buffer.count >= bufferByteCount {
                    // Between chunks, which is the only place a stream this
                    // long can be stopped without waiting for the server.
                    try Task.checkCancellation()
                    try flush()
                }
            }
            try Task.checkCancellation()
            try flush()
            if written == 0 { progress(0) }
            try handle.close()

            let result = digest.finalized()
            try expected.verify(result)
            return result
        } catch {
            try? handle.close()
            // Best effort: if the removal itself fails, the caller still sees why
            // the download failed rather than why the cleanup did, and the next
            // attempt truncates the file anyway.
            try? FileManager.default.removeItem(at: partURL)
            // Deliberate: once the task is cancelled, *any* error in flight is
            // reported as cancellation. A digest mismatch that races a cancel is
            // therefore lost. That is the right trade — the file is deleted
            // either way, nothing is promoted, and a caller that has just said
            // "stop" should not be shown a verification error for a transfer it
            // abandoned.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Opens `partURL` for writing, truncating whatever an abandoned earlier
    /// attempt left there. Refuses to write through anything that is not a plain
    /// file: `attributesOfItem` does not follow a final symlink, so a link
    /// planted at the part path is seen as a link rather than as its target.
    private static func createPartFile(at partURL: URL) throws -> FileHandle {
        let manager = FileManager.default
        let name = partURL.lastPathComponent
        if let attributes = try? manager.attributesOfItem(atPath: partURL.path),
           let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw FileIntegrityError.partPathBlocked(name)
        }
        guard manager.createFile(atPath: partURL.path, contents: nil) else {
            throw FileIntegrityError.partFileNotWritable(name)
        }
        guard let handle = try? FileHandle(forWritingTo: partURL) else {
            try? manager.removeItem(at: partURL)
            throw FileIntegrityError.partFileNotWritable(name)
        }
        return handle
    }
}

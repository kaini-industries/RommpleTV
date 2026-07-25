import XCTest
import Foundation
@testable import RommpleTVKit

// MARK: - Known-answer vectors
//
// Every digest expectation in this file is a *published* value transcribed from a
// standards document or a reference implementation's own published check value.
// Nothing here is produced by `FileIntegrity.swift`, because a digest test that
// computes its expectation with the code it is testing proves only that the code
// agrees with itself.
//
//   SHA-1   — FIPS 180-2 Appendix A ("abc", the 56-byte two-block message, and
//             the one-million-'a' message) and the universally published digest
//             of the empty string.
//   MD5     — RFC 1321 Appendix A.5 "MD5 test suite", verbatim, plus the
//             one-million-'a' and pangram values published alongside them.
//   CRC-32  — the CRC catalogue check value for CRC-32/ISO-HDLC (`"123456789"`
//             → 0xCBF43926) plus the widely published short-string and
//             all-zero/all-ones/counting-bytes vectors for the same parameters
//             (poly 0xEDB88320 reflected, init and final XOR 0xFFFFFFFF).
//
// Transcription was checked against Python's `hashlib`/`zlib` — independent
// implementations, used to confirm the values were copied correctly, not to
// derive them.

private enum Vector {
    static let emptySHA1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
    static let emptyMD5 = "d41d8cd98f00b204e9800998ecf8427e"
    static let emptyCRC32 = "00000000"

    /// "The quick brown fox jumps over the lazy dog" — 43 bytes, all three digests
    /// published. Used as the body of most downloader tests.
    static let fox = Data("The quick brown fox jumps over the lazy dog".utf8)
    static let foxSHA1 = "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12"
    static let foxMD5 = "9e107d9d372bb6826bd81d3542a419d6"
    static let foxCRC32 = "414fa339"
    static let foxSize = Int64(43)

    /// FIPS 180-2's third SHA-1 example: 1,000,000 repetitions of 'a'.
    static let millionA = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
    static let millionASHA1 = "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
    static let millionAMD5 = "7707d6ae4e027c70eea2a935c2296f21"
    /// Not from a standards document: this is zlib's `crc32` of the same message,
    /// recorded here so the long-input CRC path has a fixed expectation. The
    /// short CRC vectors above are the published ones.
    static let millionACRC32 = "dc25bfbc"
}

// MARK: - Scripted response body

/// A `URLProtocol` that replays a response body in explicit chunks from its own
/// queue, so a test can inspect the world *between* chunks — in particular how
/// many bytes have reached the `.part` file while the body is still arriving.
final class ScriptedBodyProtocol: URLProtocol {

    struct Script: @unchecked Sendable {
        var status = 200
        var chunks: [Data] = []
        /// Deliver a plain `URLResponse` rather than an `HTTPURLResponse`.
        var nonHTTPResponse = false
        /// Runs on the sending queue immediately before chunk `index` goes out.
        /// Returning `false` abandons the rest of the body.
        var beforeChunk: (@Sendable (_ index: Int) -> Bool)?
        /// Fail the body with this error instead of finishing it.
        var failure: URLError.Code?
        /// Accept the request and then say nothing at all — no response, no
        /// body, no completion. Parks a caller inside `bytes(for:)`.
        var stall = false
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var _script = Script()
    nonisolated(unsafe) private static var _startedRequests = 0

    static var script: Script {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _script }
        set { stateLock.lock(); _script = newValue; stateLock.unlock() }
    }

    /// How many requests reached the loading system since `reset()`.
    static var startedRequests: Int {
        stateLock.lock(); defer { stateLock.unlock() }; return _startedRequests
    }

    static func reset() {
        stateLock.lock(); _script = Script(); _startedRequests = 0; stateLock.unlock()
    }

    static func session(_ script: Script) -> URLSession {
        reset()
        self.script = script
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedBodyProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let instanceLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { instanceLock.lock(); defer { instanceLock.unlock() }; return stopped }

    private static let queue = DispatchQueue(label: "ScriptedBodyProtocol")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock(); Self._startedRequests += 1; Self.stateLock.unlock()
        let script = Self.script
        guard !script.stall else { return }
        Self.queue.async {
            if script.nonHTTPResponse {
                let response = URLResponse(url: self.request.url!,
                                           mimeType: "application/octet-stream",
                                           expectedContentLength: -1, textEncodingName: nil)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            } else {
                let response = HTTPURLResponse(url: self.request.url!, statusCode: script.status,
                                               httpVersion: "HTTP/1.1", headerFields: nil)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            for (index, chunk) in script.chunks.enumerated() {
                if self.isStopped { return }
                if let gate = script.beforeChunk, !gate(index) { break }
                if self.isStopped { return }
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            if self.isStopped { return }
            if let failure = script.failure {
                self.client?.urlProtocol(self, didFailWithError: URLError(failure))
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        instanceLock.lock(); stopped = true; instanceLock.unlock()
    }
}

// MARK: - Injected byte sources

/// A pull-based byte source that reports what it has handed out at each block
/// boundary.
///
/// Nothing is produced until the downloader asks for it, so when the downloader
/// asks for the first byte of block *i* it has already consumed blocks `0..<i`.
/// A downloader that streams has therefore already written them; one that
/// buffers the whole body has written nothing. The observation is exact and
/// synchronous — no timeouts, no sleeps, no timing assumptions, and no way for
/// the test to hang.
struct BlockSource: AsyncSequence {
    typealias Element = UInt8

    let blocks: [[UInt8]]
    /// `(block index, bytes handed out so far)`, called before the first byte of
    /// each block leaves the source. Returning an error throws it in place of
    /// the block, which is how a source imitates a connection dropping.
    let atBlockBoundary: @Sendable (Int, Int64) -> Error?

    struct AsyncIterator: AsyncIteratorProtocol {
        let blocks: [[UInt8]]
        let atBlockBoundary: @Sendable (Int, Int64) -> Error?
        var blockIndex = 0
        var byteIndex = 0
        var produced: Int64 = 0

        mutating func next() async throws -> UInt8? {
            while blockIndex < blocks.count {
                if byteIndex == 0, let error = atBlockBoundary(blockIndex, produced) { throw error }
                let block = blocks[blockIndex]
                if byteIndex < block.count {
                    defer { byteIndex += 1; produced += 1 }
                    return block[byteIndex]
                }
                blockIndex += 1
                byteIndex = 0
            }
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(blocks: blocks, atBlockBoundary: atBlockBoundary)
    }
}

/// Somewhere to publish the download's `Task` handle to a byte source that wants
/// to cancel it mid-body.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<FileDigest, Error>?
    private(set) var cancelled = false

    func publish(_ task: Task<FileDigest, Error>) { lock.lock(); self.task = task; lock.unlock() }

    /// Cancels the published task, waiting up to `seconds` for it to be
    /// published. Returns false if it never was, so the test fails loudly
    /// instead of racing.
    func cancelPublishedTask(waitingUpTo seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock(); let task = self.task; lock.unlock()
            if let task {
                task.cancel()
                lock.lock(); cancelled = true; lock.unlock()
                return true
            }
            usleep(500)
        }
        return false
    }
}

// MARK: - File helpers usable from any thread

private func sizeOfFile(at url: URL) -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber else { return -1 }
    return size.int64Value
}

private func fileExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Polls `condition` until it holds or the deadline passes. Used only where the
/// producer and the consumer are genuinely on different threads.
private func waitUntil(_ seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(500)
    }
    return condition()
}

/// A thread-safe list of observations made from a stub's queue.
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - Tests

/// Digest correctness is pinned with published vectors; the downloader's rules
/// are pinned one at a time, each with its own named test, so a weakened rule
/// fails a test that names it.
///
/// All file and disc names here are synthetic.
final class FileIntegrityTests: XCTestCase {

    private var directory: URL!
    private var part: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileIntegrityTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        part = directory.appendingPathComponent("disc (Track 01).bin.part", isDirectory: false)
        ScriptedBodyProtocol.reset()
    }

    override func tearDownWithError() throws {
        ScriptedBodyProtocol.reset()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private static let requestURL = URL(string: "https://example.invalid/api/roms/1/files/content/x")!

    private func request() -> URLRequest { URLRequest(url: Self.requestURL) }

    private func digest(of data: Data, chunkedInto chunkSize: Int? = nil) -> FileDigest {
        var incremental = IncrementalFileDigest()
        if let chunkSize {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                incremental.update(data[data.startIndex + offset..<data.startIndex + end])
                offset = end
            }
        } else {
            incremental.update(data)
        }
        return incremental.finalized()
    }

    /// Re-reads a file from disk and digests it, so a returned `FileDigest` can
    /// be checked against the bytes that actually landed rather than against the
    /// downloader's own account of them. Task 6 promotes a `.part` file on the
    /// strength of the returned digest without re-reading it, so "the digest
    /// describes the file" is a claim that has to be tested, not assumed.
    private func digestOfFile(at url: URL, readingIn chunkSize: Int = 64 << 10) throws -> FileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var incremental = IncrementalFileDigest()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            incremental.update(chunk)
        }
        return incremental.finalized()
    }

    private func assertMalformed(
        _ expression: @autoclosure () throws -> ExpectedFileIntegrity,
        _ expected: FileIntegrityError,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let value = try expression()
            XCTFail("expected \(expected) \(message); built \(value)", file: file, line: line)
        } catch let error as FileIntegrityError {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        } catch {
            XCTFail("expected FileIntegrityError, got \(error)", file: file, line: line)
        }
    }

    /// Runs one download against a scripted body and returns the result or the error.
    private func runDownload(
        status: Int = 200,
        body: Data,
        chunkSize: Int? = nil,
        nonHTTPResponse: Bool = false,
        failure: URLError.Code? = nil,
        expected: ExpectedFileIntegrity,
        bufferByteCount: Int = StreamingFileDownloader.defaultBufferByteCount,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async -> Result<FileDigest, Error> {
        var chunks: [Data] = []
        if let chunkSize, !body.isEmpty {
            var offset = 0
            while offset < body.count {
                let end = min(offset + chunkSize, body.count)
                chunks.append(body[body.startIndex + offset..<body.startIndex + end])
                offset = end
            }
        } else if !body.isEmpty {
            chunks = [body]
        }
        let session = ScriptedBodyProtocol.session(
            .init(status: status, chunks: chunks, nonHTTPResponse: nonHTTPResponse, failure: failure))
        let downloader = StreamingFileDownloader(session: session, bufferByteCount: bufferByteCount)
        let report = progress ?? { _ in }
        do {
            return .success(try await downloader.download(request: request(), to: part,
                                                          expected: expected, progress: report))
        } catch {
            return .failure(error)
        }
    }

    private func assertIntegrityError(
        _ result: Result<FileDigest, Error>, _ expected: FileIntegrityError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case let .success(digest):
            XCTFail("expected \(expected), download succeeded with \(digest)", file: file, line: line)
        case let .failure(error):
            guard let error = error as? FileIntegrityError else {
                return XCTFail("expected FileIntegrityError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - SHA-1, MD5, CRC-32 against published vectors

    func testSHA1MatchesPublishedVectors() {
        let vectors: [(String, String)] = [
            ("", Vector.emptySHA1),
            ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
            ("The quick brown fox jumps over the lazy dog", Vector.foxSHA1),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(digest(of: Data(input.utf8)).sha1, expected, "SHA-1 of \"\(input)\"")
        }
    }

    func testMD5MatchesPublishedVectors() {
        // RFC 1321 Appendix A.5, in order, plus the pangram.
        let vectors: [(String, String)] = [
            ("", Vector.emptyMD5),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
             "d174ab98d277d9f5a5611c2c9f419d9f"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a"),
            ("The quick brown fox jumps over the lazy dog", Vector.foxMD5),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(digest(of: Data(input.utf8)).md5, expected, "MD5 of \"\(input)\"")
        }
    }

    func testCRC32MatchesPublishedVectors() {
        let textVectors: [(String, String)] = [
            ("", Vector.emptyCRC32),
            ("a", "e8b7be43"),
            ("abc", "352441c2"),
            ("123456789", "cbf43926"),      // the CRC-32/ISO-HDLC catalogue check value
            ("abcdefghijklmnopqrstuvwxyz", "4c2750bd"),
            ("The quick brown fox jumps over the lazy dog", Vector.foxCRC32),
        ]
        for (input, expected) in textVectors {
            XCTAssertEqual(digest(of: Data(input.utf8)).crc32, expected, "CRC-32 of \"\(input)\"")
        }

        let byteVectors: [([UInt8], String)] = [
            ([UInt8](repeating: 0x00, count: 32), "190a55ad"),
            ([UInt8](repeating: 0xFF, count: 32), "ff6cab0b"),
            ((0..<32).map { UInt8($0) }, "91267e8a"),
        ]
        for (input, expected) in byteVectors {
            XCTAssertEqual(digest(of: Data(input)).crc32, expected, "CRC-32 of \(input.count) bytes")
        }
    }

    /// The empty message pins zero-padding as well as emptiness: a CRC-32 of zero
    /// must be eight characters, not "0", and a digest hex encoder that strips
    /// leading zeros would fail here and on MD5("a") = "0cc1...".
    func testDigestsAreLowercaseHexadecimalOfTheDocumentedWidth() {
        let empty = digest(of: Data())
        XCTAssertEqual(empty.sha1, Vector.emptySHA1)
        XCTAssertEqual(empty.md5, Vector.emptyMD5)
        XCTAssertEqual(empty.crc32, "00000000")
        XCTAssertEqual(empty.crc32.count, 8)
        XCTAssertEqual(empty.sha1.count, 40)
        XCTAssertEqual(empty.md5.count, 32)
        XCTAssertEqual(empty.size, 0)
        XCTAssertEqual(digest(of: Data("a".utf8)).md5, "0cc175b9c0f1b6a831c399e269772661")
    }

    /// Feeding a published vector one byte at a time must produce the published
    /// answer, which is what "incremental" has to mean.
    func testPublishedVectorsSurviveBeingFedOneByteAtATime() {
        let oneAtATime = digest(of: Vector.fox, chunkedInto: 1)
        XCTAssertEqual(oneAtATime.sha1, Vector.foxSHA1)
        XCTAssertEqual(oneAtATime.md5, Vector.foxMD5)
        XCTAssertEqual(oneAtATime.crc32, Vector.foxCRC32)
        XCTAssertEqual(oneAtATime.size, Vector.foxSize)

        // Awkward split sizes straddle every internal block boundary of both
        // hash functions (SHA-1 and MD5 both consume 64-byte blocks).
        for chunkSize in [1, 3, 7, 64, 65] {
            let split = digest(of: Vector.fox, chunkedInto: chunkSize)
            XCTAssertEqual(split.sha1, Vector.foxSHA1, "chunk size \(chunkSize)")
            XCTAssertEqual(split.md5, Vector.foxMD5, "chunk size \(chunkSize)")
            XCTAssertEqual(split.crc32, Vector.foxCRC32, "chunk size \(chunkSize)")
        }
    }

    /// FIPS 180-2's one-million-'a' message, fed in 64 KiB slices: the only
    /// vector here big enough that a "hash the whole file at once" implementation
    /// would be a real memory problem on the target device.
    func testMillionCharacterVectorHashesInSlices() {
        let sliced = digest(of: Vector.millionA, chunkedInto: 64 << 10)
        XCTAssertEqual(sliced.size, 1_000_000)
        XCTAssertEqual(sliced.sha1, Vector.millionASHA1)
        XCTAssertEqual(sliced.md5, Vector.millionAMD5)
        XCTAssertEqual(sliced.crc32, Vector.millionACRC32)
        // Same message, one update: the answer cannot depend on the slicing.
        XCTAssertEqual(digest(of: Vector.millionA), sliced)
    }

    func testByteCountCountsEveryByteIncludingNULs() {
        XCTAssertEqual(digest(of: Data()).size, 0)
        XCTAssertEqual(digest(of: Data([0x00])).size, 1)
        XCTAssertEqual(digest(of: Data(repeating: 0x00, count: 4096)).size, 4096)
        XCTAssertEqual(digest(of: Vector.fox).size, 43)
        XCTAssertEqual(digest(of: Vector.millionA, chunkedInto: 997).size, 1_000_000)
    }

    // MARK: - Expected integrity: malformed digests die at construction

    func testAbsentDigestsAreNil() throws {
        let expected = try ExpectedFileIntegrity(size: 43)
        XCTAssertEqual(expected.size, 43)
        XCTAssertNil(expected.sha1)
        XCTAssertNil(expected.md5)
        XCTAssertNil(expected.crc32)
    }

    func testUppercaseDigestsAreNormalizedToLowercase() throws {
        let expected = try ExpectedFileIntegrity(
            size: Vector.foxSize,
            sha1: Vector.foxSHA1.uppercased(),
            md5: Vector.foxMD5.uppercased(),
            crc32: Vector.foxCRC32.uppercased())
        XCTAssertEqual(expected.sha1, Vector.foxSHA1)
        XCTAssertEqual(expected.md5, Vector.foxMD5)
        XCTAssertEqual(expected.crc32, Vector.foxCRC32)
    }

    /// A server that spells a digest in mixed case must still verify, which is
    /// the point of normalizing rather than comparing raw strings.
    func testMixedCaseDigestsStillVerify() async throws {
        let expected = try ExpectedFileIntegrity(
            size: Vector.foxSize,
            sha1: "2FD4e1c67a2d28fCED849ee1bb76e7391B93eb12",
            md5: "9E107D9d372bb6826bd81d3542a419d6",
            crc32: "414FA339")
        let result = await runDownload(body: Vector.fox, expected: expected)
        XCTAssertEqual(try result.get().sha1, Vector.foxSHA1)
    }

    func testWrongLengthDigestsAreRejected() {
        assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: String(Vector.foxSHA1.dropLast())),
                        .malformedDigest(.sha1, problem: .wrongLength), "39 characters")
        assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: Vector.foxSHA1 + "0"),
                        .malformedDigest(.sha1, problem: .wrongLength), "41 characters")
        assertMalformed(try ExpectedFileIntegrity(size: 1, md5: String(Vector.foxMD5.dropLast())),
                        .malformedDigest(.md5, problem: .wrongLength), "31 characters")
        assertMalformed(try ExpectedFileIntegrity(size: 1, md5: Vector.foxMD5 + "0"),
                        .malformedDigest(.md5, problem: .wrongLength), "33 characters")
        assertMalformed(try ExpectedFileIntegrity(size: 1, crc32: String(Vector.foxCRC32.dropLast())),
                        .malformedDigest(.crc32, problem: .wrongLength), "7 characters")
        assertMalformed(try ExpectedFileIntegrity(size: 1, crc32: Vector.foxCRC32 + "0"),
                        .malformedDigest(.crc32, problem: .wrongLength), "9 characters")
        // An MD5-length value in the SHA-1 field is not a SHA-1.
        assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: Vector.foxMD5),
                        .malformedDigest(.sha1, problem: .wrongLength), "MD5 in the SHA-1 field")
    }

    func testNonHexadecimalDigestsAreRejected() {
        // Right length, wrong alphabet — the case a length check alone would miss.
        assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: String(repeating: "g", count: 40)),
                        .malformedDigest(.sha1, problem: .nonHexadecimal))
        assertMalformed(try ExpectedFileIntegrity(size: 1, md5: String(repeating: "z", count: 32)),
                        .malformedDigest(.md5, problem: .nonHexadecimal))
        assertMalformed(try ExpectedFileIntegrity(size: 1, crc32: "0x414fa3"),
                        .malformedDigest(.crc32, problem: .nonHexadecimal), "0x prefix")
        assertMalformed(try ExpectedFileIntegrity(size: 1, crc32: "414-a339"),
                        .malformedDigest(.crc32, problem: .nonHexadecimal))
        // An interior space keeps the length right and the alphabet wrong.
        let interiorSpace = "2fd4e1c67a2d28fced849ee1bb 6e7391b93eb12"
        XCTAssertEqual(interiorSpace.count, 40)
        assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: interiorSpace),
                        .malformedDigest(.sha1, problem: .nonHexadecimal), "interior space")
        // Non-ASCII digits that `isHexDigit` would accept if it were asked about
        // Unicode rather than ASCII.
        assertMalformed(try ExpectedFileIntegrity(size: 1, crc32: "41４fa339"),
                        .malformedDigest(.crc32, problem: .nonHexadecimal), "full-width digit")
    }

    /// Whitespace is rejected, not trimmed. A trimming implementation would
    /// accept every one of these.
    func testWhitespacePaddedDigestsAreRejected() {
        for padded in [" " + Vector.foxSHA1, Vector.foxSHA1 + " ", "\t" + Vector.foxSHA1,
                       Vector.foxSHA1 + "\n", Vector.foxSHA1 + "\r\n", "\u{00A0}" + Vector.foxSHA1] {
            assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: padded),
                            .malformedDigest(.sha1, problem: .whitespace),
                            "padded SHA-1 of \(padded.count) characters")
        }
        assertMalformed(try ExpectedFileIntegrity(size: 1, md5: " " + Vector.foxMD5),
                        .malformedDigest(.md5, problem: .whitespace))
        assertMalformed(try ExpectedFileIntegrity(size: 1, crc32: Vector.foxCRC32 + "\n"),
                        .malformedDigest(.crc32, problem: .whitespace))
        // The sneaky one: 40 characters in total, one of them a leading space, so
        // a length check passes and only the whitespace rule fires.
        let fortyWithSpace = " " + String(Vector.foxSHA1.dropLast())
        XCTAssertEqual(fortyWithSpace.count, 40)
        assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: fortyWithSpace),
                        .malformedDigest(.sha1, problem: .whitespace), "right length, padded")
        // Whitespace only.
        assertMalformed(try ExpectedFileIntegrity(size: 1, md5: String(repeating: " ", count: 32)),
                        .malformedDigest(.md5, problem: .whitespace))
    }

    /// An empty string is a value the server sent, not an absent checksum.
    func testEmptyDigestStringsAreRejectedRatherThanTreatedAsAbsent() {
        assertMalformed(try ExpectedFileIntegrity(size: 1, sha1: ""),
                        .malformedDigest(.sha1, problem: .empty))
        assertMalformed(try ExpectedFileIntegrity(size: 1, md5: ""),
                        .malformedDigest(.md5, problem: .empty))
        assertMalformed(try ExpectedFileIntegrity(size: 1, crc32: ""),
                        .malformedDigest(.crc32, problem: .empty))
    }

    func testNegativeExpectedSizeIsRejected() {
        assertMalformed(try ExpectedFileIntegrity(size: -1), .negativeExpectedSize(-1))
    }

    /// "Before the download starts" is structural, not a matter of call order:
    /// `download` cannot be called without an `ExpectedFileIntegrity`, and one
    /// cannot be built from a malformed digest.
    func testMalformedDigestIsRejectedBeforeAnyRequestIsMade() async {
        let session = ScriptedBodyProtocol.session(.init(status: 200, chunks: [Vector.fox]))
        let downloader = StreamingFileDownloader(session: session)

        var built: ExpectedFileIntegrity?
        do {
            built = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                              md5: Vector.foxMD5, crc32: "not hex")
        } catch {
            built = nil
        }
        XCTAssertNil(built, "a malformed CRC-32 must not produce an expectation")

        if let built {   // never taken; present so the downloader is genuinely unused above
            _ = try? await downloader.download(request: request(), to: part,
                                               expected: built, progress: { _ in })
        }
        XCTAssertEqual(ScriptedBodyProtocol.startedRequests, 0, "no request may be issued")
        XCTAssertFalse(fileExists(at: part), "no part file may be created")
    }

    func testExpectedIntegrityFromARomFileCarriesEveryServerHash() throws {
        let file = RomFile(id: 7, fileName: "disc (Track 01).bin", filePath: "psx/Vault Runner",
                           sizeBytes: Vector.foxSize, isTopLevel: true,
                           crcHash: Vector.foxCRC32.uppercased(), md5Hash: Vector.foxMD5,
                           sha1Hash: Vector.foxSHA1, updatedAt: "2026-01-01T00:00:00")
        let expected = try ExpectedFileIntegrity(file)
        XCTAssertEqual(expected, try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                                          md5: Vector.foxMD5, crc32: Vector.foxCRC32))
    }

    func testExpectedIntegrityFromARomFileRejectsAMalformedServerHash() {
        let file = RomFile(id: 7, fileName: "disc (Track 01).bin", filePath: "psx/Vault Runner",
                           sizeBytes: Vector.foxSize, isTopLevel: true,
                           crcHash: "zzzzzzzz", md5Hash: nil, sha1Hash: nil,
                           updatedAt: "2026-01-01T00:00:00")
        assertMalformed(try ExpectedFileIntegrity(file),
                        .malformedDigest(.crc32, problem: .nonHexadecimal))
    }

    func testExpectedIntegrityFromFirmwareCarriesEveryServerHash() throws {
        let firmware = RommFirmware(id: 3, fileName: "psx-bios.bin", fileSizeBytes: Vector.foxSize,
                                    isVerified: true, crcHash: Vector.foxCRC32,
                                    md5Hash: Vector.foxMD5, sha1Hash: Vector.foxSHA1,
                                    missingFromFS: false, updatedAt: "2026-01-01T00:00:00")
        let expected = try ExpectedFileIntegrity(firmware)
        XCTAssertEqual(expected, try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                                          md5: Vector.foxMD5, crc32: Vector.foxCRC32))
    }

    // MARK: - Verification against a computed digest

    func testVerifyAcceptsAMatchingDigest() throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                                 md5: Vector.foxMD5, crc32: Vector.foxCRC32)
        XCTAssertNoThrow(try expected.verify(digest(of: Vector.fox)))
    }

    /// Each supplied hash is checked on its own: with the other two correct, a
    /// wrong one must still fail. An implementation that only checked the
    /// strongest hash would pass the SHA-1 case and fail these.
    func testEachSuppliedHashIsVerifiedIndependently() throws {
        let wrongSHA1 = String(repeating: "0", count: 40)
        let wrongMD5 = String(repeating: "0", count: 32)
        let wrongCRC32 = "00000000"
        let actual = digest(of: Vector.fox)

        let badSHA1 = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: wrongSHA1,
                                                md5: Vector.foxMD5, crc32: Vector.foxCRC32)
        XCTAssertThrowsError(try badSHA1.verify(actual)) {
            XCTAssertEqual($0 as? FileIntegrityError,
                           .digestMismatch(.sha1, expected: wrongSHA1, actual: Vector.foxSHA1))
        }

        let badMD5 = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                               md5: wrongMD5, crc32: Vector.foxCRC32)
        XCTAssertThrowsError(try badMD5.verify(actual)) {
            XCTAssertEqual($0 as? FileIntegrityError,
                           .digestMismatch(.md5, expected: wrongMD5, actual: Vector.foxMD5))
        }

        let badCRC = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                               md5: Vector.foxMD5, crc32: wrongCRC32)
        XCTAssertThrowsError(try badCRC.verify(actual)) {
            XCTAssertEqual($0 as? FileIntegrityError,
                           .digestMismatch(.crc32, expected: wrongCRC32, actual: Vector.foxCRC32))
        }
    }

    func testVerifyChecksTheByteCount() throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize + 1, sha1: Vector.foxSHA1)
        XCTAssertThrowsError(try expected.verify(digest(of: Vector.fox))) {
            XCTAssertEqual($0 as? FileIntegrityError,
                           .bodyTooShort(expected: Vector.foxSize + 1, actual: Vector.foxSize))
        }
    }

    func testAbsentHashesAreNotChecked() throws {
        let sizeOnly = try ExpectedFileIntegrity(size: Vector.foxSize)
        XCTAssertNoThrow(try sizeOnly.verify(digest(of: Vector.fox)))
    }

    // MARK: - Download: the happy path

    func testDownloadWritesTheBodyToThePartFileAndReturnsItsDigest() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                                 md5: Vector.foxMD5, crc32: Vector.foxCRC32)
        let result = await runDownload(body: Vector.fox, chunkSize: 7, expected: expected)
        let digest = try result.get()

        XCTAssertEqual(digest.size, Vector.foxSize)
        XCTAssertEqual(digest.sha1, Vector.foxSHA1)
        XCTAssertEqual(digest.md5, Vector.foxMD5)
        XCTAssertEqual(digest.crc32, Vector.foxCRC32)
        XCTAssertEqual(try Data(contentsOf: part), Vector.fox)
    }

    /// The downloader hands back a `.part` file and nothing else: promoting it to
    /// its final name is the caller's decision, so an interrupted run can never
    /// leave something that looks complete.
    func testDownloadLeavesTheFileAtThePartPathAndCreatesNothingElse() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1)
        _ = try await runDownload(body: Vector.fox, expected: expected).get()

        let contents = try FileManager.default
            .contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(contents, [part.lastPathComponent])
    }

    func testDownloadOfAnEmptyBodyProducesTheEmptyMessageVectors() async throws {
        let expected = try ExpectedFileIntegrity(size: 0, sha1: Vector.emptySHA1,
                                                 md5: Vector.emptyMD5, crc32: Vector.emptyCRC32)
        let digest = try await runDownload(body: Data(), expected: expected).get()
        XCTAssertEqual(digest.size, 0)
        XCTAssertEqual(digest.sha1, Vector.emptySHA1)
        XCTAssertEqual(try Data(contentsOf: part), Data())
    }

    /// A purged cache leaves stale `.part` files behind. The next attempt must
    /// overwrite one, not append to it.
    func testAStalePartFileIsTruncatedRatherThanAppendedTo() async throws {
        try Data(repeating: 0xAB, count: 200_000).write(to: part)
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                                 md5: Vector.foxMD5, crc32: Vector.foxCRC32)
        let digest = try await runDownload(body: Vector.fox, expected: expected).get()
        XCTAssertEqual(digest.sha1, Vector.foxSHA1)
        XCTAssertEqual(try Data(contentsOf: part), Vector.fox)
        XCTAssertEqual(sizeOfFile(at: part), Vector.foxSize)
    }

    /// End to end: a megabyte body, streamed through `URLSession`, hashed
    /// incrementally, checked against the published one-million-'a' vectors —
    /// and then checked against the file that is actually on disk.
    ///
    /// The last part matters more than it looks. Every other body whose
    /// *contents* are asserted here is smaller than one buffer, so it is written
    /// by the single post-loop flush. Without this, an implementation that
    /// re-wrote the first buffer each time, or wrote at the wrong offset, would
    /// produce a file of the right length and the wrong bytes and hand back a
    /// digest saying it was fine.
    func testDownloadOfTheMillionCharacterVectorMatchesThePublishedDigests() async throws {
        let expected = try ExpectedFileIntegrity(size: 1_000_000, sha1: Vector.millionASHA1,
                                                 md5: Vector.millionAMD5, crc32: Vector.millionACRC32)
        let digest = try await runDownload(body: Vector.millionA, chunkSize: 128 << 10,
                                           expected: expected).get()
        XCTAssertEqual(digest.sha1, Vector.millionASHA1)
        XCTAssertEqual(digest.md5, Vector.millionAMD5)
        XCTAssertEqual(digest.crc32, Vector.millionACRC32)
        XCTAssertEqual(sizeOfFile(at: part), 1_000_000)

        // The returned digest must describe the bytes on disk, over a body of
        // sixteen buffers.
        XCTAssertEqual(try digestOfFile(at: part), digest)
        // And independently of the hashing code entirely.
        XCTAssertTrue(try Data(contentsOf: part) == Vector.millionA,
                      "the file on disk is not the body that was sent")
    }

    // MARK: - Streaming, proved rather than asserted

    /// Drives the write loop from a pull-based source that measures, at each
    /// block boundary, how far the `.part` file has fallen behind what it has
    /// handed out.
    ///
    /// Because the source is pull-based and the observation is synchronous, an
    /// implementation that buffered the body would show a lag equal to
    /// everything produced so far, and one that streams shows at most one
    /// buffer. There is no sleeping and nothing to time out.
    private func measureStreamingLag(
        blockCount: Int, blockSize: Int, bufferByteCount: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (digest: FileDigest, maximumLag: Int64) {
        // Every block has different contents, so a loop that wrote the right
        // number of bytes from the wrong buffer, or at the wrong offset, cannot
        // produce a file that re-digests to the same answer.
        let blocks = (0..<blockCount).map { index in
            [UInt8](repeating: UInt8(index % 251), count: blockSize)
        }
        let total = Int64(blockCount * blockSize)
        let lags = Recorder<Int64>()
        let partURL = part!
        let source = BlockSource(blocks: blocks) { _, produced in
            lags.append(produced - max(0, sizeOfFile(at: partURL)))
            return nil
        }
        let downloader = StreamingFileDownloader(session: .shared, bufferByteCount: bufferByteCount)
        let digest = try await downloader.write(source, to: partURL,
                                                expected: ExpectedFileIntegrity(size: total),
                                                progress: { _ in })
        XCTAssertEqual(try digestOfFile(at: partURL), digest,
                       "the returned digest does not describe the bytes on disk",
                       file: file, line: line)
        XCTAssertTrue(try Data(contentsOf: partURL) == Data(blocks.flatMap { $0 }),
                      "the file on disk is not the body that was sent",
                      file: file, line: line)
        return (digest, lags.all.max() ?? 0)
    }

    func testWriteFlushesToDiskWhileTheBodyIsStillArriving() async throws {
        let blockSize = 64 << 10
        let (digest, maximumLag) = try await measureStreamingLag(
            blockCount: 16, blockSize: blockSize, bufferByteCount: blockSize)

        XCTAssertEqual(digest.size, Int64(16 * blockSize))
        // A downloader that buffered the body would have a lag of the whole
        // megabyte at the last boundary.
        XCTAssertLessThanOrEqual(maximumLag, Int64(blockSize),
                                 "bytes produced but not yet on disk must stay within one buffer")
        XCTAssertLessThan(maximumLag * 8, digest.size,
                          "the bound is only meaningful if the body is much larger than it")
    }

    /// The same measurement with a buffer four times the block size: the peak
    /// still tracks the buffer, not the body, which is what "bounded buffer"
    /// means.
    func testPeakBufferedBytesTrackTheBufferRatherThanTheBodySize() async throws {
        let blockSize = 16 << 10
        let (digest, maximumLag) = try await measureStreamingLag(
            blockCount: 64, blockSize: blockSize, bufferByteCount: 4 * blockSize)
        XCTAssertEqual(digest.size, Int64(64 * blockSize))
        XCTAssertLessThanOrEqual(maximumLag, Int64(4 * blockSize))
        XCTAssertLessThan(maximumLag * 8, digest.size,
                          "the bound is only meaningful if the body is much larger than it")
    }

    /// The same claim across the real `URLSession` path, where the risk is that
    /// the session hands over the body only once it is complete. The stub holds
    /// each chunk back until the `.part` file shows the previous ones, so an
    /// implementation that buffered — at either layer — would stall the gate and
    /// fail here.
    func testDownloadStreamsThroughURLSessionRatherThanBufferingTheBody() async throws {
        let chunkSize = 128 << 10
        let chunkCount = 8
        let buffer = 64 << 10
        let body = Data((0..<chunkCount).flatMap { index in
            [UInt8](repeating: UInt8(index), count: chunkSize)
        })
        let partURL = part!
        let stalled = Recorder<Int>()
        let observed = Recorder<Int64>()

        let chunks = (0..<chunkCount).map { index in
            body[body.startIndex + index * chunkSize ..< body.startIndex + (index + 1) * chunkSize]
        }.map { Data($0) }

        let session = ScriptedBodyProtocol.session(.init(status: 200, chunks: chunks, beforeChunk: { index in
            guard index > 0 else { return true }
            // Everything before this chunk must already be on disk, bar one buffer.
            let required = Int64(index * chunkSize - buffer)
            let arrived = waitUntil(10) { sizeOfFile(at: partURL) >= required }
            observed.append(sizeOfFile(at: partURL))
            if !arrived { stalled.append(index) }
            return true
        }))

        let downloader = StreamingFileDownloader(session: session, bufferByteCount: buffer)
        let expected = try ExpectedFileIntegrity(size: Int64(body.count))
        let digest = try await downloader.download(request: request(), to: part,
                                                   expected: expected, progress: { _ in })

        XCTAssertEqual(stalled.all, [], "the part file did not grow while the body was arriving")
        XCTAssertEqual(digest.size, Int64(body.count))
        XCTAssertEqual(observed.all.count, chunkCount - 1)
        XCTAssertLessThan(observed.all.first ?? -1, Int64(body.count),
                          "bytes must reach disk before the body is complete")
    }

    func testProgressIsMonotonicAndEndsAtTheByteCount() async throws {
        let samples = Recorder<Int64>()
        let expected = try ExpectedFileIntegrity(size: 1_000_000, sha1: Vector.millionASHA1)
        _ = try await runDownload(body: Vector.millionA, chunkSize: 64 << 10, expected: expected,
                                  bufferByteCount: 32 << 10,
                                  progress: { samples.append($0) }).get()

        let reported = samples.all
        XCTAssertGreaterThan(reported.count, 8, "progress must be reported during the body")
        XCTAssertEqual(reported, reported.sorted(), "progress must never go backwards")
        XCTAssertEqual(reported.last, 1_000_000)
        XCTAssertGreaterThan(reported.first ?? 0, 0)
        XCTAssertLessThan(reported.first ?? .max, 1_000_000,
                          "the first report must arrive before the body is complete")
        XCTAssertTrue(reported.allSatisfy { $0 <= 1_000_000 }, "progress must not overshoot")
    }

    func testProgressReportsZeroForAnEmptyBody() async throws {
        let samples = Recorder<Int64>()
        let expected = try ExpectedFileIntegrity(size: 0, sha1: Vector.emptySHA1)
        _ = try await runDownload(body: Data(), expected: expected,
                                  progress: { samples.append($0) }).get()
        XCTAssertEqual(samples.all, [0])
    }

    // MARK: - Status codes

    func testNonSuccessStatusIsRejected() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1)
        for status in [199, 300, 301, 302, 400, 401, 404, 500, 503] {
            let result = await runDownload(status: status, body: Vector.fox, expected: expected)
            assertIntegrityError(result, .httpStatus(status))
            XCTAssertFalse(fileExists(at: part), "status \(status) must leave no part file")
        }
    }

    func testSuccessStatusesOtherThan200AreAccepted() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1)
        for status in [200, 201, 206, 299] {
            let digest = try await runDownload(status: status, body: Vector.fox,
                                               expected: expected).get()
            XCTAssertEqual(digest.sha1, Vector.foxSHA1, "status \(status)")
        }
    }

    /// "Reject non-2xx before writing anything" is stronger than "clean up
    /// afterwards": an existing part file must not even be truncated.
    func testNonSuccessStatusDoesNotTouchAnExistingPartFile() async throws {
        let stale = Data(repeating: 0xCD, count: 4096)
        try stale.write(to: part)
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1)
        let result = await runDownload(status: 404, body: Vector.fox, expected: expected)
        assertIntegrityError(result, .httpStatus(404))
        XCTAssertEqual(try Data(contentsOf: part), stale)
    }

    func testANonHTTPResponseIsRejected() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        let result = await runDownload(body: Vector.fox, nonHTTPResponse: true, expected: expected)
        assertIntegrityError(result, .notAnHTTPResponse)
        XCTAssertFalse(fileExists(at: part))
    }

    // MARK: - Size mismatches

    func testABodyShorterThanExpectedIsRejected() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize + 10, sha1: Vector.foxSHA1)
        let result = await runDownload(body: Vector.fox, chunkSize: 10, expected: expected)
        assertIntegrityError(result, .bodyTooShort(expected: Vector.foxSize + 10,
                                                   actual: Vector.foxSize))
        XCTAssertFalse(fileExists(at: part))
    }

    /// A body longer than expected is refused on the byte that makes it too
    /// long, not after the whole thing has been read: `seenAtLeast` is exactly
    /// one past the expectation even though the stub had ten times that queued.
    func testABodyLongerThanExpectedIsRejectedAsSoonAsItOverruns() async throws {
        let body = Data(repeating: UInt8(ascii: "a"), count: 400_000)
        let expected = try ExpectedFileIntegrity(size: 40_000)
        let result = await runDownload(body: body, chunkSize: 16 << 10, expected: expected)
        assertIntegrityError(result, .bodyTooLong(expected: 40_000, seenAtLeast: 40_001))
        XCTAssertFalse(fileExists(at: part))
    }

    func testABodyOneByteLongIsRejected() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        let result = await runDownload(body: Vector.fox + Data([0x00]), expected: expected)
        assertIntegrityError(result, .bodyTooLong(expected: Vector.foxSize,
                                                  seenAtLeast: Vector.foxSize + 1))
        XCTAssertFalse(fileExists(at: part))
    }

    // MARK: - Hash mismatches

    func testEveryHashTheServerSuppliesIsCheckedAgainstTheDownloadedBytes() async throws {
        let wrongSHA1 = String(repeating: "1", count: 40)
        let wrongMD5 = String(repeating: "2", count: 32)
        let wrongCRC32 = "deadbeef"

        let cases: [(ExpectedFileIntegrity, FileIntegrityError)] = [
            (try ExpectedFileIntegrity(size: Vector.foxSize, sha1: wrongSHA1, md5: Vector.foxMD5,
                                       crc32: Vector.foxCRC32),
             .digestMismatch(.sha1, expected: wrongSHA1, actual: Vector.foxSHA1)),
            (try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1, md5: wrongMD5,
                                       crc32: Vector.foxCRC32),
             .digestMismatch(.md5, expected: wrongMD5, actual: Vector.foxMD5)),
            (try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                       md5: Vector.foxMD5, crc32: wrongCRC32),
             .digestMismatch(.crc32, expected: wrongCRC32, actual: Vector.foxCRC32)),
        ]
        for (expected, error) in cases {
            let result = await runDownload(body: Vector.fox, expected: expected)
            assertIntegrityError(result, error)
            XCTAssertFalse(fileExists(at: part), "a mismatch must remove the part file")
        }
    }

    /// A one-bit change in the body with the server's hashes unchanged: the
    /// corruption this whole file exists to catch.
    func testASingleFlippedBitFailsVerification() async throws {
        var corrupted = Vector.fox
        corrupted[corrupted.startIndex + 20] ^= 0x01
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                                 md5: Vector.foxMD5, crc32: Vector.foxCRC32)
        let result = await runDownload(body: corrupted, expected: expected)
        switch result {
        case .success: XCTFail("a flipped bit must not verify")
        case let .failure(error):
            guard case .digestMismatch(.sha1, _, _)? = error as? FileIntegrityError else {
                return XCTFail("expected a SHA-1 mismatch, got \(error)")
            }
        }
        XCTAssertFalse(fileExists(at: part))
    }

    func testADownloadWithNoServerHashesIsAcceptedOnSizeAlone() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        let digest = try await runDownload(body: Vector.fox, expected: expected).get()
        XCTAssertEqual(digest.sha1, Vector.foxSHA1)
        XCTAssertTrue(fileExists(at: part))
    }

    // MARK: - Failure cleanup

    func testATransportFailureMidBodyRemovesThePartFile() async throws {
        let body = Data(repeating: UInt8(ascii: "a"), count: 300_000)
        let expected = try ExpectedFileIntegrity(size: Int64(body.count))
        let result = await runDownload(body: body, chunkSize: 32 << 10,
                                       failure: .networkConnectionLost, expected: expected)
        switch result {
        case .success: XCTFail("a dropped connection must fail the download")
        case let .failure(error): XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertFalse(fileExists(at: part), "a dropped connection must leave no part file")
    }

    func testCancellationRemovesThePartFile() async throws {
        let chunkSize = 64 << 10
        let chunks = (0..<32).map { _ in Data(repeating: UInt8(ascii: "a"), count: chunkSize) }
        let partURL = part!
        let box = TaskBox()
        let published = Recorder<Bool>()

        let session = ScriptedBodyProtocol.session(.init(status: 200, chunks: chunks, beforeChunk: { index in
            guard index == 4 else { return true }
            // Cancel once the download is demonstrably under way.
            _ = waitUntil(10) { sizeOfFile(at: partURL) > 0 }
            published.append(box.cancelPublishedTask())
            return true
        }))
        let downloader = StreamingFileDownloader(session: session, bufferByteCount: chunkSize)
        let expected = try ExpectedFileIntegrity(size: Int64(32 * chunkSize))
        let task = Task { try await downloader.download(request: request(), to: partURL,
                                                        expected: expected, progress: { _ in }) }
        box.publish(task)

        let result = await task.result
        XCTAssertEqual(published.all, [true], "the test must actually have cancelled the task")
        switch result {
        case .success: XCTFail("a cancelled download must not succeed")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(fileExists(at: partURL), "cancellation must leave no part file")
    }

    /// Cancellation is checked by the write loop itself, not merely inherited
    /// from `URLSession`, and it stops the transfer *where it is*. This source
    /// never suspends at a cancellation point and would happily deliver every
    /// byte, so a loop that did not check would succeed; a loop that checked
    /// only after the body would still read all sixteen blocks, which on a real
    /// disc is half a gigabyte the player already told us to stop fetching.
    func testCancellationIsCheckedBetweenChunksAndStopsTheTransfer() async throws {
        let blockSize = 64 << 10
        let blockCount = 16
        let blocks = (0..<blockCount).map { _ in [UInt8](repeating: UInt8(ascii: "a"), count: blockSize) }
        let partURL = part!
        let box = TaskBox()
        let published = Recorder<Bool>()
        let delivered = Recorder<Int>()

        // Block 5, deliberately not a round number of buffers: a loop that
        // checked only every fourth chunk would run on to block 8 and fail the
        // bound below.
        let source = BlockSource(blocks: blocks) { index, _ in
            delivered.append(index)
            guard index == 5 else { return nil }
            published.append(box.cancelPublishedTask())
            return nil
        }
        let downloader = StreamingFileDownloader(session: .shared, bufferByteCount: blockSize)
        let expected = try ExpectedFileIntegrity(size: Int64(blockCount * blockSize))
        let task = Task { try await downloader.write(source, to: partURL, expected: expected,
                                                     progress: { _ in }) }
        box.publish(task)

        let result = await task.result
        XCTAssertEqual(published.all, [true], "the source must actually have cancelled the task")
        switch result {
        case let .success(digest):
            XCTFail("the write loop ignored cancellation and completed with \(digest)")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThanOrEqual(delivered.all.count, 7,
                                 "cancellation must stop the transfer, not just fail it at the end")
        XCTAssertFalse(fileExists(at: partURL))
    }

    /// A body smaller than one buffer never reaches a flush boundary, so the
    /// only check that can see the cancellation is the one after the loop.
    func testCancellationDuringABodySmallerThanOneBufferIsStillCaught() async throws {
        let partURL = part!
        let box = TaskBox()
        let published = Recorder<Bool>()
        let source = BlockSource(blocks: [[UInt8](repeating: UInt8(ascii: "a"), count: 1024)]) { index, _ in
            if index == 0 { published.append(box.cancelPublishedTask()) }
            return nil
        }
        let downloader = StreamingFileDownloader(session: .shared, bufferByteCount: 64 << 10)
        let expected = try ExpectedFileIntegrity(size: 1024)
        let task = Task { try await downloader.write(source, to: partURL, expected: expected,
                                                     progress: { _ in }) }
        box.publish(task)

        let result = await task.result
        XCTAssertEqual(published.all, [true])
        switch result {
        case let .success(digest): XCTFail("a cancelled download must not succeed: \(digest)")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(fileExists(at: partURL))
    }

    /// What `URLSession` does when a task is cancelled mid-body is throw
    /// `URLError.cancelled`, not `CancellationError`. A caller decides whether to
    /// show an error or say nothing on the error's type, so cancellation must
    /// arrive as cancellation however the body ended.
    func testAnUnderlyingCancelledURLErrorIsReportedAsCancellation() async throws {
        let partURL = part!
        let box = TaskBox()
        let blocks = [[UInt8]](repeating: [UInt8](repeating: UInt8(ascii: "a"), count: 1024), count: 2)
        let source = BlockSource(blocks: blocks) { index, _ in
            if index == 0 { _ = box.cancelPublishedTask() }
            // No flush boundary has been crossed, so the loop's own check has
            // not run when this arrives.
            return index == 1 ? URLError(.cancelled) : nil
        }
        let downloader = StreamingFileDownloader(session: .shared, bufferByteCount: 64 << 10)
        let expected = try ExpectedFileIntegrity(size: 2048)
        let task = Task { try await downloader.write(source, to: partURL, expected: expected,
                                                     progress: { _ in }) }
        box.publish(task)

        switch await task.result {
        case let .success(digest): XCTFail("a cancelled download must not succeed: \(digest)")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(fileExists(at: partURL))
    }

    /// Cancellation while the request is still in flight — before a single
    /// header has come back — is the case that lives outside the write loop
    /// entirely. The stub accepts the request and then says nothing at all, so
    /// the download is parked inside `session.bytes(for:)`, which is where
    /// Foundation reports cancellation as `URLError.cancelled`.
    ///
    /// In production this is Task 6 cancelling a per-file loop mid-package: the
    /// in-flight file must not report a *network error* while its neighbour
    /// reports cancellation.
    func testCancellationBeforeTheResponseArrivesIsReportedAsCancellation() async throws {
        let session = ScriptedBodyProtocol.session(.init(stall: true))
        let downloader = StreamingFileDownloader(session: session)
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        let partURL = part!

        let task = Task { try await downloader.download(request: request(), to: partURL,
                                                        expected: expected, progress: { _ in }) }
        XCTAssertTrue(waitUntil(10) { ScriptedBodyProtocol.startedRequests == 1 },
                      "the request never reached the loading system")
        task.cancel()

        switch await task.result {
        case let .success(digest): XCTFail("a cancelled download must not succeed: \(digest)")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(fileExists(at: partURL), "no part file may be created")
    }

    /// The same rule for a task that was already cancelled before `download` was
    /// ever awaited — the shape of a package loop whose caller backed out
    /// between files.
    func testDownloadOnAnAlreadyCancelledTaskIsReportedAsCancellation() async throws {
        let session = ScriptedBodyProtocol.session(.init(status: 200, chunks: [Vector.fox]))
        let downloader = StreamingFileDownloader(session: session)
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        let partURL = part!

        let task = Task { () -> FileDigest in
            while !Task.isCancelled { await Task.yield() }
            return try await downloader.download(request: request(), to: partURL,
                                                 expected: expected, progress: { _ in })
        }
        task.cancel()

        switch await task.result {
        case let .success(digest): XCTFail("a cancelled download must not succeed: \(digest)")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(fileExists(at: partURL))
    }

    func testEveryFailurePathLeavesNoPartFileBehind() async throws {
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize, sha1: Vector.foxSHA1,
                                                 md5: Vector.foxMD5, crc32: Vector.foxCRC32)
        let shortBody = Vector.fox.dropLast(1)
        let longBody = Vector.fox + Data([0x20])
        var corrupted = Vector.fox
        corrupted[corrupted.startIndex] ^= 0xFF

        let bodies: [(String, Data, Int)] = [
            ("non-2xx", Vector.fox, 500),
            ("short body", Data(shortBody), 200),
            ("long body", longBody, 200),
            ("corrupted body", corrupted, 200),
        ]
        for (name, body, status) in bodies {
            let result = await runDownload(status: status, body: body, chunkSize: 8,
                                           expected: expected)
            XCTAssertThrowsError(try result.get(), name)
            XCTAssertFalse(fileExists(at: part), "\(name) left a part file behind")
        }
    }

    // MARK: - Part path safety

    func testAPartPathThatIsADirectoryIsRefused() async throws {
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: false)
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        let result = await runDownload(body: Vector.fox, expected: expected)
        assertIntegrityError(result, .partPathBlocked(part.lastPathComponent))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the directory must be left alone")
    }

    func testAPartPathThatIsASymlinkIsRefusedWithoutFollowingIt() async throws {
        let target = directory.appendingPathComponent("elsewhere.bin", isDirectory: false)
        let sentinel = Data(repeating: 0x5A, count: 64)
        try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(at: part, withDestinationURL: target)

        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        let result = await runDownload(body: Vector.fox, expected: expected)
        assertIntegrityError(result, .partPathBlocked(part.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: target), sentinel,
                       "the symlink's target must not be written through")
    }

    func testAPartPathInAMissingDirectoryIsRefused() async throws {
        let missing = directory.appendingPathComponent("not-created", isDirectory: true)
            .appendingPathComponent("disc.bin.part", isDirectory: false)
        let session = ScriptedBodyProtocol.session(.init(status: 200, chunks: [Vector.fox]))
        let downloader = StreamingFileDownloader(session: session)
        let expected = try ExpectedFileIntegrity(size: Vector.foxSize)
        do {
            _ = try await downloader.download(request: request(), to: missing, expected: expected,
                                              progress: { _ in })
            XCTFail("a part path with no parent directory must fail")
        } catch let error as FileIntegrityError {
            XCTAssertEqual(error, .partFileNotWritable(missing.lastPathComponent))
        }
        XCTAssertFalse(fileExists(at: missing))
    }

    // MARK: - Error messages

    /// Every error a caller can show has to say which check failed and what was
    /// expected against what was seen, because someone on a couch has to act on it.
    func testErrorsDescribeTheCheckThatFailed() {
        let messages: [FileIntegrityError] = [
            .malformedDigest(.sha1, problem: .whitespace),
            .malformedDigest(.md5, problem: .wrongLength),
            .malformedDigest(.crc32, problem: .nonHexadecimal),
            .malformedDigest(.sha1, problem: .empty),
            .negativeExpectedSize(-1),
            .notAnHTTPResponse,
            .httpStatus(404),
            .bodyTooShort(expected: 100, actual: 40),
            .bodyTooLong(expected: 100, seenAtLeast: 101),
            .digestMismatch(.md5, expected: Vector.foxMD5, actual: Vector.emptyMD5),
            .partPathBlocked("disc.bin.part"),
            .partFileNotWritable("disc.bin.part"),
        ]
        for error in messages {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) has no message")
            XCTAssertTrue(description.hasSuffix("."), "\(error): \(description)")
        }
        XCTAssertTrue(FileIntegrityError.bodyTooShort(expected: 100, actual: 40)
            .errorDescription!.contains("100"))
        XCTAssertTrue(FileIntegrityError.bodyTooShort(expected: 100, actual: 40)
            .errorDescription!.contains("40"))
        XCTAssertTrue(FileIntegrityError.digestMismatch(.md5, expected: Vector.foxMD5,
                                                        actual: Vector.emptyMD5)
            .errorDescription!.contains("MD5"))
        XCTAssertTrue(FileIntegrityError.httpStatus(404).errorDescription!.contains("404"))
    }
}

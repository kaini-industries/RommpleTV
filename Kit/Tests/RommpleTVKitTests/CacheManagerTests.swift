import XCTest
@testable import RommpleTVKit

/// A response that arrives and then stops: headers and a first chunk, and no
/// completion until the task is cancelled.
///
/// `StubProtocol` finishes synchronously, which cannot exercise a download that
/// is interrupted mid-body — the one case where a `.part` file exists and has to
/// be cleaned up.
final class SuspendedDownloadProtocol: URLProtocol {
    enum Mode {
        /// Deliver a prefix of the declared body and then stop, so the transfer
        /// is genuinely mid-body when the test acts on it.
        case suspend
        /// Deliver a prefix and then fail, which is every non-cancellation throw
        /// that can happen after the part file exists.
        case failMidBody
    }

    nonisolated(unsafe) static var mode: Mode = .suspend
    /// What the response declares. Twice what is actually sent, so the body is
    /// never complete and the read loop is still awaiting bytes.
    nonisolated(unsafe) static let declaredLength = 1 << 21
    nonisolated(unsafe) static let deliveredLength = 1 << 20

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.declaredLength)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: Self.deliveredLength))
        switch Self.mode {
        case .suspend:
            break   // no `urlProtocolDidFinishLoading`: the body stays open
        case .failMidBody:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedDownloadProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class CacheManagerTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func makeManager() -> CacheManager {
        let client = RommClient(config: RommConfig(
            baseURL: URL(string: "https://romm.example")!, token: "not-a-secret"),
            session: StubProtocol.session())
        return CacheManager(client: client, cacheRoot: tmp)
    }
    var rom: Rom {
        get throws {
            try JSONDecoder().decode(Rom.self, from: Data("""
            {"id": 7, "name": "Test", "fs_name": "Test Game (USA).sfc",
             "platform_id": 1, "fs_size_bytes": 8}
            """.utf8))
        }
    }

    func testDownloadWritesFileAndReportsProgress() async throws {
        let payload = Data("ROMBYTES".utf8)
        StubProtocol.responder = { _ in (200, payload) }
        var progress: [Double] = []
        let url = try await makeManager().download(try rom) { progress.append($0) }
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(url.lastPathComponent, "Test Game (USA).sfc")
        XCTAssertEqual(progress.last, 1.0)
    }

    func testCachedURLHitAndMiss() async throws {
        let manager = makeManager()
        XCTAssertNil(manager.cachedURL(for: try rom))
        StubProtocol.responder = { _ in (200, Data("ROMBYTES".utf8)) }
        _ = try await manager.download(try rom) { _ in }
        XCTAssertNotNil(manager.cachedURL(for: try rom))
    }

    func testDownloadReplacesCachedFileWhenServerSizeChanges() async throws {
        let manager = makeManager()
        StubProtocol.responder = { _ in (200, Data("ROMBYTES".utf8)) }
        let originalURL = try await manager.download(try rom) { _ in }
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("ROMBYTES".utf8))

        let updatedROM = try JSONDecoder().decode(Rom.self, from: Data("""
        {"id": 7, "name": "Test", "fs_name": "Test Game (USA).sfc",
         "platform_id": 1, "fs_size_bytes": 9}
        """.utf8))
        let updatedPayload = Data("NEWBYTES!".utf8)
        StubProtocol.responder = { _ in (200, updatedPayload) }

        let updatedURL = try await manager.download(updatedROM) { _ in }

        XCTAssertEqual(try Data(contentsOf: updatedURL), updatedPayload)
    }

    func testCachedURLKeepsFileWhenServerSizeIsUnavailable() async throws {
        let manager = makeManager()
        StubProtocol.responder = { _ in (200, Data("ROMBYTES".utf8)) }
        let cachedURL = try await manager.download(try rom) { _ in }
        let romWithoutSize = try JSONDecoder().decode(Rom.self, from: Data("""
        {"id": 7, "name": "Test", "fs_name": "Test Game (USA).sfc",
         "platform_id": 1}
        """.utf8))

        XCTAssertEqual(manager.cachedURL(for: romWithoutSize), cachedURL)
        XCTAssertEqual(try Data(contentsOf: cachedURL), Data("ROMBYTES".utf8))
    }

    func testHTTPErrorThrowsAndLeavesNoFile() async throws {
        let manager = makeManager()
        StubProtocol.responder = { _ in (500, Data()) }
        do { _ = try await manager.download(try rom) { _ in }; XCTFail("expected throw") }
        catch {}
        XCTAssertNil(manager.cachedURL(for: try rom))
    }

    /// Cancel is a first-class action now that every launch goes through a
    /// screen with a Cancel button, and it has to leave the cache as it found
    /// it. Without this, backing out of a 480 MB legacy download would strand a
    /// `.part` file that nothing ever removes — the same contract PlayStation
    /// staging already honours.
    func testCancellationRemovesPartFile() async throws {
        let client = RommClient(config: RommConfig(
            baseURL: URL(string: "https://romm.invalid")!, token: "not-a-secret"),
            session: SuspendedDownloadProtocol.session())
        let manager = CacheManager(client: client, cacheRoot: tmp)
        let rom = try self.rom
        let partURL = tmp.appendingPathComponent("7", isDirectory: true)
            .appendingPathComponent("Test Game (USA).sfc.part")

        let download = Task { try await manager.download(rom) { _ in } }
        // The part file exists while the transfer is in flight — otherwise this
        // test would pass against an implementation that never created one.
        try await waitUntil { FileManager.default.fileExists(atPath: partURL.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: partURL.path),
                      "the download never reached the point where a part file exists")

        download.cancel()
        do {
            _ = try await download.value
            XCTFail("a cancelled download returned a URL")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path),
                       "a cancelled download left its .part file behind")
        XCTAssertNil(manager.cachedURL(for: rom))
    }

    /// A failure that is not a cancellation cleans up too: the connection
    /// dropping half-way through a body is the common one, and it leaves the
    /// same debris.
    func testMidBodyFailureRemovesPartFile() async throws {
        SuspendedDownloadProtocol.mode = .failMidBody
        defer { SuspendedDownloadProtocol.mode = .suspend }
        let client = RommClient(config: RommConfig(
            baseURL: URL(string: "https://romm.invalid")!, token: "not-a-secret"),
            session: SuspendedDownloadProtocol.session())
        let manager = CacheManager(client: client, cacheRoot: tmp)

        do {
            _ = try await manager.download(try rom) { _ in }
            XCTFail("expected the interrupted body to throw")
        } catch {}

        let partURL = tmp.appendingPathComponent("7", isDirectory: true)
            .appendingPathComponent("Test Game (USA).sfc.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path),
                       "an interrupted download left its .part file behind")
        XCTAssertNil(manager.cachedURL(for: try rom))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<2000 where !condition() {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

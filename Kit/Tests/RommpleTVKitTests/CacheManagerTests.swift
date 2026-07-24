import XCTest
@testable import RommpleTVKit

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
}

import XCTest
@testable import RommpleTVKit

final class RommClientTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }
    func makeClient() -> RommClient {
        RommClient(config: RommConfig(baseURL: URL(string: "https://romm.example")!,
                                      token: "not-a-secret"),
                   session: StubProtocol.session())
    }

    func testPlatformsDecodesAndSendsBearer() async throws {
        let data = try fixture("platforms")
        var capturedAuth: String?
        StubProtocol.responder = { req in
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return (200, data)
        }
        let platforms = try await makeClient().platforms()
        XCTAssertEqual(capturedAuth, "Bearer not-a-secret")
        XCTAssertFalse(platforms.isEmpty)
        XCTAssertNotNil(platforms.first { $0.slug == "snes" })
    }

    func testRomsDecodesPage() async throws {
        let data = try fixture("roms_page")
        StubProtocol.responder = { _ in (200, data) }
        let roms = try await makeClient().roms(platformId: 1)
        XCTAssertEqual(roms.count, 3)
        XCTAssertEqual(roms[0].id, 101)
        XCTAssertEqual(roms[0].platformId, 1)
        XCTAssertEqual(roms[0].fsName, "Example Adventure.sfc")
        XCTAssertEqual(roms[0].sizeBytes, 8)
    }

    func testRomsPageDecodesTotalFromEnvelope() async throws {
        let data = try fixture("roms_page")
        StubProtocol.responder = { _ in (200, data) }
        let page = try await makeClient().romsPage(platformId: 1)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.items.count, 3)
    }

    func testRomsPageBareArrayYieldsNilTotal() async throws {
        let bare = Data("""
        [{"id": 7, "name": "Example Game", "fs_name": "Example Game.sfc",
          "platform_id": 1, "fs_size_bytes": 3145728}]
        """.utf8)
        StubProtocol.responder = { _ in (200, bare) }
        let page = try await makeClient().romsPage(platformId: 1)
        XCTAssertNil(page.total)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].fsName, "Example Game.sfc")
    }

    func testRomsSendsPlatformIdsPlural() async throws {
        let data = try fixture("roms_page")
        var capturedURL: URL?
        StubProtocol.responder = { req in
            capturedURL = req.url
            return (200, data)
        }
        _ = try await makeClient().roms(platformId: 1)
        let url = try XCTUnwrap(capturedURL)
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("platform_ids=1"),
                      "expected platform_ids= in query, got: \(query)")
        XCTAssertFalse(query.contains("platform_id=1"),
                       "singular platform_id is silently ignored by RomM 5.x; query was: \(query)")
    }

    func testRomsDecodesCoverPath() async throws {
        // The fixture carries path_cover_small (already prefixed with
        // /assets/romm/resources/...); that stored small-cover path is the
        // field Rom.coverPath maps to.
        let data = try fixture("roms_page")
        StubProtocol.responder = { _ in (200, data) }
        let roms = try await makeClient().roms(platformId: 1)
        XCTAssertEqual(roms[0].coverPath,
            "/assets/romm/resources/roms/1/101/cover/small.png?ts=2026-01-01 00:00:00")
    }

    func testCoverPathAbsentDecodesNil() async throws {
        let bare = Data("""
        [{"id": 7, "name": "Example Game", "fs_name": "Example Game.sfc",
          "platform_id": 1, "fs_size_bytes": 3145728}]
        """.utf8)
        StubProtocol.responder = { _ in (200, bare) }
        let page = try await makeClient().romsPage(platformId: 1)
        XCTAssertNil(page.items[0].coverPath)
    }

    func testCoverURLResolvesPathAgainstBaseURLAndEncodesQuery() async throws {
        let data = try fixture("roms_page")
        StubProtocol.responder = { _ in (200, data) }
        let client = makeClient()
        let rom = try await client.roms(platformId: 1)[0]
        let url = try XCTUnwrap(client.coverURL(for: rom))
        XCTAssertEqual(url.absoluteString,
            "https://romm.example/assets/romm/resources/roms/1/101/cover/small.png?ts=2026-01-01%2000:00:00")
    }

    func testCoverURLNilWhenCoverPathAbsent() async throws {
        let bare = Data("""
        [{"id": 7, "name": "Example Game", "fs_name": "Example Game.sfc",
          "platform_id": 1, "fs_size_bytes": 3145728}]
        """.utf8)
        StubProtocol.responder = { _ in (200, bare) }
        let client = makeClient()
        let rom = try await client.roms(platformId: 1)[0]
        XCTAssertNil(client.coverURL(for: rom))
    }

    func testHTTPErrorThrows() async {
        StubProtocol.responder = { _ in (401, Data()) }
        do { _ = try await makeClient().platforms(); XCTFail("expected throw") }
        catch let RommError.http(status) { XCTAssertEqual(status, 401) }
        catch { XCTFail("wrong error: \(error)") }
    }

    func testContentURLEncodesFsName() {
        let url = makeClient().romContentURL(id: 42, fsName: "Example Game.sfc")
        XCTAssertEqual(url.absoluteString,
            "https://romm.example/api/roms/42/content/Example%20Game.sfc")
    }

    func testLiveServerSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURLString = environment["ROMM_BASE_URL"],
              let baseURL = URL(string: baseURLString),
              let token = environment["ROMM_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("ROMM_BASE_URL and ROMM_TOKEN are not set")
        }
        let client = RommClient(config: RommConfig(baseURL: baseURL, token: token))
        let platforms = try await client.platforms()
        XCTAssertFalse(platforms.isEmpty)
    }
}

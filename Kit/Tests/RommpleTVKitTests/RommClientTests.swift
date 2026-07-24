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

    /// Query items as a `[name: value]` dict so assertions don't depend on
    /// the client's internal (alphabetical) query-ordering choice.
    func queryDict(from url: URL) -> [String: String] {
        var dict: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            dict[item.name] = item.value
        }
        return dict
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

    func testRomsPageDecodesEnvelopeTotal() async throws {
        let data = try fixture("roms_page")
        StubProtocol.responder = { _ in (200, data) }
        let page = try await makeClient().romsPage(platformId: 1)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.limit, 48)
        XCTAssertEqual(page.offset, 0)
    }

    func testRomsPageKeepsBareArrayCompatibility() async throws {
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

    func testRomsPageSendsPagingSortingAndGroupingQuery() async throws {
        let data = try fixture("roms_page")
        var capturedURL: URL?
        StubProtocol.responder = { req in
            capturedURL = req.url
            return (200, data)
        }
        _ = try await makeClient().romsPage(platformId: 35, limit: 48, offset: 96, sort: .sizeLargest)
        let url = try XCTUnwrap(capturedURL)
        let query = queryDict(from: url)
        XCTAssertEqual(query["platform_ids"], "35")
        XCTAssertEqual(query["limit"], "48")
        XCTAssertEqual(query["offset"], "96")
        XCTAssertEqual(query["order_by"], "fs_size_bytes")
        XCTAssertEqual(query["order_dir"], "desc")
        XCTAssertEqual(query["group_by_meta_id"], "true")
        XCTAssertNil(query["platform_id"])

        // `limit: 48` above equals romsPage's own default, so it alone would still pass
        // against a client that hardcoded "limit": "48" rather than threading the
        // argument through. Prove threading with a non-default limit.
        _ = try await makeClient().romsPage(platformId: 35, limit: 24, offset: 96, sort: .sizeLargest)
        let secondURL = try XCTUnwrap(capturedURL)
        XCTAssertEqual(queryDict(from: secondURL)["limit"], "24")
    }

    func testEveryRomSortMapsToExpectedServerFields() async throws {
        let data = try fixture("roms_page")
        let expected: [RomSort: (orderBy: String, orderDir: String)] = [
            .titleAscending: ("name", "asc"),
            .titleDescending: ("name", "desc"),
            .dateAddedNewest: ("created_at", "desc"),
            .dateAddedOldest: ("created_at", "asc"),
            .lastUpdatedNewest: ("updated_at", "desc"),
            .lastUpdatedOldest: ("updated_at", "asc"),
            .sizeLargest: ("fs_size_bytes", "desc"),
            .sizeSmallest: ("fs_size_bytes", "asc"),
        ]
        // Driven off allCases so a future RomSort case without a table entry fails loudly
        // instead of silently skipping coverage.
        XCTAssertEqual(Set(RomSort.allCases), Set(expected.keys),
                        "expected-mapping table is out of sync with RomSort.allCases")
        for sort in RomSort.allCases {
            var capturedURL: URL?
            StubProtocol.responder = { req in
                capturedURL = req.url
                return (200, data)
            }
            _ = try await makeClient().romsPage(platformId: 1, sort: sort)
            let url = try XCTUnwrap(capturedURL, "no request captured for \(sort)")
            let query = queryDict(from: url)
            let (orderBy, orderDir) = try XCTUnwrap(expected[sort])
            XCTAssertEqual(query["order_by"], orderBy, "\(sort) order_by")
            XCTAssertEqual(query["order_dir"], orderDir, "\(sort) order_dir")
        }
    }

    func testGroupedSiblingSummariesDecodeWithoutFullRomFields() async throws {
        // Sibling entries in RomM's grouped payload carry only a summary shape
        // (id, name, fs_name_no_tags, fs_name_no_ext, is_main_sibling) and omit
        // required top-level Rom fields like fs_name/platform_id. A rom with no
        // sibling_roms key at all must still decode, defaulting to [].
        let bare = Data("""
        [
          {
            "id": 101, "name": "Example Adventure", "fs_name": "Example Adventure.sfc",
            "platform_id": 1, "fs_size_bytes": 8,
            "sibling_roms": [
              {"id": 102, "name": "Example Adventure (Alt)",
               "fs_name_no_tags": "Example Adventure (Alt)",
               "fs_name_no_ext": "Example Adventure (Alt)", "is_main_sibling": false},
              {"id": 104, "name": null,
               "fs_name_no_tags": "Example Adventure (Unscraped)",
               "fs_name_no_ext": "Example Adventure (Unscraped)", "is_main_sibling": false}
            ]
          },
          {
            "id": 103, "name": "Example Puzzle", "fs_name": "Example Puzzle.sfc",
            "platform_id": 1, "fs_size_bytes": 32
          }
        ]
        """.utf8)
        StubProtocol.responder = { _ in (200, bare) }
        let page = try await makeClient().romsPage(platformId: 1)
        XCTAssertEqual(page.items.count, 2)
        let withSibling = page.items[0]
        XCTAssertEqual(withSibling.siblingRoms.count, 2)
        XCTAssertEqual(withSibling.siblingRoms[0].id, 102)
        XCTAssertEqual(withSibling.siblingRoms[0].name, "Example Adventure (Alt)")
        XCTAssertEqual(withSibling.siblingRoms[0].fsNameNoTags, "Example Adventure (Alt)")
        XCTAssertEqual(withSibling.siblingRoms[0].fsNameNoExt, "Example Adventure (Alt)")
        XCTAssertEqual(withSibling.siblingRoms[0].isMainSibling, false)
        // RomM's SiblingRomSchema.name is `str | None`; a sibling with no scraped name
        // must decode (to nil) rather than failing the whole page.
        XCTAssertNil(withSibling.siblingRoms[1].name)
        XCTAssertTrue(page.items[1].siblingRoms.isEmpty)
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

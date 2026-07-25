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

    /// URLSession hands `URLProtocol` subclasses the body as a stream, so a
    /// request built with `httpBody` arrives at the stub with `httpBody == nil`.
    /// Read whichever the captured request actually carries.
    func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// Byte-exact substring count, so assertions about a multipart body never
    /// depend on the raw save bytes being valid UTF-8.
    func occurrences(of needle: String, in haystack: Data) -> Int {
        let pattern = Data(needle.utf8)
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: pattern, in: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
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

    // MARK: - PlayStation transfer surface

    /// A synthetic `/api/roms/{id}` payload shaped like RomM's: one top-level
    /// `.cue` plus a nested track, carrying fields the client deliberately does
    /// not model (`category`, `rom_id`, `full_path`, `track_meta`) so extras are
    /// proven to be ignored rather than fatal. ROM id and file ids are
    /// deliberately far apart so an id mix-up cannot pass silently.
    static let romDetailsJSON = Data("""
    {
      "id": 8343,
      "name": "Example Adventure",
      "fs_name": "Example Adventure",
      "platform_id": 35,
      "fs_size_bytes": 700000000,
      "regions": ["USA"],
      "files": [
        {
          "id": 9633,
          "file_name": "Example Adventure (Disc 1).cue",
          "file_path": "psx/Example Adventure",
          "file_size_bytes": 4096,
          "is_top_level": true,
          "crc_hash": "1a2b3c4d",
          "md5_hash": "5d41402abc4b2a76b9719d911017c592",
          "sha1_hash": "da39a3ee5e6b4b0d3255bfef95601890afd80709",
          "updated_at": "2026-01-01T00:00:00",
          "category": "disc",
          "rom_id": 8343,
          "full_path": "/romm/library/psx/Example Adventure/Example Adventure (Disc 1).cue",
          "archive_members": [],
          "track_meta": null
        },
        {
          "id": 9634,
          "file_name": "Example Adventure (Disc 1) (Track 02).bin",
          "file_path": "psx/Example Adventure",
          "file_size_bytes": 699995904,
          "is_top_level": false,
          "crc_hash": null,
          "md5_hash": null,
          "sha1_hash": null,
          "updated_at": "2026-01-02T03:04:05",
          "category": null,
          "rom_id": 8343,
          "full_path": "/romm/library/psx/Example Adventure/Example Adventure (Disc 1) (Track 02).bin"
        }
      ]
    }
    """.utf8)

    func testRomDetailsDecodesTopLevelAndNestedFiles() async throws {
        var capturedURL: URL?
        var capturedAuth: String?
        StubProtocol.responder = { req in
            capturedURL = req.url
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return (200, Self.romDetailsJSON)
        }
        let details = try await makeClient().romDetails(id: 8343)

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.path, "/api/roms/8343")
        XCTAssertEqual(capturedAuth, "Bearer not-a-secret")

        XCTAssertEqual(details.id, 8343)
        XCTAssertEqual(details.fsName, "Example Adventure")
        XCTAssertEqual(details.files.count, 2)

        let cue = details.files[0]
        XCTAssertEqual(cue.id, 9633)
        XCTAssertNotEqual(cue.id, details.id, "file id must not be the parent rom id")
        XCTAssertEqual(cue.fileName, "Example Adventure (Disc 1).cue")
        XCTAssertEqual(cue.filePath, "psx/Example Adventure")
        XCTAssertEqual(cue.sizeBytes, 4096)
        XCTAssertTrue(cue.isTopLevel)
        XCTAssertEqual(cue.crcHash, "1a2b3c4d")
        XCTAssertEqual(cue.md5Hash, "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(cue.sha1Hash, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(cue.updatedAt, "2026-01-01T00:00:00")

        let track = details.files[1]
        XCTAssertEqual(track.id, 9634)
        XCTAssertFalse(track.isTopLevel)
        XCTAssertEqual(track.sizeBytes, 699_995_904)
        // Integrity metadata is genuinely optional on RomM; a null hash must
        // decode to nil rather than failing the whole disc listing.
        XCTAssertNil(track.crcHash)
        XCTAssertNil(track.md5Hash)
        XCTAssertNil(track.sha1Hash)
        XCTAssertEqual(track.updatedAt, "2026-01-02T03:04:05")
    }

    func testRomDecodesRegionsAndDefaultsToEmpty() async throws {
        let bare = Data("""
        [
          {"id": 101, "name": "Example Adventure", "fs_name": "Example Adventure.chd",
           "platform_id": 35, "fs_size_bytes": 8, "regions": ["USA", "EUR"]},
          {"id": 102, "name": "Example Puzzle", "fs_name": "Example Puzzle.chd",
           "platform_id": 35, "fs_size_bytes": 8}
        ]
        """.utf8)
        StubProtocol.responder = { _ in (200, bare) }
        let page = try await makeClient().romsPage(platformId: 35)
        XCTAssertEqual(page.items[0].regions, ["USA", "EUR"])
        XCTAssertTrue(page.items[1].regions.isEmpty, "absent regions must default to []")
    }

    func testFirmwareListDecodesIntegrityMetadata() async throws {
        // Bare array, as /api/firmware answers. Carries unmodeled extras
        // (created_at, file_extension, file_name_no_ext, file_name_no_tags,
        // file_path, full_path) to prove they are ignored.
        let json = Data("""
        [
          {
            "id": 12, "file_name": "example-bios-a.bin", "file_size_bytes": 524288,
            "is_verified": true, "crc_hash": "3bf06be1",
            "md5_hash": "924e392ed05558ffdb115408c263dccf",
            "sha1_hash": "10155d8d6e6e832d6ea66db9bc098321fb5e8ebf",
            "missing_from_fs": false, "updated_at": "2026-01-01T00:00:00",
            "created_at": "2025-12-01T00:00:00", "file_extension": "bin",
            "file_name_no_ext": "example-bios-a", "file_name_no_tags": "example-bios-a",
            "file_path": "bios/psx", "full_path": "/romm/bios/psx/example-bios-a.bin"
          },
          {
            "id": 13, "file_name": "example-bios-b.bin", "file_size_bytes": 0,
            "is_verified": false, "crc_hash": null, "md5_hash": null, "sha1_hash": null,
            "missing_from_fs": true, "updated_at": "2026-02-02T00:00:00"
          }
        ]
        """.utf8)
        var capturedURL: URL?
        var capturedAuth: String?
        StubProtocol.responder = { req in
            capturedURL = req.url
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return (200, json)
        }
        let firmware = try await makeClient().firmware(platformID: 35)

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.path, "/api/firmware")
        XCTAssertEqual(queryDict(from: url)["platform_id"], "35")
        XCTAssertEqual(capturedAuth, "Bearer not-a-secret")

        XCTAssertEqual(firmware.count, 2)
        XCTAssertEqual(firmware[0].id, 12)
        XCTAssertEqual(firmware[0].fileName, "example-bios-a.bin")
        XCTAssertEqual(firmware[0].fileSizeBytes, 524_288)
        XCTAssertTrue(firmware[0].isVerified)
        XCTAssertEqual(firmware[0].crcHash, "3bf06be1")
        XCTAssertEqual(firmware[0].md5Hash, "924e392ed05558ffdb115408c263dccf")
        XCTAssertEqual(firmware[0].sha1Hash, "10155d8d6e6e832d6ea66db9bc098321fb5e8ebf")
        XCTAssertFalse(firmware[0].missingFromFS)
        XCTAssertEqual(firmware[0].updatedAt, "2026-01-01T00:00:00")

        // An unusable entry must still decode so the caller can reject it on
        // its own terms (missing from fs, unverified, no hashes).
        XCTAssertEqual(firmware[1].id, 13)
        XCTAssertFalse(firmware[1].isVerified)
        XCTAssertTrue(firmware[1].missingFromFS)
        XCTAssertNil(firmware[1].md5Hash)
    }

    func testSaveListDecodesIdentityAndContentHash() async throws {
        // Bare array as /api/saves answers, with unmodeled extras present.
        let json = Data("""
        [
          {
            "id": 5150, "rom_id": 8343, "file_name": "RommpleTV Memory Card.mcr",
            "file_size_bytes": 131072, "missing_from_fs": false,
            "created_at": "2026-03-01T10:00:00", "updated_at": "2026-03-01T10:00:00",
            "emulator": "mednafen_psx", "slot": "0",
            "content_hash": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            "origin_device_id": "example-device-id",
            "device_syncs": [], "download_path": "/api/saves/5150/content",
            "file_extension": "mcr", "file_name_no_ext": "RommpleTV Memory Card",
            "file_name_no_tags": "RommpleTV Memory Card", "file_path": "psx/saves",
            "full_path": "/romm/assets/psx/saves/RommpleTV Memory Card.mcr",
            "is_public": false, "screenshot": null, "user_id": 1
          },
          {
            "id": 5151, "rom_id": 8343, "file_name": "RommpleTV Memory Card.mcr",
            "file_size_bytes": 131072, "missing_from_fs": true,
            "created_at": "2026-03-02T10:00:00", "updated_at": "2026-03-02T11:00:00",
            "emulator": null, "slot": null, "content_hash": null, "origin_device_id": null
          }
        ]
        """.utf8)
        var capturedURL: URL?
        var capturedAuth: String?
        StubProtocol.responder = { req in
            capturedURL = req.url
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return (200, json)
        }
        let saves = try await makeClient().saves(romID: 8343)

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.path, "/api/saves")
        XCTAssertEqual(queryDict(from: url)["rom_id"], "8343")
        XCTAssertEqual(capturedAuth, "Bearer not-a-secret")

        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0].id, 5150)
        XCTAssertEqual(saves[0].romID, 8343)
        XCTAssertEqual(saves[0].fileName, "RommpleTV Memory Card.mcr")
        XCTAssertEqual(saves[0].fileSizeBytes, 131_072)
        XCTAssertFalse(saves[0].missingFromFS)
        XCTAssertEqual(saves[0].createdAt, "2026-03-01T10:00:00")
        XCTAssertEqual(saves[0].updatedAt, "2026-03-01T10:00:00")
        XCTAssertEqual(saves[0].emulator, "mednafen_psx")
        XCTAssertEqual(saves[0].slot, "0")
        XCTAssertEqual(saves[0].contentHash,
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        XCTAssertEqual(saves[0].originDeviceID, "example-device-id")

        // Saves written by other clients carry no identity fields at all; they
        // must decode (to nil) so the caller can filter them out.
        XCTAssertEqual(saves[1].id, 5151)
        XCTAssertTrue(saves[1].missingFromFS)
        XCTAssertNil(saves[1].emulator)
        XCTAssertNil(saves[1].slot)
        XCTAssertNil(saves[1].contentHash)
        XCTAssertNil(saves[1].originDeviceID)
    }

    func testRomFileRequestUsesInternalFileIDAndPercentEncodesFilename() async throws {
        // Drive the id straight off a decoded ROM detail payload so the test
        // locks the real hazard: rom 8343 owns files 9633/9634, and the content
        // path must carry the *file* id.
        StubProtocol.responder = { _ in (200, Self.romDetailsJSON) }
        let client = makeClient()
        let details = try await client.romDetails(id: 8343)
        let track = details.files[1]
        XCTAssertEqual(track.id, 9634)

        let request = client.romFileRequest(fileID: track.id,
                                            fileName: "Example Adventure #1 (Track 02).bin")
        let url = try XCTUnwrap(request.url)

        XCTAssertEqual(url.absoluteString,
            "https://romm.example/api/roms/9634/files/content/Example%20Adventure%20%231%20(Track%2002).bin")
        // Path segment, id placement, and encoding asserted separately so a
        // failure says which of the three broke.
        XCTAssertTrue(url.path.hasPrefix("/api/roms/9634/files/content/"),
                      "expected the /files/content/ segment under the file id, got \(url.path)")
        XCTAssertFalse(url.absoluteString.contains("/8343/"),
                       "parent rom id must never appear in a rom-file content URL")
        XCTAssertEqual(url.pathComponents.last, "Example Adventure #1 (Track 02).bin",
                       "the filename must survive a decode round trip")
        // A raw '#' would truncate the URL into a fragment; a raw space would
        // make it unusable. Both must be percent-encoded.
        XCTAssertTrue(url.absoluteString.contains("%23"), "'#' must be percent-encoded")
        XCTAssertTrue(url.absoluteString.contains("%20"), "' ' must be percent-encoded")
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer not-a-secret")
        XCTAssertFalse(url.absoluteString.contains("not-a-secret"),
                       "token must never reach the URL")

        // A server-supplied file_name is one path component and must stay one:
        // an unescaped '/' would let it split into segments, and '..' would then
        // normalize into a traversal to a different file on the same host.
        let hostile = client.romFileRequest(fileID: 9634, fileName: "../../etc/passwd")
        let hostileURL = try XCTUnwrap(hostile.url)
        XCTAssertEqual(hostileURL.absoluteString,
            "https://romm.example/api/roms/9634/files/content/..%2F..%2Fetc%2Fpasswd")
        // Compare *encoded* paths: URL.pathComponents percent-decodes, which
        // would re-split %2F and hide exactly the property under test.
        let hostilePath = try XCTUnwrap(
            URLComponents(url: hostileURL, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        let benignPath = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        XCTAssertEqual(hostilePath, "/api/roms/9634/files/content/..%2F..%2Fetc%2Fpasswd")
        XCTAssertEqual(hostilePath.filter { $0 == "/" }.count,
                       benignPath.filter { $0 == "/" }.count,
                       "an embedded '/' must not add path segments")
        XCTAssertEqual(hostileURL.standardized.absoluteString, hostileURL.absoluteString,
                       "'..' must not normalize into a traversal")
    }

    func testFirmwareContentRequestUsesFileName() throws {
        let request = makeClient().firmwareContentRequest(id: 12, fileName: "Example BIOS #1.bin")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.absoluteString,
            "https://romm.example/api/firmware/12/content/Example%20BIOS%20%231.bin")
        XCTAssertEqual(url.pathComponents.last, "Example BIOS #1.bin")
        XCTAssertNil(url.fragment)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer not-a-secret")
        XCTAssertFalse(url.absoluteString.contains("not-a-secret"))
    }

    func testSaveContentRequestUsesSaveID() throws {
        let request = makeClient().saveContentRequest(id: 5150)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.absoluteString, "https://romm.example/api/saves/5150/content")
        XCTAssertNil(url.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer not-a-secret")
        XCTAssertFalse(url.absoluteString.contains("not-a-secret"))
    }

    func testCreateSaveUsesAppendOnlyMultipartBodyAndIdentityQuery() async throws {
        // Deterministic pseudo-card bytes, including 0x00 and high bytes, so a
        // body that mangles or re-encodes the payload fails.
        let cardBytes = Data((0..<512).map { UInt8($0 % 251) })
        let responseJSON = Data("""
        {"id": 5152, "rom_id": 8343, "file_name": "RommpleTV Memory Card.mcr",
         "file_size_bytes": 512, "missing_from_fs": false,
         "created_at": "2026-03-03T09:00:00", "updated_at": "2026-03-03T09:00:00",
         "emulator": "mednafen_psx", "slot": "0", "content_hash": "abc123",
         "origin_device_id": "example-device-id"}
        """.utf8)
        var captured: URLRequest?
        StubProtocol.responder = { req in
            captured = req
            return (200, responseJSON)
        }

        XCTAssertEqual(RommClient.memoryCardFileName, "RommpleTV Memory Card.mcr")
        // One client for every upload in this test: a boundary hoisted to a
        // per-instance stored property would otherwise still look "generated".
        let client = makeClient()
        let save = try await client.createSave(
            fileName: RommClient.memoryCardFileName,
            romID: 8343,
            emulator: "mednafen_psx",
            slot: "0",
            deviceID: "example-device-id",
            data: cardBytes,
            autocleanup: true
        )
        XCTAssertEqual(save.id, 5152)
        XCTAssertEqual(save.romID, 8343)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/saves")

        // Identity + append-only retention query.
        let query = queryDict(from: url)
        XCTAssertEqual(query["rom_id"], "8343")
        XCTAssertEqual(query["emulator"], "mednafen_psx")
        XCTAssertEqual(query["slot"], "0")
        XCTAssertEqual(query["device_id"], "example-device-id")
        XCTAssertEqual(query["overwrite"], "false", "active card bytes are never overwritten")
        XCTAssertEqual(query["autocleanup"], "true")
        XCTAssertEqual(query["autocleanup_limit"], "10")

        // Boundary is generated and shared by the header and the body.
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundaryPrefix = "multipart/form-data; boundary="
        XCTAssertTrue(contentType.hasPrefix(boundaryPrefix), "got Content-Type \(contentType)")
        let boundary = String(contentType.dropFirst(boundaryPrefix.count))
        XCTAssertFalse(boundary.isEmpty)

        let body = requestBody(request)
        XCTAssertFalse(body.isEmpty, "multipart body must reach the request")
        XCTAssertEqual(occurrences(of: "--\(boundary)\r\n", in: body), 1,
                       "exactly one part may open")
        XCTAssertEqual(occurrences(of: "--\(boundary)--", in: body), 1,
                       "body must be terminated by the closing boundary")
        XCTAssertEqual(occurrences(of: "name=\"saveFile\"", in: body), 1,
                       "exactly one saveFile part")

        // Constant upload filename; never a game title.
        XCTAssertEqual(occurrences(of: "filename=\"RommpleTV Memory Card.mcr\"", in: body), 1)
        XCTAssertEqual(occurrences(of: "Example Adventure", in: body), 0,
                       "upload filenames must never be derived from a game title")

        // The part declares a binary payload, and the exact bytes sit between
        // that header and the closing boundary. Anchoring the payload on this
        // header (rather than the first blank line) means deleting the header
        // fails the byte-exactness check too, not just the count below.
        XCTAssertEqual(
            occurrences(of: "Content-Type: application/octet-stream\r\n\r\n", in: body), 1,
            "the saveFile part must declare application/octet-stream")
        let headerEnd = try XCTUnwrap(
            body.range(of: Data("Content-Type: application/octet-stream\r\n\r\n".utf8)))
        let closing = try XCTUnwrap(body.range(of: Data("\r\n--\(boundary)--".utf8)))
        XCTAssertEqual(Data(body[headerEnd.upperBound..<closing.lowerBound]), cardBytes)

        // The token lives in exactly one place.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer not-a-secret")
        XCTAssertNil(body.range(of: Data("not-a-secret".utf8)),
                     "token must never appear in the multipart body")
        XCTAssertFalse(url.absoluteString.contains("not-a-secret"),
                       "token must never appear in the URL")
        for (name, value) in request.allHTTPHeaderFields ?? [:]
        where name.caseInsensitiveCompare("Authorization") != .orderedSame {
            XCTAssertFalse(value.contains("not-a-secret"), "token leaked into header \(name)")
        }

        // A second upload on the *same* client must not reuse the first
        // boundary, and omitting `fileName` must still send the constant — the
        // safe filename is the default, not a call-site convention.
        _ = try await client.createSave(
            romID: 8343, emulator: "mednafen_psx", slot: "0",
            deviceID: "example-device-id", data: cardBytes, autocleanup: true
        )
        let secondRequest = try XCTUnwrap(captured)
        let secondContentType = try XCTUnwrap(secondRequest.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNotEqual(secondContentType, contentType, "boundary must be generated per request")
        XCTAssertEqual(
            occurrences(of: "filename=\"RommpleTV Memory Card.mcr\"", in: requestBody(secondRequest)), 1,
            "the default fileName must be the constant memory-card name")

        // Conflict archives disable autocleanup and use their own slot; the
        // POST stays append-only either way.
        _ = try await client.createSave(
            romID: 8343, emulator: "mednafen_psx",
            slot: "conflict-20260303T090000Z-abc", deviceID: "example-device-id",
            data: cardBytes, autocleanup: false
        )
        let archiveQuery = queryDict(from: try XCTUnwrap(try XCTUnwrap(captured).url))
        XCTAssertEqual(archiveQuery["autocleanup"], "false")
        XCTAssertEqual(archiveQuery["slot"], "conflict-20260303T090000Z-abc")
        XCTAssertEqual(archiveQuery["overwrite"], "false")
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

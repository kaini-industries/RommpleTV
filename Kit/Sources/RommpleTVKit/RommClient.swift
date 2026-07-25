import Foundation

public final class RommClient: @unchecked Sendable {
    /// The only filename this client ever uploads a memory card under. Upload
    /// filenames are never derived from a game title: titles are private
    /// library content and a save's filename is visible server-side.
    public static let memoryCardFileName = "RommpleTV Memory Card.mcr"

    private let config: RommConfig
    private let session: URLSession

    public init(config: RommConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    public var sessionForDownloads: URLSession { session }

    public func platforms() async throws -> [Platform] {
        try await get([Platform].self, path: "/api/platforms", query: [:])
    }

    public func roms(platformId: Int, limit: Int = 100, offset: Int = 0) async throws -> [Rom] {
        try await romsPage(platformId: platformId, limit: limit, offset: offset).items
    }

    /// One page of the library plus the server's total count (nil when the
    /// server answered with a bare array), so callers can page to completion.
    public func romsPage(
        platformId: Int,
        limit: Int = 48,
        offset: Int = 0,
        sort: RomSort = .titleAscending,
        groupByMetaId: Bool = true
    ) async throws -> RomPage {
        // RomM 5.x silently ignores the singular `platform_id` query param (returns the
        // whole library unfiltered). The working parameter is `platform_ids` (plural).
        // The ROM object's own field is still `platform_id` (singular); only this query
        // param differs.
        let page = try await get(RomsPage.self, path: "/api/roms", query: [
            "platform_ids": String(platformId), "limit": String(limit),
            "offset": String(offset), "order_by": sort.orderBy,
            "order_dir": sort.orderDirection, "group_by_meta_id": String(groupByMetaId),
        ])
        return RomPage(items: page.items, total: page.total, limit: limit, offset: offset)
    }

    public func romContentURL(id: Int, fsName: String) -> URL {
        let encoded = fsName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        return URL(string: config.baseURL.absoluteString + "/api/roms/\(id)/content/" + encoded)!
    }

    /// Cover thumbnail URL for a rom, or nil when the server has no scraped
    /// cover for it. `Rom.coverPath` is already a full resource path (e.g.
    /// `/assets/romm/resources/roms/1/101/cover/small.png?ts=...`), so this only
    /// resolves it against `baseURL`; it does not re-add the
    /// `/assets/romm/resources/` prefix. The cache-busting `ts=` query value can
    /// contain a raw space, which `URL(string:)` would reject outright, so path
    /// and query are split and percent-encoded separately rather than encoding —
    /// and breaking — the whole string.
    public func coverURL(for rom: Rom) -> URL? {
        guard let coverPath = rom.coverPath, !coverPath.isEmpty else { return nil }
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        if let qIndex = coverPath.firstIndex(of: "?") {
            comps.path = String(coverPath[coverPath.startIndex..<qIndex])
            let rawQuery = String(coverPath[coverPath.index(after: qIndex)...])
            comps.percentEncodedQuery = rawQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        } else {
            comps.path = coverPath
        }
        return comps.url
    }

    // MARK: - PlayStation transfer surface

    /// Single-ROM detail, which (unlike the library listing) carries `files[]`.
    /// Multi-file discs need it to enumerate every track.
    public func romDetails(id: Int) async throws -> RomDetails {
        try await get(RomDetails.self, path: "/api/roms/\(id)", query: [:])
    }

    /// BIOS images registered for a platform. Bare array response.
    public func firmware(platformID: Int) async throws -> [RommFirmware] {
        try await get([RommFirmware].self, path: "/api/firmware",
                      query: ["platform_id": String(platformID)])
    }

    /// Every save the server holds for a ROM, including ones this client did not
    /// write. Filtering to the active card is the caller's job.
    public func saves(romID: Int) async throws -> [RommSave] {
        try await get([RommSave].self, path: "/api/saves", query: ["rom_id": String(romID)])
    }

    /// Download request for one file of a multi-file ROM.
    ///
    /// `fileID` is the internal `RomFile.id`, **not** the parent ROM id — the
    /// route is `/api/roms/{rom_file_id}/files/content/{file_name}`. Passing the
    /// ROM id here fetches an unrelated file or 404s.
    public func romFileRequest(fileID: Int, fileName: String) -> URLRequest {
        authorizedRequest(url("/api/roms/\(fileID)/files/content", fileName: fileName))
    }

    public func firmwareContentRequest(id: Int, fileName: String) -> URLRequest {
        authorizedRequest(url("/api/firmware/\(id)/content", fileName: fileName))
    }

    public func saveContentRequest(id: Int) -> URLRequest {
        authorizedRequest(url("/api/saves/\(id)/content"))
    }

    /// Post a memory-card save.
    ///
    /// This client only ever sends the create shape: `POST /api/saves` with
    /// `overwrite=false`. It never issues the in-place `PUT /api/saves/{id}`,
    /// because that update API exposes no hash/ETag precondition and so cannot
    /// close a lost-update race. `overwrite=false` asks the server to refuse
    /// rather than clobber when the slot has moved on since the caller's last
    /// sync; `send` surfaces that refusal as `RommError.http(409)`, which a
    /// coordinator can catch to detect the newer-save case and reconcile.
    ///
    /// What RomM does with the row behind this request — append a version or
    /// update an existing one for the same `(rom_id, file_name, slot)` — is the
    /// server's business and is not asserted here; the caller must not assume
    /// each POST yields a distinct record. Active cards pass `autocleanup: true`
    /// so the server prunes to `autocleanupLimit` versions; conflict archives
    /// pass `autocleanup: false` and their own timestamped slot.
    ///
    /// `fileName` names the single `saveFile` part and defaults to the constant
    /// `RommClient.memoryCardFileName`; it is never derived from a game title.
    public func createSave(
        fileName: String = RommClient.memoryCardFileName,
        romID: Int,
        emulator: String,
        slot: String,
        deviceID: String,
        data: Data,
        autocleanup: Bool,
        autocleanupLimit: Int = 10
    ) async throws -> RommSave {
        var request = authorizedRequest(url("/api/saves", query: [
            "rom_id": String(romID),
            "emulator": emulator,
            "slot": slot,
            "device_id": deviceID,
            "overwrite": "false",
            "autocleanup": String(autocleanup),
            "autocleanup_limit": String(autocleanupLimit),
        ]))
        let boundary = "RommpleTVBoundary-\(UUID().uuidString)"
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(boundary: boundary, fieldName: "saveFile",
                                              fileName: fileName, fileData: data)
        return try await send(RommSave.self, request: request)
    }

    // MARK: - Request plumbing

    /// One multipart part carrying `fileData` verbatim. The boundary is
    /// generated per upload by the caller, and the credential is never written
    /// here — it travels only in the Authorization header set by
    /// `authorizedRequest`.
    private static func multipartBody(
        boundary: String, fieldName: String, fileName: String, fileData: Data
    ) -> Data {
        // Defence in depth: a quote or newline in the name would break out of
        // the quoted Content-Disposition value. Callers pass a constant.
        let safeName = fileName.filter { $0 != "\"" && !$0.isNewline }
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Everything legal in a URL path *except* `/`, so one server-supplied name
    /// stays one path component.
    private static let pathComponentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()

    /// Builds a URL from a trusted literal `path` plus at most one untrusted
    /// `fileName` component. The filename is percent-encoded with `/` excluded,
    /// so a space or `#` cannot truncate the URL and an embedded `/` (hence
    /// `../`) cannot add segments or traverse to another file. Query items are
    /// sorted by key for stable request shapes.
    private func url(_ path: String, fileName: String? = nil,
                     query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if let fileName {
            let encoded = fileName
                .addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed)!
            comps.percentEncodedPath += "/" + encoded
        }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [String: String]) async throws -> T {
        try await send(type, request: authorizedRequest(url(path, query: query)))
    }

    private func send<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RommError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw RommError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

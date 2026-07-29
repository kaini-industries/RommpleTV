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

    /// Content request for one save.
    ///
    /// `deviceID` is not decoration. RomM's download route takes `optimistic`
    /// (default true) and, **only when `device_id` is present**, records that this
    /// device now holds that save. That sync row is the sole evidence the server
    /// has of what a device is carrying, and the slot branch of `add_save`'s
    /// conflict check treats a *missing* row as a conflict — so a client that
    /// downloads without identifying itself gets HTTP 409 on its next upload to
    /// the slot, every time, forever. Fetching with the device id is one request;
    /// `POST /api/saves/{id}/downloaded` would be a second one doing the same job.
    ///
    /// `nil` omits the parameter entirely, which is required rather than tidy: an
    /// unknown device id is a 404 and an id sent by a token without the device
    /// scope is a 403, so a placeholder would break reading saves outright.
    public func saveContentRequest(id: Int, deviceID: String? = nil) -> URLRequest {
        let query = deviceID.map { ["device_id": $0] } ?? [:]
        return authorizedRequest(url("/api/saves/\(id)/content", query: query))
    }

    // MARK: - Device identity

    /// Devices RomM has registered for this user. Bare array response.
    public func devices() async throws -> [RommDevice] {
        try await get([RommDevice].self, path: "/api/devices", query: [:])
    }

    /// Registers this Apple TV, or returns the registration it already has.
    ///
    /// RomM dedups on a fingerprint: `(user, mac_address)` first, then
    /// `(user, hostname, platform)`. Only the latter is usable here — tvOS will
    /// not hand out a hardware address, and inventing one would take priority
    /// over the honest fingerprint and split into a new device row whenever the
    /// invented value changed. So `hostname` carries a stable per-install
    /// identifier and `platform` is constant, and `allow_existing` (the payload
    /// default, sent explicitly because it is load-bearing) makes a repeat
    /// registration answer 200 with the same `device_id` instead of 409.
    ///
    /// Deliberately not sent: `mac_address` and `ip_address` (see above; the
    /// latter is unreachable in RomM's fingerprint from this endpoint anyway),
    /// `allow_duplicate` (it would force a new row per launch), `reset_syncs`
    /// (it deletes every sync row this device has, which re-arms the slot-409 on
    /// every save it holds), and `sync_mode`/`sync_config` (server defaults).
    public func registerDevice(
        name: String, platform: String, client: String,
        clientVersion: String?, hostname: String
    ) async throws -> RommDeviceRegistration {
        var request = authorizedRequest(url("/api/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeviceRegistrationPayload(name: name, platform: platform, client: client,
                                      clientVersion: clientVersion, hostname: hostname))
        return try await send(RommDeviceRegistration.self, request: request)
    }

    /// Keys are spelled for RomM's `DeviceCreatePayload`. Encoded with no
    /// key-encoding strategy so the spelling is visible here rather than derived.
    private struct DeviceRegistrationPayload: Encodable {
        let name: String
        let platform: String
        let client: String
        let clientVersion: String?
        let hostname: String
        let allowExisting = true

        enum CodingKeys: String, CodingKey {
            case name, platform, client, hostname
            case clientVersion = "client_version"
            case allowExisting = "allow_existing"
        }
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
    /// What RomM does with the row behind this request is the server's business
    /// and is still not asserted here; the caller must not assume each POST yields
    /// a distinct record. (For the record, in RomM 5.0.0 a POST carrying a
    /// non-empty `slot` stamps the stored filename with a fresh
    /// `[YYYY-MM-DD_HH-MM-SS]` tag before the by-filename lookup, so slot uploads
    /// insert a new row and `autocleanup` genuinely prunes the slot; only
    /// slot-less uploads take the update-in-place branch. A caller that depends on
    /// either behaviour will break on a server that changes it.) Active cards pass
    /// `autocleanup: true` so the server prunes to `autocleanupLimit` versions;
    /// conflict archives pass `autocleanup: false` and their own timestamped slot.
    ///
    /// `deviceID` is optional because an unregistered device must send none at
    /// all: RomM 404s an id it does not know and 403s one the token has no device
    /// scope for, either of which would fail the upload outright. Sending nothing
    /// costs the server's conflict detection — both 409 branches require a
    /// resolved device — and nothing else.
    ///
    /// `fileName` names the single `saveFile` part and defaults to the constant
    /// `RommClient.memoryCardFileName`; it is never derived from a game title.
    public func createSave(
        fileName: String = RommClient.memoryCardFileName,
        romID: Int,
        emulator: String,
        slot: String,
        deviceID: String?,
        data: Data,
        autocleanup: Bool,
        autocleanupLimit: Int = 10
    ) async throws -> RommSave {
        var query = [
            "rom_id": String(romID),
            "emulator": emulator,
            "slot": slot,
            "overwrite": "false",
            "autocleanup": String(autocleanup),
            "autocleanup_limit": String(autocleanupLimit),
        ]
        if let deviceID { query["device_id"] = deviceID }
        var request = authorizedRequest(url("/api/saves", query: query))
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

import Foundation

public final class RommClient: @unchecked Sendable {
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
    public func romsPage(platformId: Int, limit: Int = 100,
                         offset: Int = 0) async throws -> (items: [Rom], total: Int?) {
        // RomM 5.x silently ignores the singular `platform_id` query param (returns the
        // whole library unfiltered). The working parameter is `platform_ids` (plural).
        // The ROM object's own field is still `platform_id` (singular); only this query
        // param differs.
        let page = try await get(RomsPage.self, path: "/api/roms", query: [
            "platform_ids": String(platformId), "limit": String(limit),
            "offset": String(offset), "order_by": "name", "order_dir": "asc",
        ])
        return (page.items, page.total)
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

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [String: String]) async throws -> T {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let (data, response) = try await session.data(for: authorizedRequest(comps.url!))
        guard let http = response as? HTTPURLResponse else { throw RommError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw RommError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

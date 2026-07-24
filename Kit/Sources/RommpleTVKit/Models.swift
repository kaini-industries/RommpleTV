import Foundation

public struct RommConfig: Sendable {
    public let baseURL: URL
    public let token: String
    public init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }
}

public struct Platform: Identifiable, Decodable, Sendable {
    public let id: Int
    public let slug: String
    public let name: String
    public let romCount: Int
    enum CodingKeys: String, CodingKey { case id, slug, name, romCount = "rom_count" }
}

public struct Rom: Identifiable, Decodable, Sendable {
    public let id: Int
    public let name: String?
    public let fsName: String
    public let platformId: Int
    public let sizeBytes: Int64?
    // RomM returns a full resource path for the small cover thumbnail. This is
    // optional because games may not have scraped artwork.
    public let coverPath: String?
    enum CodingKeys: String, CodingKey {
        case id, name, fsName = "fs_name", platformId = "platform_id",
             sizeBytes = "fs_size_bytes", coverPath = "path_cover_small"
    }
}

struct RomsPage: Decodable {   // handles both envelope and bare-array shapes
    let items: [Rom]
    let total: Int?            // envelope's library-wide count; nil for bare arrays
    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var roms: [Rom] = []
            while !unkeyed.isAtEnd { roms.append(try unkeyed.decode(Rom.self)) }
            items = roms
            total = nil
        } else {
            enum K: String, CodingKey { case items, total }
            let c = try decoder.container(keyedBy: K.self)
            items = try c.decode([Rom].self, forKey: .items)
            total = try c.decodeIfPresent(Int.self, forKey: .total)
        }
    }
}

public enum RommError: Error, Equatable {
    case http(Int)
    case badResponse
}

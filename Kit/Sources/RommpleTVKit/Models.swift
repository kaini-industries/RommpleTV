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

/// RomM's grouped-library summary of a sibling ROM (e.g. another region/revision
/// grouped under the same meta ID). This is deliberately not a full `Rom`: RomM's
/// `SiblingRomSchema` omits required top-level Rom fields such as `fs_name` and
/// `platform_id`, so decoding a sibling as `Rom` would fail.
public struct SiblingRom: Identifiable, Decodable, Sendable {
    public let id: Int
    // RomM's SiblingRomSchema.name is `str | None` — a sibling with no scraped
    // name is valid and must not fail the whole page decode.
    public let name: String?
    public let fsNameNoTags: String
    public let fsNameNoExt: String
    public let isMainSibling: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, fsNameNoTags = "fs_name_no_tags",
             fsNameNoExt = "fs_name_no_ext", isMainSibling = "is_main_sibling"
    }
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
    // Present only for grouped (group_by_meta_id) responses; absent roms decode to [].
    public let siblingRoms: [SiblingRom]
    // Scraped release regions (e.g. ["USA"]). Absent or unscraped roms decode to [].
    public let regions: [String]

    public init(id: Int, name: String?, fsName: String, platformId: Int, sizeBytes: Int64?,
                coverPath: String?, siblingRoms: [SiblingRom] = [], regions: [String] = []) {
        self.id = id
        self.name = name
        self.fsName = fsName
        self.platformId = platformId
        self.sizeBytes = sizeBytes
        self.coverPath = coverPath
        self.siblingRoms = siblingRoms
        self.regions = regions
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fsName = "fs_name", platformId = "platform_id",
             sizeBytes = "fs_size_bytes", coverPath = "path_cover_small",
             siblingRoms = "sibling_roms", regions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        fsName = try c.decode(String.self, forKey: .fsName)
        platformId = try c.decode(Int.self, forKey: .platformId)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        siblingRoms = try c.decodeIfPresent([SiblingRom].self, forKey: .siblingRoms) ?? []
        regions = try c.decodeIfPresent([String].self, forKey: .regions) ?? []
    }
}

/// One file belonging to a ROM, from `/api/roms/{id}`'s `files[]`. Multi-file
/// ROMs (a PS1 disc's `.cue` plus its tracks) are transferred file by file, and
/// each file is addressed by this `id` — the internal RomFile id, which is *not*
/// the parent ROM id. Only fields the transfer path consumes are modeled;
/// RomM sends several more.
public struct RomFile: Identifiable, Decodable, Sendable {
    public let id: Int
    public let fileName: String
    public let filePath: String
    public let sizeBytes: Int64
    public let isTopLevel: Bool
    // Integrity metadata is optional on RomM; unhashed files must still decode.
    public let crcHash: String?
    public let md5Hash: String?
    public let sha1Hash: String?
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, fileName = "file_name", filePath = "file_path",
             sizeBytes = "file_size_bytes", isTopLevel = "is_top_level",
             crcHash = "crc_hash", md5Hash = "md5_hash", sha1Hash = "sha1_hash",
             updatedAt = "updated_at"
    }
}

/// The single-ROM detail response, which — unlike the library listing — carries
/// the per-file breakdown needed to fetch every track of a multi-file disc.
public struct RomDetails: Decodable, Sendable {
    public let id: Int
    public let fsName: String
    public let files: [RomFile]

    enum CodingKeys: String, CodingKey {
        case id, fsName = "fs_name", files
    }
}

/// A BIOS image registered for a platform, with the integrity metadata a caller
/// needs to reject an unusable one (missing from disk, unverified, wrong hash).
public struct RommFirmware: Identifiable, Decodable, Sendable {
    public let id: Int
    public let fileName: String
    public let fileSizeBytes: Int64
    public let isVerified: Bool
    public let crcHash: String?
    public let md5Hash: String?
    public let sha1Hash: String?
    public let missingFromFS: Bool
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, fileName = "file_name", fileSizeBytes = "file_size_bytes",
             isVerified = "is_verified", crcHash = "crc_hash", md5Hash = "md5_hash",
             sha1Hash = "sha1_hash", missingFromFS = "missing_from_fs",
             updatedAt = "updated_at"
    }
}

/// A stored save record. `emulator`, `slot`, `contentHash` and `originDeviceID`
/// are optional because saves written by other clients carry no identity fields;
/// they must decode so the caller can filter them out rather than fail the list.
public struct RommSave: Identifiable, Decodable, Sendable {
    public let id: Int
    public let romID: Int
    public let fileName: String
    public let fileSizeBytes: Int64
    public let missingFromFS: Bool
    public let createdAt: String
    public let updatedAt: String
    public let emulator: String?
    public let slot: String?
    public let contentHash: String?
    public let originDeviceID: String?

    enum CodingKeys: String, CodingKey {
        case id, romID = "rom_id", fileName = "file_name",
             fileSizeBytes = "file_size_bytes", missingFromFS = "missing_from_fs",
             createdAt = "created_at", updatedAt = "updated_at", emulator, slot,
             contentHash = "content_hash", originDeviceID = "origin_device_id"
    }
}

/// Sort choices exposed to callers, mapped to RomM's `order_by`/`order_dir` query fields.
public enum RomSort: String, CaseIterable, Codable, Sendable {
    case titleAscending, titleDescending
    case dateAddedNewest, dateAddedOldest
    case lastUpdatedNewest, lastUpdatedOldest
    case sizeLargest, sizeSmallest
    public var title: String {
        switch self {
        case .titleAscending: "Title A–Z"
        case .titleDescending: "Title Z–A"
        case .dateAddedNewest: "Date added, newest"
        case .dateAddedOldest: "Date added, oldest"
        case .lastUpdatedNewest: "Last updated, newest"
        case .lastUpdatedOldest: "Last updated, oldest"
        case .sizeLargest: "File size, largest"
        case .sizeSmallest: "File size, smallest"
        }
    }
    var orderBy: String {
        switch self {
        case .titleAscending, .titleDescending: "name"
        case .dateAddedNewest, .dateAddedOldest: "created_at"
        case .lastUpdatedNewest, .lastUpdatedOldest: "updated_at"
        case .sizeLargest, .sizeSmallest: "fs_size_bytes"
        }
    }
    var orderDirection: String {
        switch self {
        case .titleAscending, .dateAddedOldest, .lastUpdatedOldest, .sizeSmallest: "asc"
        case .titleDescending, .dateAddedNewest, .lastUpdatedNewest, .sizeLargest: "desc"
        }
    }
}

/// One page of the library plus the server's total count (nil when the server
/// answered with a bare array) and the limit/offset that were requested, so
/// callers can page to completion and reissue the same request shape.
public struct RomPage: Sendable {
    public let items: [Rom]
    public let total: Int?
    public let limit: Int
    public let offset: Int

    /// Public so callers outside the module — an App-layer test double, a
    /// SwiftUI preview — can build a page without reaching the network.
    public init(items: [Rom], total: Int?, limit: Int, offset: Int) {
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
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

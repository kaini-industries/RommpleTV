import Foundation

public final class CacheManager: @unchecked Sendable {
    private let client: RommClient
    private let cacheRoot: URL
    private let session: URLSession

    public init(client: RommClient, cacheRoot: URL) {
        self.client = client
        self.cacheRoot = cacheRoot
        self.session = client.sessionForDownloads
    }

    public func cachedURL(for rom: Rom) -> URL? {
        let url = destination(for: rom)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let expectedSize = rom.sizeBytes {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let actualSize = (attributes?[.size] as? NSNumber)?.int64Value
            guard actualSize == expectedSize else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return url
    }

    /// Streams one ROM to `<dest>.part` and renames it into place.
    ///
    /// **Every exit that is not a completed file removes the part file.** That
    /// used to be true only by accident — nothing ever threw here in practice
    /// because nothing could cancel a download. A launch screen with a Cancel
    /// button changes that: backing out of a large transfer now happens on
    /// purpose, and a `.part` left behind is space in a purgeable cache that no
    /// later run reclaims, since `cachedURL` only ever looks at the final name.
    /// PlayStation staging has honoured this contract since Task 5; this is the
    /// legacy path honouring the same one.
    public func download(_ rom: Rom,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let hit = cachedURL(for: rom) { progress(1.0); return hit }
        let dest = destination(for: rom)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let request = client.authorizedRequest(
            client.romContentURL(id: rom.id, fsName: rom.fsName))
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RommError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw RommError.http(http.statusCode) }

        let expected = http.expectedContentLength   // -1 if unknown
        let partURL = dest.appendingPathExtension("part")
        do {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let file = try FileHandle(forWritingTo: partURL)
            // Runs as the error leaves this scope, so the handle is closed
            // before the `catch` below unlinks the file it was writing.
            defer { try? file.close() }
            var buffer = Data(); buffer.reserveCapacity(1 << 16)
            var written: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 16 {
                    try file.write(contentsOf: buffer)
                    written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                    if expected > 0 { progress(Double(written) / Double(expected)) }
                }
            }
            if !buffer.isEmpty {
                try file.write(contentsOf: buffer); written += Int64(buffer.count)
            }
            try file.close()
            try FileManager.default.moveItem(at: partURL, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
        progress(1.0)
        return dest
    }

    private func destination(for rom: Rom) -> URL {
        cacheRoot.appendingPathComponent(String(rom.id), isDirectory: true)
            .appendingPathComponent(rom.fsName, isDirectory: false)
    }
}

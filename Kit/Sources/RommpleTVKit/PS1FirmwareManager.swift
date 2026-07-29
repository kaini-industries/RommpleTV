import Foundation

// MARK: - Which BIOS a disc needs

/// The three PlayStation console regions Beetle PSX recognizes a BIOS for.
///
/// The core looks for one of three exact file names in its system directory and
/// picks by the disc's region itself. RommpleTV's job is only to make sure the
/// right one is *there*, which is why this type maps region tags to a role
/// rather than to a decision about which image the core will load.
public enum PS1BIOSRegion: String, Sendable, Equatable, CaseIterable {
    case japan
    case usa
    case europe

    /// Region tags this client is willing to act on, in normalized form.
    ///
    /// Deliberately short. RomM derives `regions` from filename tags and can
    /// answer with either a GoodTools code (`U`) or a name (`USA`), and the
    /// vocabulary is open-ended — `World`, `Asia`, `Korea`, `Brazil` and
    /// `Unknown` all occur. A tag that is not in this table is treated as
    /// unknown, which costs two extra BIOS files (1 MB) and never costs a wrong
    /// one. Every entry here is unambiguously one console region: the PAL
    /// entries are PAL territories, and nothing that could be either NTSC-J or
    /// PAL (`Asia`) is listed.
    private static let regionsByTag: [String: PS1BIOSRegion] = [
        "j": .japan, "jp": .japan, "jpn": .japan, "japan": .japan, "ntsc-j": .japan,

        "u": .usa, "us": .usa, "usa": .usa, "united-states": .usa,
        "north-america": .usa, "ntsc-u": .usa, "ntsc-u-c": .usa,

        "e": .europe, "eu": .europe, "eur": .europe, "europe": .europe,
        "pal": .europe, "pal-e": .europe, "uk": .europe, "england": .europe,
        "united-kingdom": .europe, "australia": .europe,
    ]

    /// The BIOS roles a game with these region tags needs.
    ///
    /// Exactly one recognized region gives one image. Anything else — no tags, a
    /// tag this client does not recognize, or tags naming two different regions —
    /// gives all three. A single unrecognized tag alongside a recognized one
    /// counts as unknown rather than as the half of the answer that was
    /// understood: `["USA", "Europe"]` and `["USA", "Asia"]` are both games whose
    /// region this client cannot pin down.
    public static func required(for regionTags: [String]) -> [PS1BIOSRegion] {
        var matched: Set<PS1BIOSRegion> = []
        for tag in regionTags {
            guard let region = regionsByTag[normalized(tag)] else { return allCases }
            matched.insert(region)
        }
        guard matched.count == 1, let only = matched.first else { return allCases }
        return [only]
    }

    /// Lowercased, with every run of space, `_`, `-` and `/` reduced to a single
    /// `-` and no separator at either end. `" USA "`, `"North_America"` and
    /// `"north america"` are one tag; so are `"NTSC-U"` and `"NTSC U"`.
    static func normalized(_ tag: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in tag.lowercased().unicodeScalars {
            let isSeparator = scalar == "_" || scalar == "-" || scalar == "/"
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSeparator {
                // Never leading, and never trailing: a separator is only emitted
                // once something follows it.
                pendingSeparator = !result.isEmpty
                continue
            }
            if pendingSeparator {
                result.unicodeScalars.append("-")
                pendingSeparator = false
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

// MARK: - What a BIOS is

/// The BIOS images this phase will install, keyed by the name the core looks for.
///
/// Two rules live here and nowhere else:
///
/// - **Selection is by name.** An entry names the file the core loads and the MD5
///   that file must have. The MD5 is only ever a *check*; it is never used to
///   find a file. The live server publishes `scph5552.bin` with `scph5502.bin`'s
///   MD5 and `scph7003.bin` with `scph5501.bin`'s, so a digest-keyed selector
///   would install an alias under a standard name and never notice.
/// - **The allow-list is closed.** `openbios.bin`, `ps1_rom.bin` and
///   `PSXONPSP660.BIN` are all on the live server, all verified and all 524,288
///   bytes, and all three need the core's Override BIOS option that this phase
///   does not enable. They are excluded because they are not in the allow-list;
///   `excludedFileNames` is the named tripwire for that, checked in
///   `entry(matching:)` so that adding one of these names to the table refuses at
///   the point of selection instead of shipping a BIOS the core cannot use.
///
/// Injectable so tests can exercise installation with a few hundred synthetic
/// bytes: the real MD5s cannot be satisfied without a real BIOS image, and this
/// repository never contains one. `PS1FirmwareManager`'s public initializers
/// always use `.playStation`.
struct PS1BIOSCatalog: Sendable, Equatable {

    /// One recognized image. `fileName` is the exact lowercase spelling written
    /// to the system directory, whatever case the server uses.
    struct Entry: Sendable, Equatable {
        let fileName: String
        /// Lowercase hexadecimal, the published MD5 of the standard image.
        let md5: String
    }

    let byteCount: Int64
    let japan: Entry
    let usa: Entry
    let europe: Entry
    /// Folded names this phase refuses to install under any circumstances.
    let excludedFileNames: Set<String>

    subscript(region: PS1BIOSRegion) -> Entry {
        switch region {
        case .japan: return japan
        case .usa: return usa
        case .europe: return europe
        }
    }

    var allEntries: [Entry] { [japan, usa, europe] }

    /// The image a server-supplied name refers to, or nil.
    ///
    /// Matching is case-insensitive because the server spells one of these names
    /// in uppercase; the answer is the catalogue's own lowercase entry, so the
    /// server's spelling never reaches the filesystem. A name that is a path, or
    /// that merely contains a recognized name, does not match: the comparison is
    /// whole-string equality after folding.
    func entry(matching remoteFileName: String) -> Entry? {
        let folded = CuePath.foldedKey(remoteFileName)
        guard !excludedFileNames.contains(folded) else { return nil }
        // Entry file names are already the folded spelling.
        return allEntries.first { $0.fileName == folded }
    }

    /// The shipped table. Sizes and digests are the published values for the
    /// retail SCPH-550x images; `PS1FirmwareManagerTests` pins every one of them.
    static let playStation = PS1BIOSCatalog(
        byteCount: 524_288,
        japan: Entry(fileName: "scph5500.bin", md5: "8dd7d5296a650fac7319bce665a6a53c"),
        usa: Entry(fileName: "scph5501.bin", md5: "490f666e1afb15b7362b406ed1cea246"),
        europe: Entry(fileName: "scph5502.bin", md5: "32736f17079d0b2b7024407c39bd3050"),
        excludedFileNames: ["openbios.bin", "ps1_rom.bin", "psxonpsp660.bin"])
}

// MARK: - Errors

/// Every way BIOS retrieval refuses. One case per rule, and every case names the
/// exact file the core is waiting for, because "your PlayStation BIOS is missing"
/// is not something a player can act on and "scph5501.bin is missing" is.
public enum PS1FirmwareError: Error, Equatable, Sendable, LocalizedError {

    /// Why one required image is not available from the server.
    public enum Rejection: Equatable, Sendable {
        /// No entry with this name at all — including when the server carries an
        /// alias with the right checksum under another name.
        case notOnServer
        /// RomM has the record but not the file.
        case missingFromStorage
        /// RomM has not matched the file against a known-good hash.
        case unverified
        case wrongSize(byteCount: Int64, expected: Int64)
        /// The server's own MD5 is not the standard image's. Caught before the
        /// transfer rather than after paying for it.
        case declaredChecksumMismatch(declared: String)
    }

    /// One required image the server cannot supply, and why. Thrown on its own by
    /// `select`, collected by `prepare`.
    public struct Unavailable: Error, Equatable, Sendable {
        public let fileName: String
        public let rejection: Rejection

        public init(fileName: String, rejection: Rejection) {
            self.fileName = fileName
            self.rejection = rejection
        }
    }

    /// What went wrong while fetching one image, in a form that survives being
    /// carried in an `Equatable` error. `network` keeps the `URLError.Code` so a
    /// caller can still tell "you are offline" from "the server refused".
    public enum FetchFailure: Equatable, Sendable {
        case integrity(FileIntegrityError)
        case network(URLError.Code)
        case other(String)

        init(_ error: Error) {
            if let integrity = error as? FileIntegrityError {
                self = .integrity(integrity)
            } else if let urlError = error as? URLError {
                self = .network(urlError.code)
            } else {
                self = .other(String(describing: error))
            }
        }
    }

    /// **Every** required image the server could not supply, in the order they
    /// were needed — not just the first. A player who has to add two BIOS files
    /// should make one trip to their server, not one trip per retry.
    case firmwareUnavailable([Unavailable])
    /// The image was selected but could not be fetched or did not check out.
    case fetchFailed(fileName: String, reason: FetchFailure)
    /// The verified bytes could not be moved into place. `code` is the `errno`
    /// from `rename(2)`.
    case installFailed(fileName: String, code: Int32)

    /// The core-recognized file names this failure is about.
    public var fileNames: [String] {
        switch self {
        case let .firmwareUnavailable(items):
            return items.map(\.fileName)
        case let .fetchFailed(fileName, _), let .installFailed(fileName, _):
            return [fileName]
        }
    }

    /// Whether this failure means the device could not reach the server, decided
    /// by the same rule `PS1PackageStore` uses so one screen classifies both.
    public var isLikelyConnectivityFailure: Bool {
        guard case let .fetchFailed(_, .network(code)) = self else { return false }
        return PS1PackageStore.isLikelyConnectivityError(URLError(code))
    }

    public var errorDescription: String? {
        switch self {
        case let .firmwareUnavailable(items):
            let described = items.map { "\"\($0.fileName)\" (\(Self.phrase($0.rejection)))" }
            guard described.count > 1 else {
                return "Your RomM server cannot supply the PlayStation BIOS file "
                    + "\(described.first ?? "")."
            }
            return "Your RomM server cannot supply \(described.count) PlayStation BIOS files: "
                + described.joined(separator: ", ") + "."
        case let .fetchFailed(fileName, reason):
            let detail: String
            switch reason {
            case let .integrity(error):
                detail = error.errorDescription ?? String(describing: error)
            case let .network(code):
                detail = "The download failed (network error \(code.rawValue))."
            case let .other(text):
                detail = text
            }
            return "RommpleTV could not fetch \"\(fileName)\". \(detail)"
        case let .installFailed(fileName, code):
            return "RommpleTV could not save \"\(fileName)\" (error \(code))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .firmwareUnavailable:
            return "Add verified copies of \(Self.list(fileNames)) to your RomM server's "
                + "PlayStation firmware, then try again."
        case .fetchFailed:
            return "Check your connection to your RomM server, then try again to get "
                + "\(Self.list(fileNames))."
        case .installFailed:
            return "Check that RommpleTV has room for \(Self.list(fileNames)), then try again."
        }
    }

    private static func phrase(_ rejection: Rejection) -> String {
        switch rejection {
        case .notOnServer:
            return "there is no file with that name"
        case .missingFromStorage:
            return "its file is missing from storage"
        case .unverified:
            return "it is not verified"
        case let .wrongSize(byteCount, expected):
            return "it is \(byteCount) bytes rather than \(expected)"
        case let .declaredChecksumMismatch(declared):
            return "its checksum \(declared) is not the standard one"
        }
    }

    /// `"a"`, `"a and b"`, `"a, b and c"` — a sentence, not a debug dump.
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

// MARK: - The manager

/// Puts the PlayStation BIOS files a disc needs into the directory the core reads.
///
/// ```text
/// <cacheRoot>/ps1/system/
///   scph5500.bin
///   scph5501.bin
///   scph5502.bin
///   scph550x.bin.part-<uuid>   (only while a transfer is in flight)
/// ```
///
/// The property everything else is arranged around: **a failure never costs a
/// BIOS that already works.** That is structural here rather than careful:
/// *nothing in this file deletes anything*. There is no cleanup path, no
/// rollback and no `removeItem` at all. A validated image can only be replaced by
/// another image of the same name whose bytes have already been verified against
/// the same MD5, and the replacement is a single `rename(2)`, which is atomic and
/// needs no prior unlink. Removing the `.part` file after a failed transfer is
/// the downloader's business, not this type's.
///
/// The second property: **a complete local set costs nothing.** `prepare`
/// validates what is on disk before it touches any seam, and returns without a
/// list call, a content request or a HEAD when every required image is already
/// there. An Apple TV with the BIOS cached can start a game with the server off.
///
/// **Concurrent preparations do not need to be prevented, and are not.** The
/// actor protects this type's own state; it does *not* serialize `prepare`
/// against itself. Actors are reentrant and isolation is released at every
/// `await`, of which `prepare` has two (the firmware list, and each transfer), so
/// two calls on one instance interleave — as do two managers over one cache root.
/// What makes that safe is that they share no mutable filesystem state: each
/// transfer writes to its own `part-<uuid>` path, so neither can truncate the
/// other's bytes, and each install is an atomic `rename(2)`. Both verify
/// independently against the same standard MD5, both installs succeed, and the
/// last writer wins with an image that is by definition the same bytes.
public actor PS1FirmwareManager {

    /// `Caches/ps1/system`, the directory handed to `LibretroCore`.
    static let platformDirectoryName = "ps1"
    static let systemDirectoryName = "system"

    /// Where the core looks for its BIOS. Immutable and `Sendable`, so callers
    /// read it without awaiting.
    public nonisolated let systemDirectory: URL

    private let catalog: PS1BIOSCatalog
    private let loadFirmware: @Sendable (Int) async throws -> [RommFirmware]
    private let buildRequest: @Sendable (Int, String) -> URLRequest
    private let transfer: PS1FileTransfer

    /// - Parameters:
    ///   - cacheRoot: the app's Caches directory; the manager owns `ps1/system`
    ///     under it.
    ///   - loadFirmware: a platform's firmware list, i.e.
    ///     `RommClient.firmware(platformID:)`. The platform id is supplied per
    ///     call by the caller, which discovered it from `/api/platforms`; nothing
    ///     here knows or assumes a platform id.
    ///   - buildRequest: `(RommFirmware.id, RommFirmware.fileName)` to a content
    ///     request, i.e. `RommClient.firmwareContentRequest(id:fileName:)`.
    ///   - transfer: one verified streaming download; see `PS1FileTransfer`.
    public init(cacheRoot: URL,
                loadFirmware: @escaping @Sendable (Int) async throws -> [RommFirmware],
                buildRequest: @escaping @Sendable (Int, String) -> URLRequest,
                transfer: @escaping PS1FileTransfer) throws {
        try self.init(cacheRoot: cacheRoot, catalog: .playStation, loadFirmware: loadFirmware,
                      buildRequest: buildRequest, transfer: transfer)
    }

    /// The catalogue is injectable for tests only, and only ever `.playStation`
    /// in production: the real MD5s cannot be satisfied by a synthetic payload,
    /// and no BIOS image is committed to this repository.
    init(cacheRoot: URL,
         catalog: PS1BIOSCatalog,
         loadFirmware: @escaping @Sendable (Int) async throws -> [RommFirmware],
         buildRequest: @escaping @Sendable (Int, String) -> URLRequest,
         transfer: @escaping PS1FileTransfer) throws {
        let directory = cacheRoot
            .appendingPathComponent(Self.platformDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.systemDirectoryName, isDirectory: true)
        self.systemDirectory = directory
        self.catalog = catalog
        self.loadFirmware = loadFirmware
        self.buildRequest = buildRequest
        self.transfer = transfer
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A `RommClient`-backed manager, which is how the app builds one.
    public init(client: RommClient, cacheRoot: URL) throws {
        let downloader = StreamingFileDownloader(session: client.sessionForDownloads)
        try self.init(
            cacheRoot: cacheRoot,
            loadFirmware: { [client] platformID in
                try await client.firmware(platformID: platformID)
            },
            buildRequest: { [client] id, fileName in
                client.firmwareContentRequest(id: id, fileName: fileName)
            },
            transfer: { request, partURL, expected, progress in
                try await downloader.download(request: request, to: partURL,
                                              expected: expected, progress: progress)
            })
    }

    // MARK: - Preparation

    /// Makes sure the BIOS files `rom` needs are installed, and answers the
    /// directory to hand `LibretroCore`.
    ///
    /// The platform id comes from the ROM the caller is launching, which RomM
    /// assigned and the client discovered from `/api/platforms`. Nothing is
    /// hard-coded.
    public func prepare(
        for rom: Rom,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void = { _ in }
    ) async throws -> URL {
        try await prepare(platformID: rom.platformId, regions: rom.regions, progress: progress)
    }

    public func prepare(
        platformID: Int,
        regions: [String],
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void = { _ in }
    ) async throws -> URL {
        let required = PS1BIOSRegion.required(for: regions).map { catalog[$0] }

        // Step 1 — what is already on disk, checked against the standard MD5s.
        // No seam is touched in this loop: if every required image is here, this
        // function returns having made no request of any kind.
        var missing: [PS1BIOSCatalog.Entry] = []
        for entry in required {
            try Task.checkCancellation()
            progress(.validating(label: entry.fileName))
            if !isInstalled(entry) { missing.append(entry) }
        }
        // `digest(ofFileAt:)` reports a cancelled hash as "unverifiable", which
        // reads as missing. Throw before that answer can be acted on.
        try Task.checkCancellation()
        guard !missing.isEmpty else { return systemDirectory }

        // Step 2 — the platform's firmware list.
        let published = try await loadFirmware(platformID)

        // Step 3 — one usable row per missing image, chosen by recognized name.
        // Every selection happens before the first transfer, so a set that cannot
        // be completed costs no bandwidth and installs nothing — and every image
        // that cannot be resolved is named in the one error, so the player fixes
        // their server once instead of once per retry.
        var selections: [(entry: PS1BIOSCatalog.Entry, firmware: RommFirmware)] = []
        var unavailable: [PS1FirmwareError.Unavailable] = []
        for entry in missing {
            do {
                selections.append((entry, try select(entry, from: published)))
            } catch let refusal as PS1FirmwareError.Unavailable {
                unavailable.append(refusal)
            }
        }
        guard unavailable.isEmpty else {
            throw PS1FirmwareError.firmwareUnavailable(unavailable)
        }

        // Step 4 — transfer, verify, install. One file at a time: each one that
        // lands is one the next call will not have to fetch, even if a later one
        // fails.
        let reporter = PS1TransferProgress(
            completed: 0, total: catalog.byteCount * Int64(selections.count), report: progress)
        for selection in selections {
            try Task.checkCancellation()
            reporter.begin(selection.entry.fileName)
            try await install(selection.firmware, as: selection.entry, reporter: reporter)
            reporter.finish(catalog.byteCount)
        }
        return systemDirectory
    }

    // MARK: - What is already here

    /// Whether the file at this entry's name is that entry's image.
    ///
    /// A plain file of the right length whose MD5 is the standard one, and
    /// nothing else. A symlink is not a BIOS however good its target is: the
    /// system directory is the core's, and a link planted in it would make the
    /// core read a file this manager never verified.
    func isInstalled(_ entry: PS1BIOSCatalog.Entry) -> Bool {
        let url = url(for: entry)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              // A `stat` before a hash: the common failure is a truncated or
              // purged file, and there is no reason to read one to find out.
              (attributes[.size] as? NSNumber)?.int64Value == catalog.byteCount,
              let digest = Self.digest(ofFileAt: url)
        else { return false }
        return digest.size == catalog.byteCount && digest.md5 == entry.md5
    }

    private func url(for entry: PS1BIOSCatalog.Entry) -> URL {
        // The catalogue's spelling, never the server's, and never a path: these
        // names are compile-time constants and cannot escape the directory.
        systemDirectory.appendingPathComponent(entry.fileName, isDirectory: false)
    }

    /// Streams a file past all three hashes; never holds more than one chunk.
    ///
    /// Returns nil when the task is cancelled, which reads as "this file could
    /// not be verified" — `prepare` checks for cancellation immediately
    /// afterwards, so that answer is never acted on.
    static func digest(ofFileAt url: URL) -> FileDigest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = IncrementalFileDigest()
        while true {
            if Task.isCancelled { return nil }
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 16) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            digest.update(chunk)
        }
        return digest.finalized()
    }

    // MARK: - Selection

    /// The row to fetch for one required image, or a throw naming the rule.
    ///
    /// Candidates are the rows whose name folds to *this entry's* name. The MD5
    /// takes no part in finding them — see `PS1BIOSCatalog` — so an alias that
    /// duplicates a required checksum under another name is invisible here.
    ///
    /// A server may list the same name twice. Rather than refusing, the first
    /// acceptable candidate is taken, preferring the exact lowercase spelling and
    /// then the lowest id, so the choice is deterministic. Guessing is safe here
    /// in a way it is not elsewhere: whichever row is chosen, its bytes are
    /// verified against the standard MD5 before they are installed, so a wrong
    /// guess can only fail the fetch — it cannot install the wrong file.
    func select(_ entry: PS1BIOSCatalog.Entry,
                from published: [RommFirmware]) throws -> RommFirmware {
        let candidates = published
            .filter { catalog.entry(matching: $0.fileName)?.fileName == entry.fileName }
            .sorted { left, right in
                let leftExact = left.fileName == entry.fileName
                let rightExact = right.fileName == entry.fileName
                if leftExact != rightExact { return leftExact }
                return left.id < right.id
            }
        guard let first = candidates.first else {
            throw PS1FirmwareError.Unavailable(fileName: entry.fileName, rejection: .notOnServer)
        }
        if let usable = candidates.first(where: { rejection(of: $0, as: entry) == nil }) {
            return usable
        }
        // Every candidate failed. Report the front-runner's reason, which is the
        // one the player would otherwise have to guess at.
        throw PS1FirmwareError.Unavailable(fileName: entry.fileName,
                                           rejection: rejection(of: first, as: entry)!)
    }

    /// The single rule this row breaks, in a fixed order so a failure is
    /// reproducible, or nil if it breaks none.
    func rejection(of firmware: RommFirmware,
                   as entry: PS1BIOSCatalog.Entry) -> PS1FirmwareError.Rejection? {
        if firmware.missingFromFS { return .missingFromStorage }
        if !firmware.isVerified { return .unverified }
        guard firmware.fileSizeBytes == catalog.byteCount else {
            return .wrongSize(byteCount: firmware.fileSizeBytes, expected: catalog.byteCount)
        }
        // A checksum the server supplies is checked against the standard one
        // here, before the transfer. A row that supplies none is not refused:
        // the bytes are checked against the standard MD5 either way, which is
        // the stronger claim.
        if let declared = firmware.md5Hash, declared.lowercased() != entry.md5 {
            return .declaredChecksumMismatch(declared: declared)
        }
        return nil
    }

    // MARK: - Transfer and install

    /// Streams one image to its own `part-<uuid>` file and renames it into place.
    ///
    /// Everything the transfer stage can throw is rewritten to carry
    /// `entry.fileName`. A `digestMismatch` on a SHA-1 the server published, or a
    /// `malformedDigest` from a row whose `sha1_hash` is `""` rather than absent,
    /// are both reachable and neither names a file on its own; a player told "the
    /// download's SHA-1 is wrong" cannot act, and one told "scph5501.bin did not
    /// check out" can. Cancellation is the exception and is never rewritten: it is
    /// a decision, not a failure, and a caller distinguishes it by type.
    private func install(_ firmware: RommFirmware,
                         as entry: PS1BIOSCatalog.Entry,
                         reporter: PS1TransferProgress) async throws {
        do {
            // The standard MD5 rather than the server's: they have already been
            // checked to agree when the server supplied one, and a server that
            // supplies none must not be able to skip the check. The size is the
            // catalogue's for the same reason. Every other hash the server did
            // supply is checked too — one it sent and we ignored is a corruption
            // we chose not to catch.
            let expected = try ExpectedFileIntegrity(size: catalog.byteCount,
                                                     sha1: firmware.sha1Hash,
                                                     md5: entry.md5,
                                                     crc32: firmware.crcHash)
            let destination = url(for: entry)
            // Unique per attempt. Two preparations that both want this image run
            // concurrently — the actor does not stop them — and a shared part
            // path would let the second `createPartFile` truncate the first's
            // bytes while its file descriptor kept writing past the end, so both
            // could verify their own in-memory digest over a file that is
            // neither. Uniqueness is what makes reentrancy a non-event.
            let partURL = destination.appendingPathExtension("part-\(UUID().uuidString)")
            let request = buildRequest(firmware.id, firmware.fileName)
            // The digest the transfer returns provably describes the bytes at the
            // part path (Task 5 pinned that), so the file is installed without
            // being read a second time.
            _ = try await transfer(request, partURL, expected) { written in
                reporter.update(written)
            }
            try Self.install(partURL, at: destination, named: entry.fileName)
        } catch let error as PS1FirmwareError {
            throw error                 // `installFailed` already names the file.
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PS1FirmwareError.fetchFailed(fileName: entry.fileName,
                                               reason: .init(error))
        }
    }

    /// Moves a verified image onto its final name.
    ///
    /// `rename(2)` rather than `FileManager.moveItem`, which refuses an existing
    /// destination and would force a remove-then-move. A remove at a BIOS path is
    /// the one operation this file must never contain: it is what turns an
    /// interrupted replacement into a lost BIOS. `rename` replaces atomically —
    /// the name refers to the old file or the new one and never to nothing — and
    /// operates on the destination link itself, so a symlink someone planted
    /// there is replaced rather than written through.
    ///
    /// A failure here leaves the verified bytes at the part path. They are not
    /// deleted, for the same reason nothing else here is — removing anything from
    /// this directory is the operation this file refuses to contain. Since part
    /// paths are now unique per attempt, that costs one 512 KB file per failed
    /// install rather than one in total; it is bounded by the number of installs a
    /// player retries, it sits in a purgeable Caches directory, and a `part-`
    /// suffix is never a name the core loads.
    static func install(_ partURL: URL, at destination: URL, named fileName: String) throws {
        let code: Int32 = partURL.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return EINVAL }
                return rename(source, target) == 0 ? 0 : errno
            }
        }
        guard code == 0 else {
            throw PS1FirmwareError.installFailed(fileName: fileName, code: code)
        }
    }
}

import CryptoKit
import Foundation

// MARK: - Public surface

/// A PlayStation game that is on disk, complete, and ready to hand to the core.
public struct PS1PreparedPackage: Sendable {
    /// The `game.m3u` inside the canonical package directory.
    public let launchURL: URL
    public let canonicalRomID: Int
    /// Disc labels in playlist order.
    public let discLabels: [String]
    /// Bytes of disc content in the package (cues, tracks, SBI); the playlist and
    /// the manifest are not counted.
    public let totalBytes: Int64
}

public enum PS1PreparationProgress: Sendable {
    case planning
    case checkingSpace(required: Int64)
    case downloading(label: String, completed: Int64, total: Int64)
    case validating(label: String)
    case promoting
}

/// Every way package preparation refuses. Fine-grained on purpose: each case names
/// the single rule that fired, so a test can pin one rule at a time and the player
/// gets a sentence rather than a code.
public enum PS1PackageError: Error, Equatable, Sendable, LocalizedError {
    case noDiscs
    case duplicateDiscIndex(Int)
    /// The disc has no top-level files at all.
    case noLaunchFile(label: String)
    /// The disc has top-level files, but none of them is a `.cue`.
    case unsupportedLaunchFile(label: String, fileName: String)
    case multipleLaunchFiles(label: String, names: [String])
    case multipleSubchannelFiles(label: String, names: [String])
    /// The server declared a cue larger than a cue sheet can be. Refused before
    /// the transfer, not after paying for it.
    case launchFileTooLarge(label: String, byteCount: Int64, limit: Int)
    case unsafeRemoteFileName(String, rejection: CueSheetError.Rejection)
    /// A server-supplied name that is a path rather than a file name.
    case remoteFileNameIsAPath(String)
    case collidingPackagePaths(String, String)
    case duplicateRemoteFile(id: Int, paths: [String])
    case insufficientCapacity(required: Int64, available: Int64)
    case emptyPlaylist(discCount: Int)
    case stagedFileMissing(String)
    case stagedFileWrongSize(String, expected: Int64, actual: Int64)
    case stagedPackageInvalid(String)
    /// Promotion failed *and* the rollback failed. The canonical directory is gone
    /// and the previous package is sitting in `backupName`; the next initialization
    /// puts it back.
    case packageDamaged(canonicalRomID: Int, backupName: String)

    public var errorDescription: String? {
        switch self {
        case .noDiscs:
            return "This game has no discs to prepare."
        case let .duplicateDiscIndex(index):
            return "This game lists disc \(index) twice."
        case let .noLaunchFile(label):
            return "The server lists no files for \(label)."
        case let .unsupportedLaunchFile(label, fileName):
            return "\(label) is stored as \"\(fileName)\". RommpleTV plays cue/bin discs only."
        case let .multipleLaunchFiles(label, names):
            return "\(label) has \(names.count) cue sheets (\(names.joined(separator: ", "))). "
                + "RommpleTV will not guess which one is the disc."
        case let .multipleSubchannelFiles(label, names):
            return "\(label) has \(names.count) subchannel files "
                + "(\(names.joined(separator: ", "))). RommpleTV will not guess which one to use."
        case let .launchFileTooLarge(label, byteCount, limit):
            return "The cue sheet the server lists for \(label) is \(byteCount) bytes; "
                + "a cue sheet larger than \(limit) bytes is not a cue sheet RommpleTV will read."
        case let .unsafeRemoteFileName(name, rejection):
            return CueSheetError.unsafeReference(name, rejection: rejection).errorDescription
        case let .remoteFileNameIsAPath(name):
            return "The server named a file \"\(name)\", which is a path and not a file name."
        case let .collidingPackagePaths(first, second):
            return "This game needs \"\(first)\" and \"\(second)\" saved to the same place."
        case let .duplicateRemoteFile(id, paths):
            return "The server file \(id) would be saved to \(paths.count) different places "
                + "(\(paths.joined(separator: ", ")))."
        case let .insufficientCapacity(required, available):
            return "This game needs \(required) bytes and only \(available) bytes are free."
        case let .emptyPlaylist(discCount):
            return "RommpleTV could not write a playlist for this game's \(discCount) disc(s)."
        case let .stagedFileMissing(path):
            return "\"\(path)\" is missing from the downloaded game."
        case let .stagedFileWrongSize(path, expected, actual):
            return "\"\(path)\" should be \(expected) bytes and is \(actual)."
        case let .stagedPackageInvalid(reason):
            return "The downloaded game did not check out (\(reason))."
        case let .packageDamaged(canonicalRomID, backupName):
            return "Installing game \(canonicalRomID) failed part-way. The previous copy is "
                + "in \"\(backupName)\" and RommpleTV will restore it the next time it starts."
        }
    }
}

/// Why a canonical package on disk is not usable as-is. Not thrown: an invalid
/// package is a reason to rebuild, not a reason to fail.
enum PS1PackageInvalidation: Error, Equatable, Sendable {
    case noManifest
    case unreadableManifest
    case unsupportedManifestVersion(Int)
    case wrongCanonicalRom(expected: Int, found: Int)
    case discSetChanged
    case playlistMismatch
    case missingFile(String)
    case wrongSize(String, expected: Int64, actual: Int64)
    case hashMismatch(String)
}

// MARK: - Manifest

/// What was installed, recorded so the next `prepare` can decide "unchanged" and
/// "intact" without downloading anything.
///
/// Two halves per file, deliberately not merged. The `remote*` half is what the
/// server said when the file was fetched and is what a fresh `RomDetails` is
/// compared against; the `local*` half is what the bytes on disk turned out to be
/// and is what a mutation check is compared against. A server that changes a hash
/// and a filesystem that changes a file are different events with different
/// answers, and one field cannot mean both.
struct PS1PackageManifest: Codable, Equatable, Sendable {
    /// Bumped whenever the recorded fields change meaning. An older or newer
    /// manifest invalidates rather than being read optimistically.
    static let currentVersion = 1

    struct File: Codable, Equatable, Sendable {
        let remoteID: Int
        let remoteFileName: String
        let remoteSizeBytes: Int64
        let remoteUpdatedAt: String
        let remoteCRC32: String?
        let remoteMD5: String?
        let remoteSHA1: String?
        /// Package-relative destination, e.g. `disc-01/track01.bin`.
        let path: String
        let localSizeBytes: Int64
        let localModifiedAt: Double
        /// Computed while the bytes were written, so a rehash has something to
        /// compare against even when the server supplied no SHA-1.
        let localSHA1: String
    }

    struct Disc: Codable, Equatable, Sendable {
        let romID: Int
        let index: Int
        let label: String
        let directory: String
        let cuePath: String
        let subchannelPath: String?
        let files: [File]
    }

    let version: Int
    let canonicalRomID: Int
    let totalBytes: Int64
    /// Package-relative cue paths, in playlist order; byte-for-byte the input
    /// `game.m3u` was written from.
    let playlist: [String]
    let discs: [Disc]

    /// Reads only the version, so a manifest this build cannot decode still
    /// produces "wrong version" rather than "corrupt".
    struct VersionProbe: Decodable {
        let version: Int
    }
}

/// One transfer, as `StreamingFileDownloader.download(request:to:expected:progress:)`
/// performs it. The seam is a closure so a test never needs a network, and so the
/// store's own failure paths can be driven without a server that misbehaves.
public typealias PS1FileTransfer = @Sendable (
    _ request: URLRequest,
    _ partURL: URL,
    _ expected: ExpectedFileIntegrity,
    _ progress: @Sendable (Int64) -> Void
) async throws -> FileDigest

/// The two points inside promotion, in order. Promotion is the one moment the
/// canonical directory is not intact, and neither of its failure branches can be
/// reached from outside: a directory this process just renamed can always be
/// renamed back. The seam exists so rollback is *proved* rather than argued — the
/// same reason `StreamingFileDownloader` exposes its write loop.
enum PS1PromotionStage: Sendable, Equatable {
    /// Canonical intact, staging complete.
    case beforeBackup
    /// Canonical renamed aside; nothing is at the canonical path. This is the
    /// window a power cut can land in, and the one initialization repairs.
    case afterBackup
}

/// Cumulative byte progress across a whole preparation, safe to update from
/// whatever thread the transfer's progress callback runs on.
final class PS1TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int64
    private var label = ""
    private let total: Int64
    private let report: @Sendable (PS1PreparationProgress) -> Void

    init(completed: Int64, total: Int64,
         report: @escaping @Sendable (PS1PreparationProgress) -> Void) {
        self.completed = completed
        self.total = total
        self.report = report
    }

    func begin(_ label: String) {
        lock.lock(); self.label = label; lock.unlock()
    }

    /// `written` is cumulative **for the file currently in flight**.
    func update(_ written: Int64) {
        lock.lock()
        let snapshot = min(completed + written, total)
        let name = label
        lock.unlock()
        report(.downloading(label: name, completed: snapshot, total: total))
    }

    func finish(_ size: Int64) {
        lock.lock()
        completed = min(completed + size, total)
        let snapshot = completed
        let name = label
        lock.unlock()
        report(.downloading(label: name, completed: snapshot, total: total))
    }
}

// MARK: - The store

/// Turns a classified `PS1Game` into a directory the core can launch.
///
/// ```text
/// <cacheRoot>/games/psx/
///   <canonical-rom-id>/
///     game.m3u
///     package.json
///     disc-01/<cue and tracks>
///     disc-02/<cue and tracks>
///   .staging-<canonical-rom-id>-<uuid>/
///   .backup-<canonical-rom-id>-<uuid>/   (only inside promotion)
/// ```
///
/// The property everything else is arranged around: **a failed, cancelled or
/// interrupted rebuild never damages a working package.** A missing package costs
/// a re-download; a half-written one costs a re-download that the player cannot
/// ask for because the game looks installed. So nothing is ever written into the
/// canonical directory. A rebuild is assembled in a private staging directory and
/// installed with two renames, and the window between those renames is the only
/// state that needs repairing — which initialization does.
///
/// One store per cache root. Initialization deletes every staging directory it
/// finds, so two live stores over one root would delete each other's work.
public actor PS1PackageStore {

    // MARK: Layout

    static let platformDirectoryName = "psx"
    static let manifestFileName = "package.json"
    static let playlistFileName = "game.m3u"
    static let stagingPrefix = ".staging-"
    static let backupPrefix = ".backup-"

    /// What a disc is allowed to be made of. Anything else the server lists for a
    /// ROM — artwork, notes, a manual — is not disc content, is not fetched and is
    /// not counted against capacity.
    static let contentExtensions: Set<String> = ["cue", "bin", "sbi"]

    /// Held back on every capacity check so a package that *just* fits does not
    /// leave the device with nowhere to write a save, a log or a BIOS.
    public static let capacitySafetyReserveBytes: Int64 = 64 << 20

    // MARK: Seams

    let platformRoot: URL
    private let loadDetails: @Sendable (Int) async throws -> RomDetails
    private let buildRequest: @Sendable (Int, String) -> URLRequest
    private let transfer: PS1FileTransfer
    private let availableCapacity: @Sendable () throws -> Int64
    private let isConnectivityError: @Sendable (Error) -> Bool
    /// Test-only; see `PS1PromotionStage`.
    private var promotionProbe: (@Sendable (PS1PromotionStage) throws -> Void)?

    func setPromotionProbe(_ probe: (@Sendable (PS1PromotionStage) throws -> Void)?) {
        promotionProbe = probe
    }

    /// - Parameters:
    ///   - cacheRoot: the app's Caches directory; the store owns `games/psx` under it.
    ///   - loadDetails: single-ROM detail load, i.e. `RommClient.romDetails(id:)`.
    ///   - buildRequest: `(RomFile.id, RomFile.fileName)` to a content request, i.e.
    ///     `RommClient.romFileRequest(fileID:fileName:)`. The **file** id, never the
    ///     parent ROM id.
    ///   - transfer: one verified streaming download; see `PS1FileTransfer`.
    ///   - availableCapacity: free bytes on the cache volume. `nil` measures the
    ///     real volume.
    ///   - isConnectivityError: decides whether a metadata failure means "you are
    ///     offline" (fall back to the cached package) or "something is wrong"
    ///     (surface it). Injected because the answer depends on the transport.
    public init(cacheRoot: URL,
                loadDetails: @escaping @Sendable (Int) async throws -> RomDetails,
                buildRequest: @escaping @Sendable (Int, String) -> URLRequest,
                transfer: @escaping PS1FileTransfer,
                availableCapacity: (@Sendable () throws -> Int64)? = nil,
                isConnectivityError: @escaping @Sendable (Error) -> Bool
                    = { PS1PackageStore.isLikelyConnectivityError($0) }) throws {
        let root = cacheRoot.appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent(Self.platformDirectoryName, isDirectory: true)
        self.platformRoot = root
        self.loadDetails = loadDetails
        self.buildRequest = buildRequest
        self.transfer = transfer
        self.availableCapacity = availableCapacity ?? { try Self.freeBytes(on: root) }
        self.isConnectivityError = isConnectivityError

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Repair first as a matter of intent rather than necessity: the sweep
        // matches `stagingPrefix` and a backup carries `backupPrefix`, so the two
        // cannot collide today. Restoring a package before reclaiming space is
        // still the order to write down.
        Self.repairInterruptedPromotions(in: root)
        Self.removeAbandonedStaging(in: root)
    }

    /// A `RommClient`-backed store, which is how the app builds one.
    public init(client: RommClient, cacheRoot: URL) throws {
        let downloader = StreamingFileDownloader(session: client.sessionForDownloads)
        try self.init(
            cacheRoot: cacheRoot,
            loadDetails: { [client] id in try await client.romDetails(id: id) },
            buildRequest: { [client] fileID, fileName in
                client.romFileRequest(fileID: fileID, fileName: fileName)
            },
            transfer: { request, partURL, expected, progress in
                try await downloader.download(request: request, to: partURL,
                                              expected: expected, progress: progress)
            })
    }

    // MARK: - Preparation

    /// The twelve steps, in order. Every `return` before the end is a cache hit;
    /// every `throw` before promotion leaves the canonical directory untouched.
    public func prepare(
        _ game: PS1Game,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void = { _ in }
    ) async throws -> PS1PreparedPackage {
        progress(.planning)
        try Task.checkCancellation()
        let discs = try Self.orderedDiscs(of: game)
        let canonical = platformRoot.appendingPathComponent(String(game.canonicalRomID),
                                                            isDirectory: true)

        // Step 1 — is what is already on disk still a package?
        let cached = try? Self.validatePackage(at: canonical, for: game).get()
        // Step 1 can stream-hash a whole disc. `sha1OfFile` stops between chunks
        // when the task is cancelled and reports the file as unverifiable, so this
        // check has to come before that answer is mistaken for a stale package.
        try Task.checkCancellation()

        // Step 2 — refresh metadata for every disc.
        let details: [RomDetails]
        do {
            var loaded: [RomDetails] = []
            for disc in discs {
                try Task.checkCancellation()
                loaded.append(try await loadDetails(disc.romID))
            }
            details = loaded
        } catch {
            // Cancellation is not connectivity, whatever the classifier says and
            // whatever shape the error arrived in. A player who backed out must not
            // be handed a package as though nothing happened.
            if error is CancellationError { throw error }
            if Task.isCancelled { throw CancellationError() }
            guard let cached, isConnectivityError(error) else { throw error }
            return Self.package(from: cached, at: canonical)
        }

        // Step 3 — pick each disc's cue, then decide whether anything moved.
        var selections: [DiscSelection] = []
        for (disc, detail) in zip(discs, details) {
            selections.append(try Self.select(disc: disc, from: detail))
        }
        if let cached, Self.isUnchanged(cached, against: selections) {
            return Self.package(from: cached, at: canonical)
        }

        // Step 4 — conservative preflight, before a single content request.
        let conservative = selections.reduce(Int64(0)) { $0 + $1.candidateContentBytes }
            + Self.capacitySafetyReserveBytes
        progress(.checkingSpace(required: conservative))
        try Self.requireCapacity(conservative, availableCapacity)

        // Steps 5–12 all happen inside a staging directory that is removed on any
        // failure. Nothing below this line touches the canonical directory until
        // `promote`.
        try Task.checkCancellation()
        let staging = platformRoot.appendingPathComponent(
            "\(Self.stagingPrefix)\(game.canonicalRomID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            return try await build(game: game, selections: selections, staging: staging,
                                   canonical: canonical, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func build(
        game: PS1Game,
        selections: [DiscSelection],
        staging: URL,
        canonical: URL,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> PS1PreparedPackage {
        var digests: [Int: FileDigest] = [:]

        // Step 5 — the cues first: nothing else about a disc is known until its cue
        // has been fetched, decoded and parsed.
        var resolvedTracks: [[ResolvedCueFile]] = []
        for selection in selections {
            try Task.checkCancellation()
            let cuePath = selection.cuePackagePath
            let destination = try CueStaging.prepareDestination(for: cuePath, in: staging)
            digests[selection.cue.id] = try await download(selection.cue, to: destination,
                                                           progress: nil)
            let text = try CueSheet.decode(try Data(contentsOf: destination))
            let sheet = try CueSheet.parse(text)
            // Step 6 — `resolve`'s output is consumed as-is. No filename is matched
            // twice and no remote id is reconstructed here: the disc-relative
            // matching rules, including the case-folding and ambiguity rules, live
            // in `CueSheet` and are not repeated (or weakened) in this layer.
            resolvedTracks.append(try sheet.resolve(against: selection.candidates))
        }

        // Step 7 — the exact plan, then the exact preflight.
        let plan = try Self.plan(selections: selections, tracks: resolvedTracks)
        let totalBytes = plan.reduce(Int64(0)) { $0 + $1.file.sizeBytes }
        let stagedBytes = plan.filter(\.alreadyStaged).reduce(Int64(0)) { $0 + $1.file.sizeBytes }
        let remaining = totalBytes - stagedBytes + Self.capacitySafetyReserveBytes
        progress(.checkingSpace(required: remaining))
        try Self.requireCapacity(remaining, availableCapacity)

        // Step 8 — everything else.
        let reporter = PS1TransferProgress(completed: stagedBytes, total: totalBytes,
                                           report: progress)
        for entry in plan where !entry.alreadyStaged {
            try Task.checkCancellation()
            reporter.begin(entry.label)
            let destination = try CueStaging.prepareDestination(for: entry.packagePath,
                                                                in: staging)
            digests[entry.file.id] = try await download(entry.file, to: destination,
                                                        progress: reporter)
            reporter.finish(entry.file.sizeBytes)
        }

        // Step 9 — re-parse what was written and check every reference landed.
        for (selection, _) in zip(selections, resolvedTracks) {
            try Task.checkCancellation()
            progress(.validating(label: selection.disc.label))
            let discRoot = staging.appendingPathComponent(selection.directory, isDirectory: true)
            guard let cueURL = Self.existingFile(at: selection.cueName, in: discRoot) else {
                throw PS1PackageError.stagedFileMissing(selection.cuePackagePath)
            }
            let sheet = try CueSheet.parse(try CueSheet.decode(try Data(contentsOf: cueURL)))
            for reference in sheet.fileReferences where
                Self.existingFile(at: reference, in: discRoot) == nil {
                throw PS1PackageError.stagedFileMissing(selection.directory + "/" + reference)
            }
        }

        // Step 10 — the playlist and the manifest, both through the staging writer.
        var manifestDiscs: [PS1PackageManifest.Disc] = []
        for selection in selections {
            let entries = plan.filter { $0.discIndex == selection.disc.index }
            manifestDiscs.append(.init(
                romID: selection.disc.romID,
                index: selection.disc.index,
                label: selection.disc.label,
                directory: selection.directory,
                cuePath: selection.cuePackagePath,
                subchannelPath: selection.subchannelPackagePath,
                files: try entries.map { entry in
                    try Self.manifestFile(for: entry, digest: digests[entry.file.id],
                                          in: staging)
                }))
        }
        let playlist = selections.map(\.cuePackagePath)
        let manifest = PS1PackageManifest(version: PS1PackageManifest.currentVersion,
                                          canonicalRomID: game.canonicalRomID,
                                          totalBytes: totalBytes,
                                          playlist: playlist,
                                          discs: manifestDiscs)
        // The carry-forward from Task 4: both of these go through
        // `CueStaging.prepareDestination`. A cue reference like `X.cue/track01.bin`
        // still creates a directory named `X.cue`, and what makes that safe is that
        // `prepareDestination` then refuses to write the disc's own cue through it.
        // Computing a URL here and calling `Data.write(to:)` would re-open the hole.
        let playlistURL = try CueStaging.prepareDestination(for: Self.playlistFileName,
                                                            in: staging)
        try Self.playlistData(for: playlist).write(to: playlistURL, options: .atomic)
        let manifestURL = try CueStaging.prepareDestination(for: Self.manifestFileName,
                                                            in: staging)
        try Self.encode(manifest).write(to: manifestURL, options: .atomic)

        // Step 11 — the staged package answers the same questions the canonical one
        // is asked on every launch.
        if case let .failure(reason) = Self.validatePackage(at: staging, for: game) {
            throw PS1PackageError.stagedPackageInvalid("\(reason)")
        }

        // Step 12.
        try Task.checkCancellation()
        progress(.promoting)
        try promote(staging: staging, to: canonical, canonicalRomID: game.canonicalRomID)

        return PS1PreparedPackage(launchURL: canonical.appendingPathComponent(Self.playlistFileName),
                                  canonicalRomID: game.canonicalRomID,
                                  discLabels: selections.map(\.disc.label),
                                  totalBytes: totalBytes)
    }

    // MARK: - Transfer

    /// Streams one file to `<destination>.part`, then renames it inside staging.
    ///
    /// The rename is what makes a complete file complete: a `.part` that a crash or
    /// a purge interrupts is never mistaken for content. The digest the transfer
    /// returns provably describes the bytes at the part path (Task 5 pinned that),
    /// so the file is promoted without being read a second time.
    private func download(_ file: RomFile, to destination: URL,
                          progress reporter: PS1TransferProgress?) async throws -> FileDigest {
        let expected = try ExpectedFileIntegrity(file)
        let request = buildRequest(file.id, file.fileName)
        let partURL = destination.appendingPathExtension("part")
        let digest = try await transfer(request, partURL, expected) { written in
            reporter?.update(written)
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: partURL, to: destination)
        return digest
    }

    // MARK: - Promotion

    /// Installs `staging` at `canonical` with two renames, and puts the previous
    /// package back if the second one fails.
    ///
    /// If the process dies between them the canonical directory is absent and the
    /// previous package is sitting in `.backup-<id>-<uuid>`; the next
    /// initialization moves it back. If the process dies during either rename,
    /// `rename(2)` is atomic and the directory is wholly at one path or the other.
    /// The backup is removed only after the new package is in place.
    ///
    /// - Important: **This function must never become `async`, and no `await` may
    ///   appear between the two renames below.** The actor yields at every
    ///   suspension point, so a suspension inside this sequence lets a second
    ///   `prepare` for the same game interleave against one canonical path — one
    ///   promotion's backup rename landing between another's backup and install.
    ///   That two concurrent preparations cannot damage a package is a consequence
    ///   of this function being synchronous, not of the actor.
    ///   `testConcurrentPreparesForOneGameLeaveOneValidPackage` drives both
    ///   entrants through the backup branch, so an inserted `await` is *likely* to
    ///   surface there as a `packageDamaged` throw and a leaked backup — but the
    ///   probe seam is synchronous and cannot inject the suspension itself, so no
    ///   test can catch it deterministically.
    private func promote(staging: URL, to canonical: URL, canonicalRomID: Int) throws {
        let manager = FileManager.default
        try promotionProbe?(.beforeBackup)

        guard manager.fileExists(atPath: canonical.path) else {
            try manager.moveItem(at: staging, to: canonical)
            return
        }

        let backupName = "\(Self.backupPrefix)\(canonicalRomID)-\(UUID().uuidString)"
        let backup = platformRoot.appendingPathComponent(backupName, isDirectory: true)
        try manager.moveItem(at: canonical, to: backup)
        do {
            try promotionProbe?(.afterBackup)
            try manager.moveItem(at: staging, to: canonical)
        } catch {
            do {
                try manager.moveItem(at: backup, to: canonical)
            } catch {
                // Both renames failed. Say so precisely rather than reporting the
                // original failure and leaving the player with no package and no
                // explanation; the backup name is in the message and the next
                // initialization restores it.
                throw PS1PackageError.packageDamaged(canonicalRomID: canonicalRomID,
                                                     backupName: backupName)
            }
            throw error
        }
        // Only now. A backup removed any earlier is a rollback that cannot happen.
        try? manager.removeItem(at: backup)
    }

    // MARK: - Initialization sweep

    /// Finishes a promotion the process died in the middle of.
    static func repairInterruptedPromotions(in root: URL) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(backupPrefix) {
            let backup = root.appendingPathComponent(name, isDirectory: true)
            guard let romID = canonicalID(inBackupName: name) else {
                // Left alone on purpose. A backup this code cannot place is still a
                // whole package; it costs space, and deleting it costs the package.
                continue
            }
            let canonical = root.appendingPathComponent(String(romID), isDirectory: true)
            if manager.fileExists(atPath: canonical.path) {
                // The install went through; this is the superseded copy.
                try? manager.removeItem(at: backup)
            } else {
                // The install did not. Put the previous package back. A failure here
                // leaves the backup alone rather than deleting the only copy.
                try? manager.moveItem(at: backup, to: canonical)
            }
        }
    }

    /// Removes staging directories left by a run that did not finish. A staging
    /// directory holds nothing that is not re-downloadable, and holding onto one
    /// costs a purgeable cache the space of a whole game.
    static func removeAbandonedStaging(in root: URL) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(stagingPrefix) {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    static func canonicalID(inBackupName name: String) -> Int? {
        let body = name.dropFirst(backupPrefix.count)
        guard let separator = body.firstIndex(of: "-") else { return nil }
        let digits = body[body.startIndex..<separator]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    // MARK: - Disc selection

    /// One disc, resolved down to the rows the transfer needs.
    struct DiscSelection {
        let disc: PS1Disc
        let directory: String
        let details: RomDetails
        let cue: RomFile
        /// The cue's validated file name — a single safe path component.
        let cueName: String
        let subchannel: RomFile?
        let subchannelName: String?
        /// Rows that live at or below the cue's own directory, which is what pins
        /// `CueSheet.resolve`'s common-root heuristic to this disc's folder.
        let candidates: [RomFile]

        var cuePackagePath: String { directory + "/" + cueName }
        var subchannelPackagePath: String? { subchannelName.map { directory + "/" + $0 } }

        /// Every candidate that could be disc content, whether or not the cue turns
        /// out to reference it. This is the conservative preflight's input.
        var candidateContentBytes: Int64 {
            candidates.filter {
                contentExtensions.contains(CuePath.fileExtension(of: $0.fileName).lowercased())
            }.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
        }
    }

    static func orderedDiscs(of game: PS1Game) throws -> [PS1Disc] {
        guard !game.discs.isEmpty else { throw PS1PackageError.noDiscs }
        var seen: Set<Int> = []
        for disc in game.discs where !seen.insert(disc.index).inserted {
            throw PS1PackageError.duplicateDiscIndex(disc.index)
        }
        return game.discs.sorted { $0.index < $1.index }
    }

    static func discDirectoryName(index: Int) -> String { String(format: "disc-%02d", index) }

    static func select(disc: PS1Disc, from details: RomDetails) throws -> DiscSelection {
        let topLevel = details.files.filter(\.isTopLevel)
        guard !topLevel.isEmpty else { throw PS1PackageError.noLaunchFile(label: disc.label) }
        let cues = topLevel.filter { fileExtension(of: $0.fileName) == "cue" }
        guard cues.count <= 1 else {
            throw PS1PackageError.multipleLaunchFiles(label: disc.label,
                                                      names: cues.map(\.fileName).sorted())
        }
        guard let cue = cues.first else {
            // Name the largest top-level file. RomM marks *every* row of a ROM
            // top-level in the sampled library, so "the first one alphabetically"
            // would routinely name a `.bin` sidecar in a sentence that goes on to
            // say bin files are supported. The disc image is the big one.
            let named = topLevel.sorted { ($0.sizeBytes, $1.fileName) > ($1.sizeBytes, $0.fileName) }
            throw PS1PackageError.unsupportedLaunchFile(label: disc.label,
                                                        fileName: named[0].fileName)
        }
        // A cue sheet is a few kilobytes. Refusing an absurd declared size here is
        // cheaper than discovering it after transferring the bytes, and
        // `CueSheet.decode` would refuse them anyway.
        guard cue.sizeBytes <= Int64(CueSheet.maximumByteCount) else {
            throw PS1PackageError.launchFileTooLarge(label: disc.label,
                                                     byteCount: cue.sizeBytes,
                                                     limit: CueSheet.maximumByteCount)
        }
        // Every name that becomes a path is validated here, before the staging
        // directory exists and long before a request is made.
        let cueName = try safeRemoteFileName(cue.fileName, allowing: ["cue"])

        let candidates = filesUnderDirectory(of: cue, in: details.files)
        let stem = CuePath.foldedKey(self.stem(of: cue.fileName))
        let subchannels = candidates.filter {
            $0.isTopLevel && fileExtension(of: $0.fileName) == "sbi"
                && CuePath.foldedKey(self.stem(of: $0.fileName)) == stem
        }
        guard subchannels.count <= 1 else {
            throw PS1PackageError.multipleSubchannelFiles(
                label: disc.label, names: subchannels.map(\.fileName).sorted())
        }
        // `validateTrackReference` rather than `validate`: this destination comes
        // from `RomFile.fileName`, not from a cue reference, so `CueSheet.parse`'s
        // bin/sbi whitelist has not been applied to it.
        let subchannelName = try subchannels.first.map {
            try safeRemoteFileName($0.fileName, allowing: CuePath.allowedTrackExtensions)
        }

        return DiscSelection(disc: disc, directory: discDirectoryName(index: disc.index),
                             details: details, cue: cue, cueName: cueName,
                             subchannel: subchannels.first, subchannelName: subchannelName,
                             candidates: candidates)
    }

    /// The rows at or below `cue`'s own directory.
    ///
    /// `CueSheet.resolve` derives the disc root from the longest directory prefix
    /// *all* the rows share, so a single row RomM lists a level up shifts every
    /// relative path and fails the disc. `resolve` takes no root parameter, so the
    /// root is pinned by handing it a candidate set whose shared prefix is the
    /// cue's directory — the cue row itself is always in the set, which is what
    /// keeps the prefix from sliding deeper.
    static func filesUnderDirectory(of cue: RomFile, in files: [RomFile]) -> [RomFile] {
        let root = directoryComponents(cue.filePath)
        guard !root.isEmpty else {
            // The cue sits at the library root and cannot pin anything. Keep only
            // rows that sit there too, so the prefix stays empty.
            return files.filter { directoryComponents($0.filePath).isEmpty }
        }
        return files.filter { file in
            let components = directoryComponents(file.filePath)
            return components.count >= root.count
                && Array(components.prefix(root.count)) == root
        }
    }

    static func directoryComponents(_ path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
    }

    static func fileExtension(of name: String) -> String {
        CuePath.fileExtension(of: name).lowercased()
    }

    static func stem(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// A server-supplied file name, judged safe enough to become one path
    /// component under a staging directory.
    static func safeRemoteFileName(_ name: String,
                                   allowing extensions: Set<String>) throws -> String {
        let normalized: String
        do {
            normalized = try CuePath.validate(name)
        } catch let error as CueSheetError {
            if case let .unsafeReference(_, rejection) = error {
                throw PS1PackageError.unsafeRemoteFileName(name, rejection: rejection)
            }
            throw error
        }
        // `validate` normalizes separators but does not forbid them: a reference
        // *may* be a nested path. A file name may not.
        guard !normalized.contains("/") else {
            throw PS1PackageError.remoteFileNameIsAPath(name)
        }
        let suffix = fileExtension(of: normalized)
        guard extensions.contains(suffix) else {
            throw CueSheetError.unsupportedTrackExtension(name, fileExtension: suffix)
        }
        return normalized
    }

    // MARK: - The plan

    /// One file to put in the package.
    struct PlannedFile {
        let file: RomFile
        /// Package-relative destination, e.g. `disc-01/track01.bin`.
        let packagePath: String
        let discIndex: Int
        let label: String
        /// True for the cues, which step 5 has already written.
        let alreadyStaged: Bool
    }

    /// The exact unique-file plan: each disc's cue, every track its cue resolved
    /// to, and the disc's same-basename SBI when the server has one.
    ///
    /// The collision rules mirror `CueSheet.parse`'s, but across the whole package
    /// rather than one cue: two destinations that fold to one name, and a
    /// destination that needs a directory where another needs a file. The second is
    /// what catches a reference like `X.cue/track01.bin`, whose intermediate
    /// component is not extension-checked and would otherwise reach the staging
    /// writer as a directory named after the disc's own cue.
    static func plan(selections: [DiscSelection],
                     tracks: [[ResolvedCueFile]]) throws -> [PlannedFile] {
        var candidates: [PlannedFile] = []
        for (selection, resolved) in zip(selections, tracks) {
            candidates.append(PlannedFile(file: selection.cue,
                                          packagePath: selection.cuePackagePath,
                                          discIndex: selection.disc.index,
                                          label: selection.disc.label,
                                          alreadyStaged: true))
            for entry in resolved {
                // Step 6: the destination is the cue's own spelling of the
                // reference and the row is the one `resolve` matched. Neither is
                // recomputed here.
                candidates.append(PlannedFile(
                    file: entry.file,
                    packagePath: selection.directory + "/" + entry.relativeDestinationPath,
                    discIndex: selection.disc.index,
                    label: selection.disc.label,
                    alreadyStaged: false))
            }
            if let subchannel = selection.subchannel, let path = selection.subchannelPackagePath {
                candidates.append(PlannedFile(file: subchannel, packagePath: path,
                                              discIndex: selection.disc.index,
                                              label: selection.disc.label,
                                              alreadyStaged: false))
            }
        }

        var plan: [PlannedFile] = []
        var filesByFoldedPath: [String: String] = [:]
        var directoriesByFoldedPath: [String: String] = [:]
        var pathsByRemoteID: [Int: String] = [:]

        for entry in candidates {
            let key = CuePath.foldedKey(entry.packagePath)
            // The same server file at the same destination is one download, not a
            // conflict: a cue that references the disc's SBI names the row the
            // same-basename rule would have added anyway.
            if pathsByRemoteID[entry.file.id] == entry.packagePath,
               filesByFoldedPath[key] == entry.packagePath { continue }

            if let existing = filesByFoldedPath[key] {
                throw PS1PackageError.collidingPackagePaths(existing, entry.packagePath)
            }
            if let owner = directoriesByFoldedPath[key] {
                throw PS1PackageError.collidingPackagePaths(entry.packagePath, owner)
            }
            var ancestor: [String] = []
            for component in entry.packagePath.split(separator: "/").dropLast() {
                ancestor.append(String(component))
                let ancestorKey = CuePath.foldedKey(ancestor.joined(separator: "/"))
                if let existing = filesByFoldedPath[ancestorKey] {
                    throw PS1PackageError.collidingPackagePaths(existing, entry.packagePath)
                }
                directoriesByFoldedPath[ancestorKey] = entry.packagePath
            }
            if let other = pathsByRemoteID[entry.file.id] {
                throw PS1PackageError.duplicateRemoteFile(
                    id: entry.file.id, paths: [other, entry.packagePath].sorted())
            }
            filesByFoldedPath[key] = entry.packagePath
            pathsByRemoteID[entry.file.id] = entry.packagePath
            plan.append(entry)
        }
        return plan
    }

    // MARK: - Capacity

    static func requireCapacity(_ required: Int64,
                                _ measure: @Sendable () throws -> Int64) throws {
        let available = try measure()
        guard available >= required else {
            throw PS1PackageError.insufficientCapacity(required: required, available: available)
        }
    }

    /// Free bytes on the volume `url` lives on.
    ///
    /// Two answers, because the platforms do not offer the same one.
    /// `volumeAvailableCapacityForImportantUsage` is the better figure — it counts
    /// space the system would reclaim by purging, which is exactly the space a game
    /// download is allowed to take — but the key is unavailable on tvOS and
    /// watchOS, so there the only figure is `systemFreeSize`.
    ///
    /// The asymmetry is deliberate and worth naming: `systemFreeSize` does **not**
    /// count purgeable space, so it under-reports on the one platform whose cache
    /// is purgeable. Under-reporting is the direction to be wrong in for a
    /// preflight — it refuses a download that might have fitted rather than
    /// starting one that will not, and a refusal is a sentence the player can act
    /// on while a half-written package is not.
    static func freeBytes(on url: URL) throws -> Int64 {
        #if !os(tvOS) && !os(watchOS)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage { return capacity }
        #endif
        return try fileSystemFreeBytes(on: url)
    }

    /// The figure every platform has, and the only one tvOS has. Split out so the
    /// branch the tvOS app actually takes is reachable from a test running on
    /// macOS, where the `#if` above would otherwise compile it away.
    static func fileSystemFreeBytes(on url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Playlist and manifest

    /// The playlist bytes, or a throw.
    ///
    /// `M3UWriter.data` answers `Data()` when *any* entry is unsafe, on purpose:
    /// dropping one entry of a three-disc game does not produce a playlist with a
    /// problem in it, it produces a wrong one, where disc 3 silently becomes disc 2.
    /// Treating empty as "no discs" here would launder that back into a wrong
    /// answer nobody notices.
    static func playlistData(for cuePaths: [String]) throws -> Data {
        let data = M3UWriter.data(cuePaths: cuePaths)
        guard !data.isEmpty else {
            throw PS1PackageError.emptyPlaylist(discCount: cuePaths.count)
        }
        return data
    }

    static func encode(_ manifest: PS1PackageManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    static func manifestFile(for entry: PlannedFile, digest: FileDigest?,
                             in root: URL) throws -> PS1PackageManifest.File {
        guard let url = existingFile(at: entry.packagePath, in: root) else {
            throw PS1PackageError.stagedFileMissing(entry.packagePath)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        // The digest is the one the transfer returned, which provably describes the
        // bytes it wrote; the size is read back from disk. A disagreement means the
        // file changed after it was verified, which is a refusal and not a manifest
        // entry to be written down.
        guard size == entry.file.sizeBytes, let digest, digest.size == size else {
            throw PS1PackageError.stagedFileWrongSize(entry.packagePath,
                                                      expected: entry.file.sizeBytes,
                                                      actual: size)
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return PS1PackageManifest.File(remoteID: entry.file.id,
                                       remoteFileName: entry.file.fileName,
                                       remoteSizeBytes: entry.file.sizeBytes,
                                       remoteUpdatedAt: entry.file.updatedAt,
                                       remoteCRC32: entry.file.crcHash,
                                       remoteMD5: entry.file.md5Hash,
                                       remoteSHA1: entry.file.sha1Hash,
                                       path: entry.packagePath,
                                       localSizeBytes: size,
                                       localModifiedAt: modified,
                                       localSHA1: digest.sha1)
    }

    static func package(from manifest: PS1PackageManifest, at root: URL) -> PS1PreparedPackage {
        PS1PreparedPackage(launchURL: root.appendingPathComponent(playlistFileName),
                           canonicalRomID: manifest.canonicalRomID,
                           discLabels: manifest.discs.map(\.label),
                           totalBytes: manifest.totalBytes)
    }

    // MARK: - Is the cache still current?

    /// Whether the installed package still describes what the server holds.
    ///
    /// Compared per recorded file: id, name, size, `updatedAt` and every hash the
    /// server supplies. The selected cue must still be the recorded one, and a
    /// subchannel file that has appeared or vanished since is a change too —
    /// without that, a newly published SBI would be masked forever by a manifest
    /// that never mentioned one.
    static func isUnchanged(_ manifest: PS1PackageManifest,
                            against selections: [DiscSelection]) -> Bool {
        guard manifest.discs.count == selections.count else { return false }
        for (recorded, selection) in zip(manifest.discs, selections) {
            guard recorded.romID == selection.disc.romID,
                  recorded.index == selection.disc.index,
                  recorded.label == selection.disc.label,
                  recorded.directory == selection.directory,
                  recorded.cuePath == selection.cuePackagePath,
                  recorded.subchannelPath == selection.subchannelPackagePath
            else { return false }
            guard let recordedCue = recorded.files.first(where: { $0.path == recorded.cuePath }),
                  recordedCue.remoteID == selection.cue.id else { return false }

            var rows: [Int: RomFile] = [:]
            for row in selection.details.files where rows[row.id] == nil { rows[row.id] = row }
            for file in recorded.files {
                guard let row = rows[file.remoteID],
                      row.fileName == file.remoteFileName,
                      row.sizeBytes == file.remoteSizeBytes,
                      row.updatedAt == file.remoteUpdatedAt,
                      row.crcHash == file.remoteCRC32,
                      row.md5Hash == file.remoteMD5,
                      row.sha1Hash == file.remoteSHA1
                else { return false }
            }
        }
        return true
    }

    // MARK: - Is what is on disk still a package?

    /// Timestamps round-trip through JSON as doubles; this is slack for that, not
    /// for a file that was rewritten.
    static let modificationDateTolerance = 0.000_001

    /// Validates a package directory against the game it claims to be.
    ///
    /// Sizes are checked for every file on every call, because a size check is a
    /// `stat` and a purge or a truncation is exactly what it catches. Contents are
    /// only rehashed when the recorded local metadata says the file has been
    /// touched since it was written — re-reading 480 MB before every launch would
    /// cost more than the corruption it looks for, and would itself invite the
    /// purge it is trying to detect.
    static func validatePackage(at root: URL,
                                for game: PS1Game) -> Result<PS1PackageManifest,
                                                             PS1PackageInvalidation> {
        guard let raw = try? Data(contentsOf: root.appendingPathComponent(manifestFileName)) else {
            return .failure(.noManifest)
        }
        guard let manifest = try? JSONDecoder().decode(PS1PackageManifest.self, from: raw) else {
            if let probe = try? JSONDecoder().decode(PS1PackageManifest.VersionProbe.self,
                                                     from: raw),
               probe.version != PS1PackageManifest.currentVersion {
                return .failure(.unsupportedManifestVersion(probe.version))
            }
            return .failure(.unreadableManifest)
        }
        guard manifest.version == PS1PackageManifest.currentVersion else {
            return .failure(.unsupportedManifestVersion(manifest.version))
        }
        guard manifest.canonicalRomID == game.canonicalRomID else {
            return .failure(.wrongCanonicalRom(expected: game.canonicalRomID,
                                               found: manifest.canonicalRomID))
        }

        let discs = game.discs.sorted { $0.index < $1.index }
        guard manifest.discs.count == discs.count else { return .failure(.discSetChanged) }
        for (recorded, disc) in zip(manifest.discs, discs) {
            guard recorded.romID == disc.romID, recorded.index == disc.index,
                  recorded.label == disc.label,
                  recorded.directory == discDirectoryName(index: disc.index)
            else { return .failure(.discSetChanged) }
        }

        guard manifest.playlist == manifest.discs.map(\.cuePath) else {
            return .failure(.playlistMismatch)
        }
        for recorded in manifest.discs where
            !recorded.files.contains(where: { $0.path == recorded.cuePath }) {
            return .failure(.playlistMismatch)
        }
        guard let playlist = try? playlistData(for: manifest.playlist),
              let onDisk = try? Data(contentsOf: root.appendingPathComponent(playlistFileName)),
              onDisk == playlist
        else { return .failure(.playlistMismatch) }

        for recorded in manifest.discs {
            for file in recorded.files {
                guard let url = existingFile(at: file.path, in: root) else {
                    return .failure(.missingFile(file.path))
                }
                guard let attributes = try? FileManager.default
                        .attributesOfItem(atPath: url.path) else {
                    return .failure(.missingFile(file.path))
                }
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard size == file.localSizeBytes, size == file.remoteSizeBytes else {
                    return .failure(.wrongSize(file.path, expected: file.remoteSizeBytes,
                                               actual: size))
                }
                let modified = (attributes[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? .nan
                let untouched = abs(modified - file.localModifiedAt) <= modificationDateTolerance
                if untouched { continue }
                guard let sha1 = sha1OfFile(at: url) else {
                    return .failure(.missingFile(file.path))
                }
                guard sha1 == file.localSHA1 else { return .failure(.hashMismatch(file.path)) }
            }
        }
        return .success(manifest)
    }

    /// The URL of an existing regular file at `relativePath` under `root`, creating
    /// nothing and following no symlink at any step.
    ///
    /// Validation-time twin of `CueStaging.prepareDestination`: same component walk
    /// and same containment backstop, without the directory creation, so a check
    /// can never leave debris in the package it is checking.
    static func existingFile(at relativePath: String, in root: URL) -> URL? {
        guard let normalized = try? CuePath.validate(relativePath) else { return nil }
        let components = normalized.split(separator: "/").map(String.init)
        guard let name = components.last else { return nil }
        var url = root
        for component in components.dropLast() {
            url.appendPathComponent(component, isDirectory: true)
            guard itemType(at: url) == .typeDirectory else { return nil }
        }
        url.appendPathComponent(name, isDirectory: false)
        guard itemType(at: url) == .typeRegular else { return nil }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == rootPath || parent.hasPrefix(rootPath + "/") else { return nil }
        return url
    }

    private static func itemType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// Streams the file past a SHA-1; never holds more than one chunk.
    ///
    /// SHA-1 alone rather than `IncrementalFileDigest`, which computes MD5 and
    /// CRC-32 in the same pass and would have two thirds of its work discarded
    /// here. Re-reading a touched 480 MB disc is already the most expensive thing
    /// step 1 can do on an Apple TV. `testStreamingSHA1AgreesWithTheFullDigest`
    /// pins the two against each other so the second formatter cannot drift.
    ///
    /// Returns `nil` when the task is cancelled, which reads as "this file could
    /// not be verified" — the caller invalidates, and the cancellation check
    /// immediately after step 1 throws before that answer can be acted on.
    static func sha1OfFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1()
        while true {
            // Between chunks, which is the only place a multi-second hash of a
            // whole disc can be stopped.
            if Task.isCancelled { return nil }
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 16) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            sha1.update(data: chunk)
        }
        return hexadecimal(sha1.finalize())
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lowercase, two characters per byte, no leading zero suppression — the same
    /// spelling `IncrementalFileDigest` produces, because these two strings are
    /// compared against each other.
    private static func hexadecimal<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        var characters: [UInt8] = []
        characters.reserveCapacity(40)
        for byte in bytes {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    // MARK: - Offline versus broken

    /// Whether a metadata failure means the device cannot reach the server.
    ///
    /// Deliberately narrow, and deliberately not "anything that is not a 2xx". An
    /// expired token, a 500, a proxy's HTML error page and a schema change are all
    /// *reachable server* failures with different answers, and telling a player
    /// they are offline sends them to check a router that is working. Only
    /// transport-layer `URLError`s qualify; `URLError.cancelled` never does,
    /// because a cancelled request is a decision, not a network condition, and
    /// `CancellationError` is not a `URLError` at all. `prepare` additionally
    /// refuses to consult this function once the task is cancelled — a guard that
    /// belongs there, where the answer is acted on, rather than here.
    public static func isLikelyConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
             .dataNotAllowed, .callIsActive:
            return true
        default:
            return false
        }
    }
}

import XCTest
@testable import RommpleTVKit

// MARK: - Synthetic library
//
// Nothing in this file is real library content. Titles are invented, bytes are
// generated from file ids, and every expectation is computed from those generated
// bytes. The digests come from `IncrementalFileDigest` — the same code the store
// uses — which is composition rather than self-validation: `FileIntegrityTests`
// already pins that type against published FIPS/RFC/CRC-catalogue vectors, so
// what is under test here is the store's behaviour, not the hash function.

/// A stand-in for one RomM server: rom details keyed by ROM id, file bytes keyed
/// by `RomFile.id`, plus counters and hooks the tests drive failures through.
private final class FakeLibrary: @unchecked Sendable {

    struct Extra {
        let name: String
        let isTopLevel: Bool
        let size: Int
        /// Overrides the disc folder, so a row RomM lists a level up (or a level
        /// down) can be modelled.
        var path: String?
    }

    struct DiscSpec {
        var romID: Int
        var folder: String
        var cueName: String
        var tracks: [String]
        var subchannelName: String?
        var extras: [Extra] = []
        /// Replaces the generated cue text verbatim, for references the generator
        /// would never produce.
        var cueTextOverride: String?
        var cueIsTopLevel = true
        var tracksAreTopLevel = true
    }

    private let lock = NSLock()
    private var details: [Int: RomDetails] = [:]
    private var contents: [Int: Data] = [:]
    private var nextFileID = 9000

    /// RomM's digests are lowercase in the sampled deployment, but nothing in the
    /// schema promises it.
    var uppercaseHashes = false
    /// A downloader that ignores cancellation, so the store's own checks are the
    /// only thing that can stop a run. Same seam, and same reason, as
    /// `StreamingFileDownloader.write`'s injectable byte source.
    var ignoresCancellation = false

    private var detailsCallsStorage: [Int] = []
    private var requestedFilesStorage: [(fileID: Int, fileName: String)] = []
    private var transferredStorage: [Int] = []

    /// Runs before a details load resolves; throw to fail it.
    var detailsHook: (@Sendable (Int) async throws -> Void)?
    /// Runs before a transfer writes anything; throw to fail it. The part URL is
    /// supplied so a hook can leave debris behind on purpose.
    var transferHook: (@Sendable (Int, URL) async throws -> Void)?

    // MARK: Building

    @discardableResult
    func add(_ spec: DiscSpec, updatedAt: String = "2026-01-01T00:00:00") -> RomDetails {
        lock.lock()
        var files: [RomFile] = []

        for track in spec.tracks {
            let id = nextFileID; nextFileID += 1
            let data = Self.bytes(id: id, count: 4096 + (id % 97) * 16)
            contents[id] = data
            // A track name carrying a separator is a track in a subdirectory of the
            // disc folder, which is how RomM would report one.
            var directory = spec.folder
            var name = track
            if let slash = track.lastIndex(of: "/") {
                directory += "/" + String(track[track.startIndex..<slash])
                name = String(track[track.index(after: slash)...])
            }
            files.append(Self.file(id: id, name: name, path: directory, data: data,
                                   isTopLevel: spec.tracksAreTopLevel, updatedAt: updatedAt,
                                   uppercaseHashes: uppercaseHashes))
        }

        let cueID = nextFileID; nextFileID += 1
        let cueText = spec.cueTextOverride ?? Self.cueText(referencing: spec.tracks)
        let cueData = Data(cueText.utf8)
        contents[cueID] = cueData
        files.append(Self.file(id: cueID, name: spec.cueName, path: spec.folder, data: cueData,
                               isTopLevel: spec.cueIsTopLevel, updatedAt: updatedAt,
                               uppercaseHashes: uppercaseHashes))

        if let subchannelName = spec.subchannelName {
            let id = nextFileID; nextFileID += 1
            let data = Self.bytes(id: id, count: 512)
            contents[id] = data
            files.append(Self.file(id: id, name: subchannelName, path: spec.folder, data: data,
                                   isTopLevel: true, updatedAt: updatedAt,
                                   uppercaseHashes: uppercaseHashes))
        }

        for extra in spec.extras {
            let id = nextFileID; nextFileID += 1
            let data = Self.bytes(id: id, count: extra.size)
            contents[id] = data
            files.append(Self.file(id: id, name: extra.name, path: extra.path ?? spec.folder,
                                   data: data, isTopLevel: extra.isTopLevel,
                                   updatedAt: updatedAt, uppercaseHashes: uppercaseHashes))
        }

        let result = RomDetails(id: spec.romID, fsName: spec.folder, files: files)
        details[spec.romID] = result
        lock.unlock()
        return result
    }

    func setDetails(_ value: RomDetails, for romID: Int) {
        lock.lock(); details[romID] = value; lock.unlock()
    }

    func details(for romID: Int) -> RomDetails {
        lock.lock(); defer { lock.unlock() }
        return details[romID]!
    }

    func file(named name: String, in romID: Int) -> RomFile {
        details(for: romID).files.first { $0.fileName == name }!
    }

    func register(_ data: Data, forFileID id: Int) {
        lock.lock(); contents[id] = data; lock.unlock()
    }

    func bytes(forFileID id: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return contents[id]
    }

    /// Rewrites one file row in place, leaving every other row alone.
    func replaceFile(romID: Int, fileID: Int, _ transform: (RomFile) -> RomFile) {
        lock.lock()
        let current = details[romID]!
        let rewritten = current.files.map { $0.id == fileID ? transform($0) : $0 }
        details[romID] = RomDetails(id: current.id, fsName: current.fsName, files: rewritten)
        lock.unlock()
    }

    // MARK: Counters

    var detailsCalls: [Int] { lock.lock(); defer { lock.unlock() }; return detailsCallsStorage }
    var requestedFiles: [(fileID: Int, fileName: String)] {
        lock.lock(); defer { lock.unlock() }; return requestedFilesStorage
    }
    var transferredFileIDs: [Int] {
        lock.lock(); defer { lock.unlock() }; return transferredStorage
    }
    var transferCount: Int { transferredFileIDs.count }

    func resetCounters() {
        lock.lock()
        detailsCallsStorage = []; requestedFilesStorage = []; transferredStorage = []
        lock.unlock()
    }

    // MARK: Seams handed to the store

    private func recordDetailsCall(_ romID: Int) {
        lock.lock(); detailsCallsStorage.append(romID); lock.unlock()
    }

    private func storedDetails(_ romID: Int) -> RomDetails? {
        lock.lock(); defer { lock.unlock() }; return details[romID]
    }

    private func recordTransfer(_ fileID: Int) {
        lock.lock(); transferredStorage.append(fileID); lock.unlock()
    }

    private func recordRequest(_ fileID: Int, _ fileName: String) {
        lock.lock(); requestedFilesStorage.append((fileID, fileName)); lock.unlock()
    }

    var loadDetails: @Sendable (Int) async throws -> RomDetails {
        { [self] romID in
            recordDetailsCall(romID)
            if let hook = detailsHook { try await hook(romID) }
            guard let found = storedDetails(romID) else { throw RommError.http(404) }
            return found
        }
    }

    /// Mirrors `RommClient.romFileRequest(fileID:fileName:)`: the id in the path is
    /// the **file** id. The transfer below looks the bytes up by exactly that id,
    /// so a store that passed a parent ROM id would find nothing.
    var buildRequest: @Sendable (Int, String) -> URLRequest {
        { [self] fileID, fileName in
            recordRequest(fileID, fileName)
            let encoded = fileName.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? "x"
            let url = URL(string:
                "https://library.invalid/api/roms/\(fileID)/files/content/\(encoded)")!
            return URLRequest(url: url)
        }
    }

    /// The `StreamingFileDownloader` contract, honoured: bytes land at `partURL`,
    /// the returned digest describes them, and on any failure the part file this
    /// call created is removed.
    var transfer: PS1FileTransfer {
        { [self] request, partURL, expected, progress in
            let fileID = Self.fileID(in: request.url!)
            recordTransfer(fileID)
            if let hook = transferHook {
                do { try await hook(fileID, partURL) } catch {
                    try? FileManager.default.removeItem(at: partURL)
                    throw error
                }
            }
            if !ignoresCancellation { try Task.checkCancellation() }
            guard let data = bytes(forFileID: fileID) else {
                throw FileIntegrityError.httpStatus(404)
            }
            do {
                try data.write(to: partURL)
                var digest = IncrementalFileDigest()
                digest.update(data)
                let result = digest.finalized()
                progress(result.size)
                try expected.verify(result)
                return result
            } catch {
                try? FileManager.default.removeItem(at: partURL)
                throw error
            }
        }
    }

    // MARK: Generation

    static func fileID(in url: URL) -> Int {
        let parts = url.path.split(separator: "/")
        guard let romsIndex = parts.firstIndex(of: "roms"), romsIndex + 1 < parts.count,
              let id = Int(parts[romsIndex + 1]) else { return -1 }
        return id
    }

    static func bytes(id: Int, count: Int) -> Data {
        var data = Data(repeating: UInt8(truncatingIfNeeded: id &* 7 &+ 3), count: count)
        if count >= 4 {
            let stamp = withUnsafeBytes(of: UInt32(id).bigEndian) { Data($0) }
            data.replaceSubrange(0..<4, with: stamp)
        }
        return data
    }

    static func file(id: Int, name: String, path: String, data: Data,
                     isTopLevel: Bool, updatedAt: String,
                     uppercaseHashes: Bool = false) -> RomFile {
        var digest = IncrementalFileDigest()
        digest.update(data)
        let computed = digest.finalized()
        let cased: (String) -> String = uppercaseHashes ? { $0.uppercased() } : { $0 }
        return RomFile(id: id, fileName: name, filePath: path, sizeBytes: Int64(data.count),
                       isTopLevel: isTopLevel, crcHash: cased(computed.crc32),
                       md5Hash: cased(computed.md5), sha1Hash: cased(computed.sha1),
                       updatedAt: updatedAt)
    }

    static func cueText(referencing tracks: [String]) -> String {
        var text = ""
        for (offset, track) in tracks.enumerated() {
            text += "FILE \"\(track)\" BINARY\n"
            text += String(format: "  TRACK %02d MODE2/2352\n", offset + 1)
            text += "    INDEX 01 00:00:00\n"
        }
        return text
    }
}

/// A flag two tasks can hand across.
private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func wait() async {
        for _ in 0..<2000 where !isRaised {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// Collects progress reports from any thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PS1PreparationProgress] = []
    var events: [PS1PreparationProgress] { lock.lock(); defer { lock.unlock() }; return storage }
    var sink: @Sendable (PS1PreparationProgress) -> Void {
        { [self] event in lock.lock(); storage.append(event); lock.unlock() }
    }
    var names: [String] {
        events.map { event in
            switch event {
            case .planning: return "planning"
            case .checkingSpace: return "checkingSpace"
            case .downloading: return "downloading"
            case .validating: return "validating"
            case .promoting: return "promoting"
            }
        }
    }
    var requiredSpaceReports: [Int64] {
        events.compactMap { if case let .checkingSpace(required) = $0 { return required }; return nil }
    }
    var downloadTotals: [Int64] {
        events.compactMap { if case let .downloading(_, _, total) = $0 { return total }; return nil }
    }
    var downloadCompletions: [Int64] {
        events.compactMap { if case let .downloading(_, done, _) = $0 { return done }; return nil }
    }
}

// MARK: - Tests

final class PS1PackageStoreTests: XCTestCase {

    // MARK: Fixtures

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func platformRoot(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent("psx", isDirectory: true)
    }

    private func makeStore(
        cacheRoot: URL,
        library: FakeLibrary,
        capacity: @escaping @Sendable () throws -> Int64 = { 1 << 40 },
        isConnectivityError: @escaping @Sendable (Error) -> Bool
            = { PS1PackageStore.isLikelyConnectivityError($0) }
    ) throws -> PS1PackageStore {
        try PS1PackageStore(cacheRoot: cacheRoot,
                            loadDetails: library.loadDetails,
                            buildRequest: library.buildRequest,
                            transfer: library.transfer,
                            availableCapacity: capacity,
                            isConnectivityError: isConnectivityError)
    }

    /// A two-disc game: disc 1 has two tracks and an SBI, disc 2 has one track.
    private func twoDiscLibrary() -> FakeLibrary {
        let library = FakeLibrary()
        library.add(.init(romID: 8300, folder: "psx/Vault Runner (Disc 1)",
                          cueName: "Vault Runner (Disc 1).cue",
                          tracks: ["Vault Runner (Disc 1) (Track 1).bin",
                                   "Vault Runner (Disc 1) (Track 2).bin"],
                          subchannelName: "Vault Runner (Disc 1).sbi"))
        library.add(.init(romID: 8301, folder: "psx/Vault Runner (Disc 2)",
                          cueName: "Vault Runner (Disc 2).cue",
                          tracks: ["Vault Runner (Disc 2) (Track 1).bin"]))
        return library
    }

    private func singleDiscLibrary() -> FakeLibrary {
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue",
                          tracks: ["Signal Drift.bin"]))
        return library
    }

    private func game(canonical: Int, discs: [(romID: Int, index: Int)],
                      fsName: String = "Vault Runner (Disc 1)") -> PS1Game {
        let representative = Rom(id: discs[0].romID, name: "Vault Runner", fsName: fsName,
                                 platformId: 35, sizeBytes: nil, coverPath: nil)
        return PS1Game(
            representative: representative,
            canonicalRomID: canonical,
            discs: discs.map {
                PS1Disc(romID: $0.romID, fileStem: "stem-\($0.romID)", index: $0.index,
                        label: "Disc \($0.index)")
            },
            excludedSiblings: [])
    }

    private func twoDiscGame() -> PS1Game {
        game(canonical: 8300, discs: [(8300, 1), (8301, 2)])
    }

    private func singleDiscGame() -> PS1Game {
        game(canonical: 8400, discs: [(8400, 1)], fsName: "Signal Drift")
    }

    // MARK: Filesystem helpers

    private func snapshot(_ root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return result }
        for case let relative as String in walker {
            let url = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            result[relative] = (try? Data(contentsOf: url)) ?? Data()
        }
        return result
    }

    private func entries(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    private func stagingDirectories(in root: URL) -> [String] {
        entries(in: root).filter { $0.hasPrefix(".staging-") }
    }

    private func backupDirectories(in root: URL) -> [String] {
        entries(in: root).filter { $0.hasPrefix(".backup-") }
    }

    private func partFiles(in root: URL) -> [String] {
        snapshot(root).keys.filter { $0.hasSuffix(".part") }.sorted()
    }

    private func canonicalDirectory(_ cacheRoot: URL, _ id: Int) -> URL {
        platformRoot(in: cacheRoot).appendingPathComponent(String(id), isDirectory: true)
    }

    private func manifest(at packageRoot: URL) throws -> PS1PackageManifest {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("package.json"))
        return try JSONDecoder().decode(PS1PackageManifest.self, from: data)
    }

    private func playlistLines(at packageRoot: URL) throws -> [String] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("game.m3u"))
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Plan shape

    func testFetchPlanCoversEveryCueAndReferencedTrack() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        let prepared = try await store.prepare(twoDiscGame())

        let expected = Set([
            library.file(named: "Vault Runner (Disc 1).cue", in: 8300).id,
            library.file(named: "Vault Runner (Disc 1) (Track 1).bin", in: 8300).id,
            library.file(named: "Vault Runner (Disc 1) (Track 2).bin", in: 8300).id,
            library.file(named: "Vault Runner (Disc 1).sbi", in: 8300).id,
            library.file(named: "Vault Runner (Disc 2).cue", in: 8301).id,
            library.file(named: "Vault Runner (Disc 2) (Track 1).bin", in: 8301).id,
        ])
        XCTAssertEqual(Set(library.transferredFileIDs), expected)
        XCTAssertEqual(library.transferCount, expected.count, "no file fetched twice")

        let package = canonicalDirectory(cacheRoot, 8300)
        XCTAssertEqual(prepared.launchURL, package.appendingPathComponent("game.m3u"))
        let files = snapshot(package)
        XCTAssertNotNil(files["disc-01/Vault Runner (Disc 1).cue"])
        XCTAssertNotNil(files["disc-01/Vault Runner (Disc 1) (Track 1).bin"])
        XCTAssertNotNil(files["disc-01/Vault Runner (Disc 1) (Track 2).bin"])
        XCTAssertNotNil(files["disc-02/Vault Runner (Disc 2).cue"])
        XCTAssertNotNil(files["disc-02/Vault Runner (Disc 2) (Track 1).bin"])
    }

    func testDownloadedBytesMatchTheServersFiles() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())

        let package = canonicalDirectory(cacheRoot, 8300)
        let track = library.file(named: "Vault Runner (Disc 1) (Track 2).bin", in: 8300)
        let written = try Data(contentsOf:
            package.appendingPathComponent("disc-01/Vault Runner (Disc 1) (Track 2).bin"))
        XCTAssertEqual(written, library.bytes(forFileID: track.id))
    }

    func testSameBasenameSubchannelFileIsRetained() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())

        let package = canonicalDirectory(cacheRoot, 8300)
        XCTAssertNotNil(snapshot(package)["disc-01/Vault Runner (Disc 1).sbi"])
        let recorded = try manifest(at: package)
        XCTAssertEqual(recorded.discs[0].subchannelPath, "disc-01/Vault Runner (Disc 1).sbi")
        XCTAssertNil(recorded.discs[1].subchannelPath)
    }

    func testDifferentBasenameSubchannelFileIsNotRetained() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"],
                          subchannelName: "Something Else.sbi"))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())

        XCTAssertNil(snapshot(canonicalDirectory(cacheRoot, 8400))["disc-01/Something Else.sbi"])
        XCTAssertEqual(library.transferCount, 2, "cue and one track only")
    }

    func testMultipleSameBasenameSubchannelFilesAreRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"],
                          subchannelName: "Signal Drift.sbi",
                          extras: [.init(name: "Signal Drift.SBI", isTopLevel: true, size: 64)]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.multipleSubchannelFiles(
            label: "Disc 1", names: ["Signal Drift.SBI", "Signal Drift.sbi"])) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferCount, 0)
    }

    func testDeclaredTotalIsTheSumOfUniqueRemoteFiles() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let log = ProgressLog()

        let prepared = try await store.prepare(twoDiscGame(), progress: log.sink)

        let names: [(String, Int)] = [
            ("Vault Runner (Disc 1).cue", 8300),
            ("Vault Runner (Disc 1) (Track 1).bin", 8300),
            ("Vault Runner (Disc 1) (Track 2).bin", 8300),
            ("Vault Runner (Disc 1).sbi", 8300),
            ("Vault Runner (Disc 2).cue", 8301),
            ("Vault Runner (Disc 2) (Track 1).bin", 8301),
        ]
        let expected = names.reduce(Int64(0)) { $0 + library.file(named: $1.0, in: $1.1).sizeBytes }
        XCTAssertEqual(prepared.totalBytes, expected)
        XCTAssertEqual(Set(log.downloadTotals), [expected])
        XCTAssertEqual(log.downloadCompletions.last, expected)
        XCTAssertEqual(log.downloadCompletions, log.downloadCompletions.sorted(),
                       "download progress is monotonic")
    }

    func testContentRequestsUseFileIDsNotRomIDs() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())

        let requested = Set(library.requestedFiles.map(\.fileID))
        XCTAssertFalse(requested.contains(8300))
        XCTAssertFalse(requested.contains(8301))
        let known = Set(library.details(for: 8300).files.map(\.id)
                            + library.details(for: 8301).files.map(\.id))
        XCTAssertTrue(requested.isSubset(of: known))
        for entry in library.requestedFiles {
            let owner = [8300, 8301].first { romID in
                library.details(for: romID).files.contains { $0.id == entry.fileID }
            }
            XCTAssertNotNil(owner)
            let row = library.details(for: owner!).files.first { $0.id == entry.fileID }!
            XCTAssertEqual(entry.fileName, row.fileName,
                           "the request names the server's own file name")
        }
    }

    func testProgressReportsEveryPhaseInOrder() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let log = ProgressLog()
        _ = try await store.prepare(twoDiscGame(), progress: log.sink)

        let names = log.names
        XCTAssertEqual(names.first, "planning")
        XCTAssertEqual(names.last, "promoting")
        let rank = ["planning": 0, "checkingSpace": 1, "downloading": 2,
                    "validating": 3, "promoting": 4]
        XCTAssertEqual(names.map { rank[$0]! }, names.map { rank[$0]! }.sorted(),
                       "phases never run backwards: \(names)")
        XCTAssertTrue(names.contains("checkingSpace"))
        XCTAssertTrue(names.contains("validating"))
    }

    // MARK: - Cache revalidation

    func testUnchangedRemoteMetadataDownloadsNothing() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let first = try await store.prepare(twoDiscGame())
        let before = snapshot(canonicalDirectory(cacheRoot, 8300))
        library.resetCounters()

        let second = try await store.prepare(twoDiscGame())

        XCTAssertEqual(library.transferCount, 0)
        XCTAssertEqual(second.launchURL, first.launchURL)
        XCTAssertEqual(second.totalBytes, first.totalBytes)
        XCTAssertEqual(second.discLabels, first.discLabels)
        XCTAssertEqual(snapshot(canonicalDirectory(cacheRoot, 8300)), before)
        XCTAssertEqual(library.detailsCalls.sorted(), [8300, 8301],
                       "metadata is still refreshed on a cache hit")
    }

    func testChangedRemoteHashTriggersRebuild() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        library.resetCounters()

        let track = library.file(named: "Vault Runner (Disc 1) (Track 1).bin", in: 8300)
        let replacement = FakeLibrary.bytes(id: track.id &+ 5000, count: Int(track.sizeBytes))
        library.replaceFile(romID: 8300, fileID: track.id) { row in
            var digest = IncrementalFileDigest(); digest.update(replacement)
            let computed = digest.finalized()
            return RomFile(id: row.id, fileName: row.fileName, filePath: row.filePath,
                           sizeBytes: row.sizeBytes, isTopLevel: row.isTopLevel,
                           crcHash: computed.crc32, md5Hash: computed.md5,
                           sha1Hash: computed.sha1, updatedAt: row.updatedAt)
        }

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }
        XCTAssertGreaterThan(library.transferCount, 0, "a changed hash must force a rebuild")
    }

    func testChangedRemoteUpdatedAtTriggersRebuild() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        library.resetCounters()

        let track = library.file(named: "Vault Runner (Disc 1) (Track 2).bin", in: 8300)
        library.replaceFile(romID: 8300, fileID: track.id) { row in
            RomFile(id: row.id, fileName: row.fileName, filePath: row.filePath,
                    sizeBytes: row.sizeBytes, isTopLevel: row.isTopLevel, crcHash: row.crcHash,
                    md5Hash: row.md5Hash, sha1Hash: row.sha1Hash,
                    updatedAt: "2026-06-06T06:06:06")
        }

        _ = try await store.prepare(twoDiscGame())
        XCTAssertGreaterThan(library.transferCount, 0, "a changed updated_at must force a rebuild")
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), ["8300"])
    }

    func testSuccessfulRebuildOverAnExistingPackageLeavesNoBackup() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        library.resetCounters()

        // Move the metadata on so the second prepare rebuilds over a package that
        // is already there, which is the only path that takes promotion's backup
        // branch. The negative rule (never remove the backup before the install)
        // has three tests; this is the positive one.
        let track = library.file(named: "Vault Runner (Disc 1) (Track 1).bin", in: 8300)
        library.replaceFile(romID: 8300, fileID: track.id) { row in
            RomFile(id: row.id, fileName: row.fileName, filePath: row.filePath,
                    sizeBytes: row.sizeBytes, isTopLevel: row.isTopLevel, crcHash: row.crcHash,
                    md5Hash: row.md5Hash, sha1Hash: row.sha1Hash,
                    updatedAt: "2026-08-08T08:08:08")
        }

        _ = try await store.prepare(twoDiscGame())

        XCTAssertGreaterThan(library.transferCount, 0, "precondition: this was a rebuild")
        let root = platformRoot(in: cacheRoot)
        XCTAssertEqual(backupDirectories(in: root), [],
                       "a leaked backup is a whole duplicate game on a purgeable cache")
        XCTAssertEqual(entries(in: root), ["8300"])
        XCTAssertNil(invalidation(at: canonicalDirectory(cacheRoot, 8300), for: twoDiscGame()))
    }

    func testConcurrentPreparesForOneGameLeaveOneValidPackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        // Install first, then move the metadata on, so both entrants below rebuild
        // over an existing package and both take promotion's *backup* branch.
        // Against an empty cache root the first entrant returns from inside
        // `promote`'s no-canonical guard after a single rename, so only the second
        // can ever reach the backup branch — and the window this test exists for,
        // one promotion's backup rename landing between another's backup and
        // install, is unreachable however the two are scheduled.
        _ = try await store.prepare(twoDiscGame())
        let track = library.file(named: "Vault Runner (Disc 1) (Track 1).bin", in: 8300)
        library.replaceFile(romID: 8300, fileID: track.id) { row in
            RomFile(id: row.id, fileName: row.fileName, filePath: row.filePath,
                    sizeBytes: row.sizeBytes, isTopLevel: row.isTopLevel, crcHash: row.crcHash,
                    md5Hash: row.md5Hash, sha1Hash: row.sha1Hash,
                    updatedAt: "2026-10-10T10:10:10")
        }
        library.resetCounters()
        // Yielding inside every transfer makes the two runs interleave at the
        // actor's suspension points instead of running end to end. What keeps the
        // canonical path safe is that `promote` has none — see its doc comment.
        library.transferHook = { _, _ in
            for _ in 0..<4 { await Task.yield() }
        }

        async let first = store.prepare(twoDiscGame())
        async let second = store.prepare(twoDiscGame())
        let (a, b) = try await (first, second)

        // Each entrant reaches its first `await` — the metadata load — before the
        // other can promote, so both see the stale package and both rebuild. That
        // is what puts two tasks in the backup branch.
        XCTAssertEqual(library.transferCount, 12, "both runs must rebuild all six files")
        XCTAssertEqual(a.launchURL, b.launchURL)
        XCTAssertEqual(a.totalBytes, b.totalBytes)
        let root = platformRoot(in: cacheRoot)
        XCTAssertEqual(entries(in: root), ["8300"])
        XCTAssertEqual(partFiles(in: root), [])
        XCTAssertNil(invalidation(at: canonicalDirectory(cacheRoot, 8300), for: twoDiscGame()))
    }

    func testChangedRemoteFileIDTriggersRebuild() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        library.resetCounters()

        let track = library.file(named: "Signal Drift.bin", in: 8400)
        let bytes = library.bytes(forFileID: track.id)!
        let renumbered = FakeLibrary.file(id: 12345, name: track.fileName, path: track.filePath,
                                          data: bytes, isTopLevel: track.isTopLevel,
                                          updatedAt: track.updatedAt)
        let current = library.details(for: 8400)
        library.setDetails(RomDetails(id: current.id, fsName: current.fsName,
                                      files: current.files.map { $0.id == track.id ? renumbered : $0 }),
                           for: 8400)

        await assertThrowsSomething { _ = try await store.prepare(self.singleDiscGame()) }
        XCTAssertGreaterThan(library.transferCount, 0, "a changed file id must force a rebuild")
    }

    func testChangedRemoteSizeTriggersRebuild() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        library.resetCounters()

        let track = library.file(named: "Signal Drift.bin", in: 8400)
        library.replaceFile(romID: 8400, fileID: track.id) { row in
            RomFile(id: row.id, fileName: row.fileName, filePath: row.filePath,
                    sizeBytes: row.sizeBytes + 16, isTopLevel: row.isTopLevel,
                    crcHash: row.crcHash, md5Hash: row.md5Hash, sha1Hash: row.sha1Hash,
                    updatedAt: row.updatedAt)
        }

        await assertThrowsSomething { _ = try await store.prepare(self.singleDiscGame()) }
        XCTAssertGreaterThan(library.transferCount, 0, "a changed size must force a rebuild")
    }

    func testNewSubchannelFileOnTheServerTriggersRebuild() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        library.resetCounters()

        let current = library.details(for: 8400)
        let sbi = FakeLibrary.file(id: 13579, name: "Signal Drift.sbi", path: current.fsName,
                                   data: FakeLibrary.bytes(id: 13579, count: 128),
                                   isTopLevel: true, updatedAt: "2026-01-01T00:00:00")
        library.setDetails(RomDetails(id: current.id, fsName: current.fsName,
                                      files: current.files + [sbi]), for: 8400)

        // The library has no bytes registered for 13579, so the rebuild fails —
        // what is under test is that a rebuild is attempted at all.
        await assertThrowsSomething { _ = try await store.prepare(self.singleDiscGame()) }
        XCTAssertGreaterThan(library.transferCount, 0,
                             "a newly published SBI must not be masked by an unchanged manifest")
    }

    func testMissingLocalFileInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        try FileManager.default.removeItem(at:
            package.appendingPathComponent("disc-01/Signal Drift.bin"))

        XCTAssertEqual(invalidation(at: package, for: singleDiscGame()),
                       .missingFile("disc-01/Signal Drift.bin"))
        library.resetCounters()
        _ = try await store.prepare(singleDiscGame())
        XCTAssertGreaterThan(library.transferCount, 0)
        XCTAssertNotNil(snapshot(package)["disc-01/Signal Drift.bin"])
    }

    func testWrongSizeLocalFileInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        let track = package.appendingPathComponent("disc-01/Signal Drift.bin")
        let short = try Data(contentsOf: track).dropLast(8)
        try short.write(to: track)

        guard case let .wrongSize(path, _, actual) =
                invalidation(at: package, for: singleDiscGame()) else {
            return XCTFail("expected a size invalidation")
        }
        XCTAssertEqual(path, "disc-01/Signal Drift.bin")
        XCTAssertEqual(actual, Int64(short.count))
    }

    func testSameSizeFileWithChangedModificationDateIsRehashed() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        let track = package.appendingPathComponent("disc-01/Signal Drift.bin")
        let original = try Data(contentsOf: track)

        var mutated = original
        mutated[mutated.count - 1] ^= 0xFF
        try mutated.write(to: track)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: track.path)

        XCTAssertEqual(invalidation(at: package, for: singleDiscGame()),
                       .hashMismatch("disc-01/Signal Drift.bin"))
        library.resetCounters()
        _ = try await store.prepare(singleDiscGame())
        XCTAssertGreaterThan(library.transferCount, 0)
        XCTAssertEqual(try Data(contentsOf: track), original, "the good bytes came back")
    }

    func testSameSizeFileWithUnchangedMetadataIsNotRehashed() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        let track = package.appendingPathComponent("disc-01/Signal Drift.bin")

        // Same size, same recorded modification date, different bytes: the stored
        // local metadata says nothing changed, so no rehash is performed and the
        // package still validates. This is the cost of not reading 480 MB on every
        // launch, and it is deliberate — pinned so the trade cannot be reversed by
        // accident in either direction.
        let recordedDate = try manifest(at: package).discs[0].files
            .first { $0.path == "disc-01/Signal Drift.bin" }!.localModifiedAt
        var mutated = try Data(contentsOf: track)
        mutated[0] ^= 0xFF
        try mutated.write(to: track)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: recordedDate)],
            ofItemAtPath: track.path)

        XCTAssertNil(invalidation(at: package, for: singleDiscGame()))
    }

    func testMissingManifestInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        try FileManager.default.removeItem(at: package.appendingPathComponent("package.json"))

        XCTAssertEqual(invalidation(at: package, for: singleDiscGame()), .noManifest)
    }

    func testUnsupportedManifestVersionInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        let url = package.appendingPathComponent("package.json")
        var raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        raw = raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
            .replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        try Data(raw.utf8).write(to: url)

        XCTAssertEqual(invalidation(at: package, for: singleDiscGame()),
                       .unsupportedManifestVersion(99))
    }

    func testTamperedPlaylistInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        try Data("disc-01/Something Else.cue\n".utf8)
            .write(to: package.appendingPathComponent("game.m3u"))

        XCTAssertEqual(invalidation(at: package, for: singleDiscGame()), .playlistMismatch)
    }

    func testDifferentDiscSetInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)

        let oneDisc = game(canonical: 8300, discs: [(8300, 1)])
        XCTAssertEqual(invalidation(at: package, for: oneDisc), .discSetChanged)
    }

    // MARK: - Offline versus broken

    func testConnectivityFailureWithValidCacheReturnsTheCachedPlaylist() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let first = try await store.prepare(twoDiscGame())
        let before = snapshot(canonicalDirectory(cacheRoot, 8300))
        library.resetCounters()
        library.detailsHook = { _ in throw URLError(.notConnectedToInternet) }

        let offline = try await store.prepare(twoDiscGame())

        XCTAssertEqual(offline.launchURL, first.launchURL)
        XCTAssertEqual(offline.totalBytes, first.totalBytes)
        XCTAssertEqual(offline.discLabels, first.discLabels)
        XCTAssertEqual(library.transferCount, 0)
        XCTAssertEqual(snapshot(canonicalDirectory(cacheRoot, 8300)), before)
    }

    func testConnectivityFailureWithoutAValidCacheIsSurfaced() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        library.detailsHook = { _ in throw URLError(.notConnectedToInternet) }
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        do {
            _ = try await store.prepare(twoDiscGame())
            XCTFail("expected the connectivity error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testHTTPFailureIsSurfacedRatherThanTreatedAsOffline() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        library.detailsHook = { _ in throw RommError.http(401) }

        await assertThrows(RommError.http(401)) { _ = try await store.prepare(self.twoDiscGame()) }
    }

    func testDecodeFailureIsSurfacedRatherThanTreatedAsOffline() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        library.detailsHook = { _ in
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "not JSON"))
        }

        do {
            _ = try await store.prepare(twoDiscGame())
            XCTFail("expected the decode error")
        } catch is DecodingError {
            // expected
        }
    }

    func testCancellationErrorIsNeverReclassifiedAsOffline() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        // A classifier that calls *everything* connectivity: only an explicit
        // cancellation check upstream of it can keep this test honest.
        let store = try makeStore(cacheRoot: cacheRoot, library: library,
                                  isConnectivityError: { _ in true })
        _ = try await store.prepare(twoDiscGame())
        library.detailsHook = { _ in throw CancellationError() }

        do {
            _ = try await store.prepare(twoDiscGame())
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testCancelledTaskIsNotReportedAsOfflineEvenWithAConnectivityError() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())

        let entered = Signal()
        library.detailsHook = { _ in
            entered.raise()
            while !Task.isCancelled { await Task.yield() }
            // A cancelled transfer surfaces as a transport error; if the store
            // classified it by shape alone it would answer "you are offline" and
            // hand back a package the caller has already abandoned.
            throw URLError(.notConnectedToInternet)
        }

        let task = Task { try await store.prepare(self.twoDiscGame()) }
        await entered.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testDefaultConnectivityClassifierAcceptsOnlyTransportFailures() {
        let connectivity: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
            .dataNotAllowed, .callIsActive,
        ]
        for code in connectivity {
            XCTAssertTrue(PS1PackageStore.isLikelyConnectivityError(URLError(code)),
                          "\(code) should read as offline")
        }
        let notConnectivity: [Error] = [
            URLError(.userAuthenticationRequired),
            URLError(.badServerResponse),
            URLError(.cancelled),
            URLError(.badURL),
            RommError.http(401),
            RommError.http(500),
            RommError.badResponse,
            CancellationError(),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")),
            FileIntegrityError.httpStatus(403),
        ]
        for error in notConnectivity {
            XCTAssertFalse(PS1PackageStore.isLikelyConnectivityError(error),
                           "\(error) must not read as offline")
        }
    }

    // MARK: - Rejections before any download

    func testUnsafeRemoteCueNamesAreRejectedBeforeAnyDownload() async throws {
        let unsafe = ["", ".", "..", "/absolute.cue", "sub/nested.cue", "sub\\nested.cue",
                      "bad\u{0007}name.cue", "https://elsewhere.invalid/x.cue", "C:\\disc.cue",
                      " leading.cue", "name\u{202E}.cue", "~/home.cue", "#directive.cue",
                      ".hidden.cue", "half%2Fescaped.cue"]
        for name in unsafe {
            let cacheRoot = try tempDirectory()
            let library = FakeLibrary()
            library.add(.init(romID: 8400, folder: "psx/Signal Drift", cueName: name,
                              tracks: ["Signal Drift.bin"]))
            let store = try makeStore(cacheRoot: cacheRoot, library: library)

            await assertThrowsSomething("cue name \(name.debugDescription)") {
                _ = try await store.prepare(self.singleDiscGame())
            }
            XCTAssertEqual(library.transferCount, 0,
                           "\(name.debugDescription) must be refused before any request")
            XCTAssertEqual(stagingDirectories(in: platformRoot(in: cacheRoot)), [])
        }
    }

    func testRemoteCueNameWithASeparatorIsRejectedAsAPath() async throws {
        for name in ["sub/nested.cue", "sub\\nested.cue"] {
            let cacheRoot = try tempDirectory()
            let library = FakeLibrary()
            library.add(.init(romID: 8400, folder: "psx/Signal Drift", cueName: name,
                              tracks: ["Signal Drift.bin"]))
            let store = try makeStore(cacheRoot: cacheRoot, library: library)

            await assertThrows(PS1PackageError.remoteFileNameIsAPath(name)) {
                _ = try await store.prepare(self.singleDiscGame())
            }
            XCTAssertEqual(library.transferCount, 0)
        }
    }

    func testUnsupportedTopLevelLaunchExtensionNamesTheDiscImage() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        // A rip with no cue: a large image plus a small sidecar. RomM marks every
        // row top-level, so the message has to pick by size — naming the sidecar
        // would say "stored as \"Signal Drift.bin\". RommpleTV plays cue/bin discs
        // only", which is both wrong and self-contradicting.
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.iso", tracks: ["Signal Drift.bin"],
                          cueTextOverride: String(repeating: "0", count: 1 << 16)))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        XCTAssertLessThan(library.file(named: "Signal Drift.bin", in: 8400).sizeBytes,
                          library.file(named: "Signal Drift.iso", in: 8400).sizeBytes,
                          "precondition: the sidecar sorts first alphabetically and is smaller")

        await assertThrows(PS1PackageError.unsupportedLaunchFile(
            label: "Disc 1", fileName: "Signal Drift.iso")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferCount, 0)
    }

    func testMultipleTopLevelCuesAreRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"],
                          extras: [.init(name: "Signal Drift (alt).cue",
                                         isTopLevel: true, size: 128)]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.multipleLaunchFiles(
            label: "Disc 1", names: ["Signal Drift (alt).cue", "Signal Drift.cue"])) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferCount, 0)
    }

    func testDiscWithNoTopLevelFilesIsRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"],
                          cueIsTopLevel: false, tracksAreTopLevel: false))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.noLaunchFile(label: "Disc 1")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferCount, 0)
    }

    func testCueShapedTrackDirectoryCollidesWithTheCueAndIsRejected() async throws {
        // The residual Task 4 left: intermediate path components are not
        // extension-checked, so `Signal Drift.cue/track01.bin` parses. It would put
        // a directory where the disc's own cue has to be a file.
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue",
                          tracks: ["Signal Drift.cue/track01.bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.collidingPackagePaths(
            "disc-01/Signal Drift.cue", "disc-01/Signal Drift.cue/track01.bin")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferredFileIDs,
                       [library.file(named: "Signal Drift.cue", in: 8400).id],
                       "the plan is refused once the cue is parsed and before any track")
    }

    func testCaseFoldedCueShapedTrackDirectoryIsRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue",
                          tracks: ["SIGNAL DRIFT.CUE/track01.bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.collidingPackagePaths(
            "disc-01/Signal Drift.cue", "disc-01/SIGNAL DRIFT.CUE/track01.bin")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferredFileIDs,
                       [library.file(named: "Signal Drift.cue", in: 8400).id])
    }

    func testUnicodeFoldedDestinationCollisionIsRejected() async throws {
        // Composed vs decomposed "é": one file name on the destination filesystem,
        // two distinct byte strings on the wire.
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Caf\u{00E9}.cue",
                          tracks: ["Cafe\u{0301}.cue/track01.bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.collidingPackagePaths(
            "disc-01/Caf\u{00E9}.cue", "disc-01/Cafe\u{0301}.cue/track01.bin")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferredFileIDs,
                       [library.file(named: "Caf\u{00E9}.cue", in: 8400).id])
    }

    func testTheSameRemoteFileForTwoDestinationsIsRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        // Make disc 2's track row carry disc 1's track id: one server file, two
        // package destinations, and a "unique remote files" total that would lie.
        let shared = library.file(named: "Vault Runner (Disc 1) (Track 1).bin", in: 8300)
        let discTwo = library.details(for: 8301)
        let rewritten = discTwo.files.map { row -> RomFile in
            guard row.fileName.hasSuffix(".bin") else { return row }
            return RomFile(id: shared.id, fileName: row.fileName, filePath: row.filePath,
                           sizeBytes: row.sizeBytes, isTopLevel: row.isTopLevel,
                           crcHash: row.crcHash, md5Hash: row.md5Hash, sha1Hash: row.sha1Hash,
                           updatedAt: row.updatedAt)
        }
        library.setDetails(RomDetails(id: discTwo.id, fsName: discTwo.fsName, files: rewritten),
                           for: 8301)
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }
        XCTAssertEqual(Set(library.transferredFileIDs),
                       Set([library.file(named: "Vault Runner (Disc 1).cue", in: 8300).id,
                            library.file(named: "Vault Runner (Disc 2).cue", in: 8301).id]),
                       "refused once both cues are parsed and before any track")
    }

    func testDuplicateDiscIndexIsRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let broken = game(canonical: 8300, discs: [(8300, 1), (8301, 1)])

        await assertThrows(PS1PackageError.duplicateDiscIndex(1)) {
            _ = try await store.prepare(broken)
        }
        XCTAssertEqual(library.transferCount, 0)
    }

    func testOversizedCueIsRefusedBeforeItIsFetched() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let cue = library.file(named: "Signal Drift.cue", in: 8400)
        library.replaceFile(romID: 8400, fileID: cue.id) { row in
            RomFile(id: row.id, fileName: row.fileName, filePath: row.filePath,
                    sizeBytes: Int64(CueSheet.maximumByteCount) + 1, isTopLevel: row.isTopLevel,
                    crcHash: row.crcHash, md5Hash: row.md5Hash, sha1Hash: row.sha1Hash,
                    updatedAt: row.updatedAt)
        }
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.launchFileTooLarge(
            label: "Disc 1", byteCount: Int64(CueSheet.maximumByteCount) + 1,
            limit: CueSheet.maximumByteCount)) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferCount, 0)
    }

    // MARK: - Capacity

    func testInsufficientConservativeCapacityFailsBeforeTheFirstRequest() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library, capacity: { 1024 })

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }
        XCTAssertEqual(library.transferCount, 0, "capacity is checked before any content request")
        XCTAssertEqual(stagingDirectories(in: platformRoot(in: cacheRoot)), [])
    }

    func testConservativeCapacityCountsCueBinAndSubchannelOnly() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"],
                          subchannelName: "Signal Drift.sbi",
                          extras: [.init(name: "cover.png", isTopLevel: true, size: 1 << 20)]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library, capacity: { 1024 })
        let log = ProgressLog()

        await assertThrowsSomething {
            _ = try await store.prepare(self.singleDiscGame(), progress: log.sink)
        }
        let content = ["Signal Drift.cue", "Signal Drift.bin", "Signal Drift.sbi"]
            .reduce(Int64(0)) { $0 + library.file(named: $1, in: 8400).sizeBytes }
        XCTAssertEqual(log.requiredSpaceReports.first,
                       content + PS1PackageStore.capacitySafetyReserveBytes,
                       "artwork is not part of the disc")
    }

    func testExactCapacityIsRecheckedOnceTheCuesAreParsed() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let calls = Counter()
        let store = try makeStore(cacheRoot: cacheRoot, library: library,
                                  capacity: { calls.bump() == 0 ? (1 << 40) : 1024 })

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }

        let cueIDs = Set([library.file(named: "Vault Runner (Disc 1).cue", in: 8300).id,
                          library.file(named: "Vault Runner (Disc 2).cue", in: 8301).id])
        XCTAssertEqual(Set(library.transferredFileIDs), cueIDs,
                       "the recheck happens after the cues and before the tracks")
        XCTAssertEqual(stagingDirectories(in: platformRoot(in: cacheRoot)), [])
    }

    // MARK: - Atomicity

    func testSuccessfulPrepareLeavesNoStagingBackupOrPartFiles() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())

        let root = platformRoot(in: cacheRoot)
        XCTAssertEqual(entries(in: root), ["8300"])
        XCTAssertEqual(partFiles(in: root), [])
        let package = canonicalDirectory(cacheRoot, 8300)
        XCTAssertNotNil(snapshot(package)["package.json"])
        XCTAssertNotNil(snapshot(package)["game.m3u"])
    }

    func testFailedRebuildLeavesThePriorPackageByteIdentical() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)
        let before = snapshot(package)
        let datesBefore = modificationDates(package)

        // Force a rebuild (metadata moved on) and make it fail mid-transfer.
        let track = library.file(named: "Vault Runner (Disc 2) (Track 1).bin", in: 8301)
        library.replaceFile(romID: 8301, fileID: track.id) { row in
            RomFile(id: row.id, fileName: row.fileName, filePath: row.filePath,
                    sizeBytes: row.sizeBytes, isTopLevel: row.isTopLevel, crcHash: row.crcHash,
                    md5Hash: row.md5Hash, sha1Hash: row.sha1Hash, updatedAt: "2026-09-09T09:09:09")
        }
        library.transferHook = { fileID, _ in
            if fileID == track.id { throw FileIntegrityError.httpStatus(500) }
        }

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }

        XCTAssertEqual(snapshot(package), before)
        XCTAssertEqual(modificationDates(package), datesBefore)
        XCTAssertEqual(stagingDirectories(in: platformRoot(in: cacheRoot)), [])
        XCTAssertEqual(backupDirectories(in: platformRoot(in: cacheRoot)), [])
        XCTAssertEqual(partFiles(in: platformRoot(in: cacheRoot)), [])
    }

    func testFailureBeforeTheBackupLeavesThePriorPackageIntact() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)
        let before = snapshot(package)

        try FileManager.default.removeItem(at:
            package.appendingPathComponent("disc-01/Vault Runner (Disc 1) (Track 1).bin"))
        let stillThere = snapshot(package)
        await store.setPromotionProbe { stage in
            if stage == .beforeBackup { throw FileIntegrityError.httpStatus(507) }
        }

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }
        XCTAssertEqual(snapshot(package), stillThere)
        XCTAssertNotEqual(before, stillThere, "precondition: the package really was damaged first")
        XCTAssertEqual(stagingDirectories(in: platformRoot(in: cacheRoot)), [])
        XCTAssertEqual(backupDirectories(in: platformRoot(in: cacheRoot)), [])
    }

    func testFailureAfterTheBackupRollsThePriorPackageBack() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)
        let before = snapshot(package)

        try FileManager.default.removeItem(at:
            package.appendingPathComponent("disc-02/Vault Runner (Disc 2).cue"))
        let damaged = snapshot(package)
        await store.setPromotionProbe { stage in
            if stage == .afterBackup { throw FileIntegrityError.httpStatus(507) }
        }

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }

        // The canonical directory was renamed aside and put back: same bytes, same
        // path, nothing left over.
        XCTAssertEqual(snapshot(package), damaged)
        XCTAssertNotEqual(before, damaged, "precondition: the package really was damaged first")
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), ["8300"])
    }

    func testUnrollbackablePromotionReportsDamageAndKeepsTheBackup() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)
        let before = snapshot(package)
        try FileManager.default.removeItem(at:
            package.appendingPathComponent("disc-02/Vault Runner (Disc 2).cue"))
        let damaged = snapshot(package)

        // Occupy the canonical path while the backup is aside, so the rollback
        // rename cannot succeed either.
        await store.setPromotionProbe { stage in
            if stage == .afterBackup {
                try Data("blocked".utf8).write(to: package)
                throw FileIntegrityError.httpStatus(507)
            }
        }

        var reported: PS1PackageError?
        do {
            _ = try await store.prepare(twoDiscGame())
            XCTFail("expected damage to be reported")
        } catch let error as PS1PackageError {
            reported = error
        }
        guard case let .packageDamaged(romID, backupName)? = reported else {
            return XCTFail("expected packageDamaged, got \(String(describing: reported))")
        }
        XCTAssertEqual(romID, 8300)
        let backup = platformRoot(in: cacheRoot).appendingPathComponent(backupName)
        XCTAssertEqual(snapshot(backup), damaged, "the previous copy survives in the backup")
        XCTAssertNotEqual(before, damaged, "precondition")
    }

    func testInterruptedPromotionIsRepairedOnTheNextInitialization() throws {
        // The one window a power cut can land in: canonical renamed aside, new
        // package not yet installed.
        let cacheRoot = try tempDirectory()
        let root = platformRoot(in: cacheRoot)
        let backup = root.appendingPathComponent(".backup-8300-\(UUID().uuidString)",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: backup.appendingPathComponent("disc-01"),
                                                withIntermediateDirectories: true)
        try Data("playlist".utf8).write(to: backup.appendingPathComponent("game.m3u"))
        let expected = snapshot(backup)

        _ = try makeStore(cacheRoot: cacheRoot, library: FakeLibrary())

        XCTAssertEqual(entries(in: root), ["8300"])
        XCTAssertEqual(snapshot(canonicalDirectory(cacheRoot, 8300)), expected)
    }

    func testStaleBackupIsRemovedWhenTheCanonicalPackageSurvived() throws {
        let cacheRoot = try tempDirectory()
        let root = platformRoot(in: cacheRoot)
        let canonical = root.appendingPathComponent("8300", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: canonical.appendingPathComponent("game.m3u"))
        let backup = root.appendingPathComponent(".backup-8300-\(UUID().uuidString)",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: backup.appendingPathComponent("game.m3u"))

        _ = try makeStore(cacheRoot: cacheRoot, library: FakeLibrary())

        XCTAssertEqual(entries(in: root), ["8300"])
        XCTAssertEqual(snapshot(canonical)["game.m3u"], Data("new".utf8))
    }

    func testAnUnparsableBackupNameIsLeftAloneRatherThanDeleted() throws {
        // "I cannot tell which game this belongs to" is not a reason to delete a
        // whole package. It costs space; deleting it costs the only copy.
        let cacheRoot = try tempDirectory()
        let root = platformRoot(in: cacheRoot)
        let name = ".backup-not-a-number-\(UUID().uuidString)"
        let backup = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("playlist".utf8).write(to: backup.appendingPathComponent("game.m3u"))
        let expected = snapshot(backup)

        _ = try makeStore(cacheRoot: cacheRoot, library: FakeLibrary())

        XCTAssertEqual(entries(in: root), [name])
        XCTAssertEqual(snapshot(backup), expected)
    }

    func testInitializationRemovesAbandonedStagingButKeepsTheCanonicalPackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)
        let before = snapshot(package)

        let root = platformRoot(in: cacheRoot)
        let abandoned = root.appendingPathComponent(".staging-8300-\(UUID().uuidString)",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned.appendingPathComponent("disc-01"),
                                                withIntermediateDirectories: true)
        try Data("half".utf8).write(to:
            abandoned.appendingPathComponent("disc-01/track01.bin.part"))
        let otherGame = root.appendingPathComponent(".staging-9999-\(UUID().uuidString)",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: otherGame, withIntermediateDirectories: true)

        _ = try makeStore(cacheRoot: cacheRoot, library: library)

        XCTAssertEqual(entries(in: root), ["8300"])
        XCTAssertEqual(snapshot(package), before)
    }

    // MARK: - Cancellation

    func testCancellationRemovesStagingAndPartFiles() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let track = library.file(named: "Vault Runner (Disc 1) (Track 2).bin", in: 8300)
        // Worst case: a downloader that fails *and* leaves its part file behind.
        // Cleaning up after it is the store's job, not a courtesy.
        library.transferHook = { fileID, partURL in
            if fileID == track.id {
                try? Data("partial".utf8).write(to: partURL)
                throw CancellationError()
            }
        }

        do {
            _ = try await store.prepare(twoDiscGame())
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let root = platformRoot(in: cacheRoot)
        XCTAssertEqual(stagingDirectories(in: root), [])
        XCTAssertEqual(partFiles(in: root), [])
        XCTAssertEqual(entries(in: root), [])
    }

    func testCancellingTheTaskDuringATransferRemovesStaging() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let entered = Signal()
        library.transferHook = { _, _ in
            entered.raise()
            while !Task.isCancelled { await Task.yield() }
            try Task.checkCancellation()
        }

        let task = Task { try await store.prepare(self.twoDiscGame()) }
        await entered.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let root = platformRoot(in: cacheRoot)
        XCTAssertEqual(stagingDirectories(in: root), [])
        XCTAssertEqual(entries(in: root), [])
    }

    // MARK: - Staged verification

    func testATransferThatWritesNothingFailsTheRebuild() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let track = library.file(named: "Signal Drift.bin", in: 8400)
        library.transferHook = { fileID, partURL in
            guard fileID == track.id else { return }
            // Report success without leaving bytes anywhere.
            try? FileManager.default.removeItem(at: partURL)
            throw FileIntegrityError.bodyTooShort(expected: 1, actual: 0)
        }

        await assertThrowsSomething { _ = try await store.prepare(self.singleDiscGame()) }
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), [])
    }

    func testATrackVanishingMidRebuildIsCaughtBeforePromotion() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue",
                          tracks: ["Signal Drift (Track 1).bin", "Signal Drift (Track 2).bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let first = library.file(named: "Signal Drift (Track 1).bin", in: 8400)
        let second = library.file(named: "Signal Drift (Track 2).bin", in: 8400)
        // A purge lands on an already-written track while the next one transfers.
        library.transferHook = { fileID, partURL in
            guard fileID == second.id else { return }
            let staged = partURL.deletingLastPathComponent()
                .appendingPathComponent(first.fileName)
            try? FileManager.default.removeItem(at: staged)
        }

        await assertThrows(PS1PackageError.stagedFileMissing(
            "disc-01/Signal Drift (Track 1).bin")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), [])
    }

    // MARK: - Playlist

    func testSingleDiscProducesAOneEntryPlaylist() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let prepared = try await store.prepare(singleDiscGame())

        let package = canonicalDirectory(cacheRoot, 8400)
        XCTAssertEqual(try playlistLines(at: package), ["disc-01/Signal Drift.cue"])
        XCTAssertEqual(prepared.discLabels, ["Disc 1"])
        XCTAssertEqual(try manifest(at: package).playlist, ["disc-01/Signal Drift.cue"])
    }

    func testMultiDiscPlaylistOrderMatchesDiscIndex() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8300, folder: "psx/Vault Runner (Disc 1)",
                          cueName: "Vault Runner (Disc 1).cue",
                          tracks: ["Vault Runner (Disc 1).bin"]))
        library.add(.init(romID: 8301, folder: "psx/Vault Runner (Disc 2)",
                          cueName: "Vault Runner (Disc 2).cue",
                          tracks: ["Vault Runner (Disc 2).bin"]))
        library.add(.init(romID: 8302, folder: "psx/Vault Runner (Disc 3)",
                          cueName: "Vault Runner (Disc 3).cue",
                          tracks: ["Vault Runner (Disc 3).bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        // Discs handed over out of order on purpose.
        let shuffled = game(canonical: 8300, discs: [(8302, 3), (8300, 1), (8301, 2)])

        let prepared = try await store.prepare(shuffled)

        let package = canonicalDirectory(cacheRoot, 8300)
        XCTAssertEqual(try playlistLines(at: package),
                       ["disc-01/Vault Runner (Disc 1).cue",
                        "disc-02/Vault Runner (Disc 2).cue",
                        "disc-03/Vault Runner (Disc 3).cue"])
        XCTAssertEqual(prepared.discLabels, ["Disc 1", "Disc 2", "Disc 3"])
        XCTAssertEqual(try manifest(at: package).discs.map(\.index), [1, 2, 3])
    }

    func testAnUnwritablePlaylistEntryIsAnErrorRatherThanAShortPlaylist() throws {
        // `M3UWriter.data` answers `Data()` for *any* unsafe entry. Silently
        // accepting that would renumber every disc after the dropped one.
        XCTAssertThrowsError(try PS1PackageStore.playlistData(for: ["disc-01/ok.cue",
                                                                   "disc-02/../escape.cue"])) {
            XCTAssertEqual($0 as? PS1PackageError, PS1PackageError.emptyPlaylist(discCount: 2))
        }
        XCTAssertThrowsError(try PS1PackageStore.playlistData(for: [])) {
            XCTAssertEqual($0 as? PS1PackageError, PS1PackageError.emptyPlaylist(discCount: 0))
        }
        let good = try PS1PackageStore.playlistData(for: ["disc-01/ok.cue", "disc-02/ok.cue"])
        XCTAssertEqual(good, Data("disc-01/ok.cue\ndisc-02/ok.cue\n".utf8))
    }

    // MARK: - Manifest contents

    func testManifestRecordsRemoteAndLocalMetadata() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let prepared = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)
        let recorded = try manifest(at: package)

        XCTAssertEqual(recorded.version, PS1PackageManifest.currentVersion)
        XCTAssertEqual(recorded.canonicalRomID, 8300)
        XCTAssertEqual(recorded.totalBytes, prepared.totalBytes)
        XCTAssertEqual(recorded.playlist, try playlistLines(at: package))
        XCTAssertEqual(recorded.discs.map(\.romID), [8300, 8301])
        XCTAssertEqual(recorded.discs.map(\.directory), ["disc-01", "disc-02"])
        XCTAssertEqual(recorded.discs.map(\.label), ["Disc 1", "Disc 2"])

        let row = library.file(named: "Vault Runner (Disc 1) (Track 1).bin", in: 8300)
        let entry = recorded.discs[0].files.first { $0.remoteID == row.id }!
        XCTAssertEqual(entry.path, "disc-01/Vault Runner (Disc 1) (Track 1).bin")
        XCTAssertEqual(entry.remoteFileName, row.fileName)
        XCTAssertEqual(entry.remoteSizeBytes, row.sizeBytes)
        XCTAssertEqual(entry.remoteUpdatedAt, row.updatedAt)
        XCTAssertEqual(entry.remoteSHA1, row.sha1Hash)
        XCTAssertEqual(entry.remoteMD5, row.md5Hash)
        XCTAssertEqual(entry.remoteCRC32, row.crcHash)
        XCTAssertEqual(entry.localSizeBytes, row.sizeBytes)
        XCTAssertEqual(entry.localSHA1, row.sha1Hash)

        let onDisk = try FileManager.default.attributesOfItem(
            atPath: package.appendingPathComponent(entry.path).path)
        let modified = (onDisk[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        XCTAssertEqual(entry.localModifiedAt, modified, accuracy: 0.000_01)
    }

    // MARK: - Invariants the mutation run found unpinned

    func testInstallFailureAfterTheBackupStillRestoresThePriorPackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)
        try FileManager.default.removeItem(at:
            package.appendingPathComponent("disc-02/Vault Runner (Disc 2).cue"))
        let damaged = snapshot(package)

        // The install rename fails on its own — the probe does not throw — so the
        // rollback is the only thing that can put the package back. A backup
        // removed any earlier than "after the install succeeded" is a rollback that
        // cannot happen.
        let root = platformRoot(in: cacheRoot)
        await store.setPromotionProbe { stage in
            guard stage == .afterBackup else { return }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            where name.hasPrefix(".staging-") {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }

        await assertThrowsSomething { _ = try await store.prepare(self.twoDiscGame()) }
        XCTAssertEqual(snapshot(package), damaged)
        XCTAssertEqual(entries(in: root), ["8300"])
    }

    func testChangedDiscIdentityInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)

        // Same number of discs, different discs: a count check alone would pass.
        let renumbered = game(canonical: 8300, discs: [(8300, 1), (8399, 2)])
        XCTAssertEqual(invalidation(at: package, for: renumbered), .discSetChanged)

        let relabelled = PS1Game(
            representative: Rom(id: 8300, name: nil, fsName: "Vault Runner (Disc 1)",
                                platformId: 35, sizeBytes: nil, coverPath: nil),
            canonicalRomID: 8300,
            discs: [PS1Disc(romID: 8300, fileStem: "a", index: 1, label: "Disc 1"),
                    PS1Disc(romID: 8301, fileStem: "b", index: 2, label: "Second disc")],
            excludedSiblings: [])
        XCTAssertEqual(invalidation(at: package, for: relabelled), .discSetChanged)
    }

    func testASymlinkedPackageFileInvalidatesThePackage() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        let track = package.appendingPathComponent("disc-01/Signal Drift.bin")

        // Byte-identical content, reached through a link. A validator that follows
        // it is a validator that can be pointed anywhere.
        let elsewhere = cacheRoot.appendingPathComponent("elsewhere.bin")
        try Data(contentsOf: track).write(to: elsewhere)
        try FileManager.default.removeItem(at: track)
        try FileManager.default.createSymbolicLink(at: track, withDestinationURL: elsewhere)

        XCTAssertEqual(invalidation(at: package, for: singleDiscGame()),
                       .missingFile("disc-01/Signal Drift.bin"))
    }

    func testManifestCuePathThatIsNotOneOfTheDiscsFilesInvalidates() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)

        // The launch target has to be a file the validator actually checks.
        try rewriteManifest(at: package) { current in
            let disc = current.discs[0]
            return PS1PackageManifest(
                version: current.version, canonicalRomID: current.canonicalRomID,
                totalBytes: current.totalBytes, playlist: ["disc-01/Ghost.cue"],
                discs: [.init(romID: disc.romID, index: disc.index, label: disc.label,
                              directory: disc.directory, cuePath: "disc-01/Ghost.cue",
                              subchannelPath: disc.subchannelPath, files: disc.files)])
        }
        XCTAssertEqual(invalidation(at: package, for: singleDiscGame()), .playlistMismatch)
    }

    func testManifestPlaylistOutOfStepWithTheDiscsInvalidates() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(twoDiscGame())
        let package = canonicalDirectory(cacheRoot, 8300)

        // A playlist that is internally consistent with itself and with the m3u on
        // disk, and still names the discs in the wrong order.
        try rewriteManifest(at: package) { current in
            PS1PackageManifest(version: current.version, canonicalRomID: current.canonicalRomID,
                               totalBytes: current.totalBytes,
                               playlist: current.playlist.reversed(), discs: current.discs)
        }
        XCTAssertEqual(invalidation(at: package, for: twoDiscGame()), .playlistMismatch)
    }

    func testRepublishedCueWithANewFileIDTriggersRebuild() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        library.resetCounters()

        // A re-import gives the cue a new id. The old row lingers, demoted, with
        // metadata identical to what the manifest recorded — so every per-file
        // comparison still passes and only the cue's identity has moved.
        let old = library.file(named: "Signal Drift.cue", in: 8400)
        let bytes = library.bytes(forFileID: old.id)!
        let demoted = RomFile(id: old.id, fileName: old.fileName, filePath: old.filePath,
                              sizeBytes: old.sizeBytes, isTopLevel: false, crcHash: old.crcHash,
                              md5Hash: old.md5Hash, sha1Hash: old.sha1Hash,
                              updatedAt: old.updatedAt)
        let republished = FakeLibrary.file(id: 24680, name: old.fileName, path: old.filePath,
                                           data: bytes, isTopLevel: true,
                                           updatedAt: old.updatedAt)
        library.register(bytes, forFileID: 24680)
        let current = library.details(for: 8400)
        library.setDetails(
            RomDetails(id: current.id, fsName: current.fsName,
                       files: current.files.map { $0.id == old.id ? demoted : $0 } + [republished]),
            for: 8400)

        _ = try await store.prepare(singleDiscGame())
        XCTAssertTrue(library.transferredFileIDs.contains(24680),
                      "the package must be rebuilt around the cue that is now the launch file")
    }

    func testFoldedCollisionBetweenACueReferenceAndTheSubchannelFileIsRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        // The cue references the SBI in a different case. `CueSheet.resolve` folds
        // and matches the same row, so one server file wants two destinations that
        // are one file on this device.
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"],
                          subchannelName: "Signal Drift.sbi",
                          cueTextOverride: FakeLibrary.cueText(
                            referencing: ["Signal Drift.bin", "signal drift.sbi"])))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        await assertThrows(PS1PackageError.collidingPackagePaths(
            "disc-01/signal drift.sbi", "disc-01/Signal Drift.sbi")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
    }

    func testAStrayShallowRomFileRowDoesNotShiftTheDiscRoot() async throws {
        // `CueSheet.resolve` derives the disc root from the longest prefix every
        // row shares, so one row RomM lists a level up would otherwise shift every
        // relative path and fail the disc.
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"],
                          extras: [.init(name: "notes.txt", isTopLevel: false, size: 32,
                                         path: "psx")]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)

        let prepared = try await store.prepare(singleDiscGame())
        XCTAssertEqual(try playlistLines(at: canonicalDirectory(cacheRoot, 8400)),
                       ["disc-01/Signal Drift.cue"])
        XCTAssertNotNil(snapshot(prepared.launchURL.deletingLastPathComponent())[
            "disc-01/Signal Drift.bin"])
    }

    func testTheCapacitySafetyReserveIsHeldBack() async throws {
        XCTAssertEqual(PS1PackageStore.capacitySafetyReserveBytes, 64 << 20)
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let content = ["Signal Drift.cue", "Signal Drift.bin"]
            .reduce(Int64(0)) { $0 + library.file(named: $1, in: 8400).sizeBytes }
        // Room for the game and not a byte more.
        let store = try makeStore(cacheRoot: cacheRoot, library: library,
                                  capacity: { content })

        await assertThrows(PS1PackageError.insufficientCapacity(
            required: content + (64 << 20), available: content)) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(library.transferCount, 0)
    }

    func testEmptyDiscSetIsRejected() async throws {
        let cacheRoot = try tempDirectory()
        let library = singleDiscLibrary()
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let empty = PS1Game(
            representative: Rom(id: 8400, name: nil, fsName: "Signal Drift", platformId: 35,
                                sizeBytes: nil, coverPath: nil),
            canonicalRomID: 8400, discs: [], excludedSiblings: [])

        await assertThrows(PS1PackageError.noDiscs) { _ = try await store.prepare(empty) }
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), [])
    }

    func testACueRewrittenMidRebuildIsCaughtBeforePromotion() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue",
                          tracks: ["Signal Drift (Track 1).bin", "Signal Drift (Track 2).bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let second = library.file(named: "Signal Drift (Track 2).bin", in: 8400)
        // The staged cue is rewritten to the same byte count after it was parsed.
        // Its size and its recorded modification date both still agree with the
        // manifest, so only re-reading the cue itself can catch this.
        library.transferHook = { fileID, partURL in
            guard fileID == second.id else { return }
            let cue = partURL.deletingLastPathComponent()
                .appendingPathComponent("Signal Drift.cue")
            let text = String(decoding: try Data(contentsOf: cue), as: UTF8.self)
            try Data(text.replacingOccurrences(of: "(Track 1).bin", with: "(Track 9).bin").utf8)
                .write(to: cue)
        }

        await assertThrows(PS1PackageError.stagedFileMissing(
            "disc-01/Signal Drift (Track 9).bin")) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), [])
    }

    func testATruncatedStagedTrackIsCaughtBeforePromotion() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue",
                          tracks: ["Signal Drift (Track 1).bin", "Signal Drift (Track 2).bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let first = library.file(named: "Signal Drift (Track 1).bin", in: 8400)
        let second = library.file(named: "Signal Drift (Track 2).bin", in: 8400)
        library.transferHook = { fileID, partURL in
            guard fileID == second.id else { return }
            let staged = partURL.deletingLastPathComponent()
                .appendingPathComponent(first.fileName)
            try Data(contentsOf: staged).dropLast(16).write(to: staged)
        }

        await assertThrows(PS1PackageError.stagedFileWrongSize(
            "disc-01/Signal Drift (Track 1).bin", expected: first.sizeBytes,
            actual: first.sizeBytes - 16)) {
            _ = try await store.prepare(self.singleDiscGame())
        }
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), [])
    }

    func testCancellationBetweenTransfersStopsFurtherTransfers() async throws {
        let cacheRoot = try tempDirectory()
        let library = twoDiscLibrary()
        // A downloader that ignores cancellation entirely, so the store's own
        // checks are the only thing that can stop the run. On a 480 MB disc the
        // point of a cancellation check is that it stops the transfer, not that it
        // reports one afterwards.
        library.ignoresCancellation = true
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        let cues = Set([library.file(named: "Vault Runner (Disc 1).cue", in: 8300).id,
                        library.file(named: "Vault Runner (Disc 2).cue", in: 8301).id])
        let lastCue = library.file(named: "Vault Runner (Disc 2).cue", in: 8301).id
        let entered = Signal()
        library.transferHook = { fileID, _ in
            guard fileID == lastCue else { return }
            entered.raise()
            while !Task.isCancelled { await Task.yield() }
        }

        let task = Task { try await store.prepare(self.twoDiscGame()) }
        await entered.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(Set(library.transferredFileIDs), cues,
                       "no track may start after the task is cancelled")
        XCTAssertEqual(entries(in: platformRoot(in: cacheRoot)), [])
    }

    func testUppercaseServerHashesStillValidateAfterATouch() async throws {
        let cacheRoot = try tempDirectory()
        let library = FakeLibrary()
        library.uppercaseHashes = true
        library.add(.init(romID: 8400, folder: "psx/Signal Drift",
                          cueName: "Signal Drift.cue", tracks: ["Signal Drift.bin"]))
        let store = try makeStore(cacheRoot: cacheRoot, library: library)
        _ = try await store.prepare(singleDiscGame())
        let package = canonicalDirectory(cacheRoot, 8400)
        let track = package.appendingPathComponent("disc-01/Signal Drift.bin")

        // A touch that changes nothing but the timestamp forces a full rehash. The
        // recorded local digest has to be in the same case the rehash produces, so
        // it must be the computed one and not whatever spelling the server used.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)],
            ofItemAtPath: track.path)

        XCTAssertNil(invalidation(at: package, for: singleDiscGame()))
    }

    // MARK: - Measuring the real volume

    func testFreeBytesMeasuresTheVolumeAndReportsBothPlatformFigures() throws {
        // Every capacity test injects `measure`, so this is the only coverage the
        // production measurement path gets — which is how a key that is unavailable
        // on tvOS survived a green suite on macOS.
        let directory = try tempDirectory()

        let free = try PS1PackageStore.freeBytes(on: directory)
        XCTAssertGreaterThan(free, 0)

        // The tvOS branch, exercised here on macOS: on tvOS this *is* `freeBytes`.
        let fileSystemFree = try PS1PackageStore.fileSystemFreeBytes(on: directory)
        XCTAssertGreaterThan(fileSystemFree, 0)

        // Unmeasurable is not "no room": it throws, so a prepare fails rather than
        // silently treating the volume as full or as empty.
        let missing = directory.appendingPathComponent("no-such-volume", isDirectory: true)
        XCTAssertThrowsError(try PS1PackageStore.freeBytes(on: missing))
        XCTAssertThrowsError(try PS1PackageStore.fileSystemFreeBytes(on: missing))
    }

    // MARK: - Rehashing

    func testStreamingSHA1AgreesWithTheFullDigest() throws {
        // `sha1OfFile` runs SHA-1 alone rather than paying for MD5 and CRC-32 it
        // discards. Two formatters now produce the string the rehash compares, so
        // they are pinned against each other rather than trusted to agree.
        let directory = try tempDirectory()
        for count in [0, 1, 1 << 16, (1 << 16) * 3 + 517] {
            let url = directory.appendingPathComponent("blob-\(count).bin")
            let data = FakeLibrary.bytes(id: 7 + count, count: count)
            try data.write(to: url)
            var reference = IncrementalFileDigest()
            reference.update(data)
            XCTAssertEqual(PS1PackageStore.sha1OfFile(at: url), reference.finalized().sha1,
                           "\(count) bytes")
        }
    }

    func testStreamingSHA1StopsWhenTheTaskIsCancelled() async throws {
        let directory = try tempDirectory()
        let url = directory.appendingPathComponent("blob.bin")
        try FakeLibrary.bytes(id: 11, count: 1 << 18).write(to: url)

        // A cancelled prepare must not be stuck rehashing a whole disc on the
        // actor while everything else queues behind it.
        let task = Task { () -> String? in
            while !Task.isCancelled { await Task.yield() }
            return PS1PackageStore.sha1OfFile(at: url)
        }
        task.cancel()
        let hashed = await task.value
        XCTAssertNil(hashed)
    }

    // MARK: - Helpers

    private func rewriteManifest(
        at package: URL, _ transform: (PS1PackageManifest) -> PS1PackageManifest
    ) throws {
        let updated = transform(try manifest(at: package))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(to: package.appendingPathComponent("package.json"))
        try M3UWriter.data(cuePaths: updated.playlist)
            .write(to: package.appendingPathComponent("game.m3u"))
    }

    private func invalidation(at package: URL, for game: PS1Game) -> PS1PackageInvalidation? {
        switch PS1PackageStore.validatePackage(at: package, for: game) {
        case .success: return nil
        case let .failure(reason): return reason
        }
    }

    private func modificationDates(_ root: URL) -> [String: Date] {
        var result: [String: Date] = [:]
        for relative in snapshot(root).keys {
            let path = root.appendingPathComponent(relative).path
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attributes[.modificationDate] as? Date {
                result[relative] = date
            }
        }
        return result
    }

    private func assertThrows<E: Error & Equatable>(
        _ expected: E, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch let error as E {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error) \(message)", file: file, line: line)
        }
    }

    private func assertThrowsSomething(
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected a throw \(message)", file: file, line: line)
        } catch {
            // expected
        }
    }
}

/// A call counter shared with a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// Returns the count *before* this call.
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

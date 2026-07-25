import Combine
import XCTest
@testable import RommpleTVKit

// MARK: - Fixtures
//
// Nothing here is real library content. Titles are invented, bytes are generated
// from ids, and the one BIOS catalogue used is synthetic — the shipped
// catalogue's MD5s cannot be satisfied without a real BIOS image and this
// repository never contains one.

/// A local card area a test can inspect and make fail on demand.
private final class FakeSaveStore: SaveRAMStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [Int: Data] = [:]
    private(set) var saveCount = 0

    func load(romID: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return cards[romID]
    }

    func save(_ data: Data, romID: Int) throws {
        lock.lock(); defer { lock.unlock() }
        cards[romID] = data
        saveCount += 1
    }
}

/// A flag two tasks hand across, plus a wait that does **not** observe
/// cancellation — which is exactly what a "late completion from an obsolete
/// attempt" needs, since a cancellation-honouring stub could never produce one.
private final class LaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var entries = 0

    func enter() { lock.lock(); entries += 1; lock.unlock() }
    var entryCount: Int { lock.lock(); defer { lock.unlock() }; return entries }
    func open() { lock.lock(); opened = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }

    /// Suspends without a cancellation point.
    func waitUntilOpen() async {
        while !isOpen { await Self.tick() }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        for _ in 0..<4000 where entryCount < count { await Self.tick() }
    }

    private static func tick() async {
        await pause(0.001)
    }

    /// A suspension with no cancellation point, so a stub can model work that
    /// still has to finish after the task it belongs to has been cancelled —
    /// closing a file handle and removing a staging directory, for instance.
    static func pause(_ seconds: TimeInterval) async {
        await withUnsafeContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }
}

/// An ordered log of which seam ran, so "reconcile before any transfer" is an
/// assertion about order rather than about counts.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private func makeRom(id: Int = 7,
                     fsName: String = "Invented Title (USA).sfc",
                     sizeBytes: Int64? = 8,
                     regions: [String] = ["USA"],
                     siblings: [SiblingRom] = []) -> Rom {
    Rom(id: id, name: "Invented Title", fsName: fsName, platformId: 1,
        sizeBytes: sizeBytes, coverPath: nil, siblingRoms: siblings, regions: regions,
        fsNameNoExt: nil)
}

private func makeGame(canonicalRomID: Int = 101,
                      discs: [(Int, String)] = [(101, "Disc 1")],
                      representativeID: Int? = nil,
                      regions: [String] = ["USA"]) -> PS1Game {
    let representative = makeRom(id: representativeID ?? canonicalRomID,
                                 fsName: "Invented Disc Title (USA) (Disc 1).cue",
                                 sizeBytes: nil, regions: regions)
    return PS1Game(
        representative: representative,
        canonicalRomID: canonicalRomID,
        discs: discs.enumerated().map { offset, disc in
            PS1Disc(romID: disc.0, fileStem: "Invented Disc Title (USA) (\(disc.1))",
                    index: offset + 1, label: disc.1)
        },
        excludedSiblings: [])
}

private let legacyCore = CoreDescriptor(coreName: "snes9x_libretro_tvos", displayName: "snes9x")

/// The seams for one test, with every default a success.
private final class Harness: @unchecked Sendable {
    let log = EventLog()
    let legacyStore = FakeSaveStore()
    let playStationStore = FakeSaveStore()
    let root: URL

    var downloadedURL: URL
    var madePlayStationDependencies = 0
    var reconcileResult: @Sendable () async throws -> PS1SaveLaunchDecision
    var resolveHandler: @Sendable (PS1SaveConflict, PS1ConflictChoice) async throws -> Void
    var firmwareHandler: @Sendable (Int, [String],
                                    @escaping @Sendable (PS1PreparationProgress) -> Void)
        async throws -> URL
    var packageHandler: @Sendable (PS1Game,
                                   @escaping @Sendable (PS1PreparationProgress) -> Void)
        async throws -> PreparedDiscSet
    var legacyDownload: @Sendable (Rom, @escaping @Sendable (Double) -> Void) async throws -> URL
    /// Set to fail the test if the PlayStation factory is reached.
    var playStationFactoryIsForbidden = false
    private(set) var recordedResolves: [(UUID, PS1ConflictChoice)] = []
    private(set) var recordedPackageGames: [PS1Game] = []
    private(set) var recordedFirmwareCalls: [(Int, [String])] = []
    private let lock = NSLock()

    init(root: URL) {
        self.root = root
        let entry = root.appendingPathComponent("rom.sfc")
        let m3u = root.appendingPathComponent("game.m3u")
        let system = root.appendingPathComponent("ps1-system", isDirectory: true)
        downloadedURL = entry
        let log = self.log
        legacyDownload = { _, progress in
            log.record("legacy-download")
            progress(0.5)
            progress(1.0)
            return entry
        }
        reconcileResult = { log.record("reconcile"); return .ready }
        resolveHandler = { _, _ in log.record("resolve") }
        firmwareHandler = { _, _, _ in log.record("firmware"); return system }
        packageHandler = { _, _ in
            log.record("package")
            return PreparedDiscSet(entryURL: m3u, canonicalRomID: 101, discLabels: ["Disc 1"])
        }
    }

    var systemDirectory: URL { root.appendingPathComponent("ps1-system", isDirectory: true) }
    var playlistURL: URL { root.appendingPathComponent("game.m3u") }

    func dependencies() -> LaunchPreparationDependencies {
        let legacy = LegacyLaunchDependencies(
            download: { [self] rom, progress in try await legacyDownload(rom, progress) },
            systemDirectory: root.appendingPathComponent("legacy-system", isDirectory: true),
            saveDirectory: root.appendingPathComponent("legacy-saves", isDirectory: true),
            saveStore: legacyStore)
        return LaunchPreparationDependencies(legacy: legacy) { [self] game in
            if playStationFactoryIsForbidden {
                XCTFail("legacy preparation built a PlayStation dependency")
            }
            lock.lock(); madePlayStationDependencies += 1; lock.unlock()
            return PlayStationLaunchDependencies(
                reconcileSave: { try await self.reconcileResult() },
                resolveConflict: { conflict, choice in
                    self.lock.lock()
                    self.recordedResolves.append((conflict.id, choice))
                    self.lock.unlock()
                    try await self.resolveHandler(conflict, choice)
                },
                prepareFirmware: { platformID, regions, progress in
                    self.lock.lock()
                    self.recordedFirmwareCalls.append((platformID, regions))
                    self.lock.unlock()
                    return try await self.firmwareHandler(platformID, regions, progress)
                },
                preparePackage: { game, progress in
                    self.lock.lock()
                    self.recordedPackageGames.append(game)
                    self.lock.unlock()
                    return try await self.packageHandler(game, progress)
                },
                saveDirectory: self.root.appendingPathComponent("ps1-saves/\(game.canonicalRomID)",
                                                                isDirectory: true),
                saveStore: self.playStationStore,
                onLocalSave: { _ in self.log.record("onLocalSave") },
                retrySaveSync: { _ in self.log.record("retrySaveSync") },
                saveStatuses: AsyncStream { $0.finish() })
        }
    }

    var resolves: [(UUID, PS1ConflictChoice)] {
        lock.lock(); defer { lock.unlock() }; return recordedResolves
    }
    var packageGames: [PS1Game] {
        lock.lock(); defer { lock.unlock() }; return recordedPackageGames
    }
    var firmwareCalls: [(Int, [String])] {
        lock.lock(); defer { lock.unlock() }; return recordedFirmwareCalls
    }
    var playStationBuilds: Int {
        lock.lock(); defer { lock.unlock() }; return madePlayStationDependencies
    }
}

// MARK: - Tests

final class LaunchPreparationServiceTests: XCTestCase {
    private var tmp: URL!
    private var harness: Harness!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        harness = Harness(root: tmp)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func makeService(
        stage: @escaping @Sendable (LaunchStage) -> Void = { _ in }
    ) -> LaunchPreparationService {
        LaunchPreparationService(dependencies: harness.dependencies(), stage: stage)
    }

    private func prepared(_ decision: LaunchPreparationDecision,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> PreparedLaunch {
        guard case let .ready(launch) = decision else {
            XCTFail("expected a prepared launch, got \(decision)", file: file, line: line)
            throw XCTSkip("not ready")
        }
        return launch
    }

    // MARK: The legacy route is unchanged

    func testLegacyRequestUsesOnlyTheCacheManagerPathAndKeepsItsIdentity() async throws {
        harness.playStationFactoryIsForbidden = true
        let rom = makeRom()
        let service = makeService()

        let launch = try prepared(try await service.prepare(.legacy(rom: rom, core: legacyCore),
                                                            progress: { _ in }))

        XCTAssertEqual(harness.log.all, ["legacy-download"])
        XCTAssertEqual(harness.playStationBuilds, 0)
        XCTAssertEqual(launch.entryURL, harness.downloadedURL)
        XCTAssertEqual(launch.core, legacyCore)
        XCTAssertEqual(launch.systemDirectory,
                       tmp.appendingPathComponent("legacy-system", isDirectory: true))
        XCTAssertEqual(launch.saveDirectory,
                       tmp.appendingPathComponent("legacy-saves", isDirectory: true))
        XCTAssertEqual(launch.canonicalRomID, rom.id)
        XCTAssertTrue(launch.saveStore === harness.legacyStore)
        XCTAssertEqual(launch.discLabels, [])
        XCTAssertNil(launch.saveStatuses)
    }

    /// The two network callbacks a legacy launch carries do nothing at all —
    /// there is no server-side save for a cartridge, and a callback that quietly
    /// did something would be a behaviour change for every accepted platform.
    func testLegacyNetworkCallbacksAreNoOps() async throws {
        harness.playStationFactoryIsForbidden = true
        let service = makeService()
        let launch = try prepared(
            try await service.prepare(.legacy(rom: makeRom(), core: legacyCore),
                                      progress: { _ in }))

        launch.onLocalSave(Data("card".utf8))
        launch.retrySaveSync(.quit)

        XCTAssertEqual(harness.log.all, ["legacy-download"])
        XCTAssertEqual(harness.legacyStore.saveCount, 0)
    }

    /// The live wiring, against the real `CacheManager`: the same cache layout,
    /// the same system and save directories, and the same store the engine has
    /// always written through.
    func testLiveLegacyWiringKeepsTheExistingCacheLayout() async throws {
        StubProtocol.responder = { _ in (200, Data("ROMBYTES".utf8)) }
        let client = RommClient(config: RommConfig(baseURL: URL(string: "https://romm.invalid")!,
                                                   token: "not-a-secret"),
                                session: StubProtocol.session())
        let dependencies = LaunchPreparationDependencies.live(client: client, cachesRoot: tmp)
        let service = LaunchPreparationService(dependencies: dependencies)
        let rom = makeRom(fsName: "Invented Title (USA).sfc")

        let launch = try prepared(try await service.prepare(.legacy(rom: rom, core: legacyCore),
                                                            progress: { _ in }))

        XCTAssertEqual(launch.entryURL,
                       tmp.appendingPathComponent("roms", isDirectory: true)
                           .appendingPathComponent("7", isDirectory: true)
                           .appendingPathComponent("Invented Title (USA).sfc"))
        XCTAssertEqual(try Data(contentsOf: launch.entryURL), Data("ROMBYTES".utf8))
        XCTAssertEqual(launch.systemDirectory,
                       tmp.appendingPathComponent("system", isDirectory: true))
        XCTAssertEqual(launch.saveDirectory,
                       tmp.appendingPathComponent("saves", isDirectory: true))
        XCTAssertTrue(launch.saveStore is BatterySaveStore)
        XCTAssertEqual(launch.discLabels, [])
        XCTAssertNil(launch.saveStatuses)
    }

    func testLegacyProgressIsReportedAsBytesAgainstTheServerSize() async throws {
        harness.legacyDownload = { _, progress in
            progress(0.25)
            progress(1.0)
            return self.tmp.appendingPathComponent("rom.sfc")
        }
        let reported = ProgressRecorder()
        let service = makeService()
        _ = try await service.prepare(.legacy(rom: makeRom(sizeBytes: 400), core: legacyCore),
                                      progress: { reported.record($0) })

        XCTAssertEqual(reported.downloads.map(\.completed), [100, 400])
        XCTAssertEqual(reported.downloads.map(\.total), [400, 400])
        XCTAssertEqual(reported.downloads.map(\.label), ["Invented Title (USA).sfc",
                                                          "Invented Title (USA).sfc"])
    }

    /// A server that omits `fs_size_bytes` leaves the total unknown rather than
    /// inventing one; the view shows an indeterminate bar for that.
    func testLegacyProgressReportsAnUnknownTotalWhenTheServerOmitsTheSize() async throws {
        harness.legacyDownload = { _, progress in
            progress(0.5)
            return self.tmp.appendingPathComponent("rom.sfc")
        }
        let reported = ProgressRecorder()
        let service = makeService()
        _ = try await service.prepare(.legacy(rom: makeRom(sizeBytes: nil), core: legacyCore),
                                      progress: { reported.record($0) })

        XCTAssertEqual(reported.downloads.map(\.total), [0])
        XCTAssertNil(LaunchProgressSnapshot(stage: .checkingCache, detail: "",
                                            completedBytes: 0, totalBytes: 0).fraction)
    }

    // MARK: The PlayStation route

    func testPlayStationReconcilesTheSaveBeforeAnyRemoteContentTransfer() async throws {
        let game = makeGame(canonicalRomID: 101,
                            discs: [(101, "Disc 1"), (102, "Disc 2")])
        harness.packageHandler = { _, _ in
            self.harness.log.record("package")
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: ["Disc 1", "Disc 2"])
        }
        let service = makeService()

        let launch = try prepared(
            try await service.prepare(.playStation(game: game, platformID: 35),
                                      progress: { _ in }))

        XCTAssertEqual(harness.log.all, ["reconcile", "firmware", "package"])
        XCTAssertEqual(launch.entryURL, harness.playlistURL)
        XCTAssertEqual(launch.systemDirectory, harness.systemDirectory)
        XCTAssertEqual(launch.discLabels, ["Disc 1", "Disc 2"])
        XCTAssertEqual(launch.canonicalRomID, 101)
        XCTAssertEqual(launch.core.coreName, "mednafen_psx_libretro_tvos")
        XCTAssertTrue(launch.saveStore === harness.playStationStore)
        XCTAssertNotNil(launch.saveStatuses)
        XCTAssertEqual(harness.packageGames.map(\.canonicalRomID), [101])
        XCTAssertEqual(harness.firmwareCalls.map(\.0), [35])
        XCTAssertEqual(harness.firmwareCalls.map(\.1), [["USA"]])
    }

    /// The core is resolved through `PlatformSupport`, not spelled out here, so a
    /// map edit cannot silently launch a PlayStation disc in another emulator.
    func testPlayStationUsesThePlatformSupportCoreForPSX() async throws {
        let service = makeService()
        let launch = try prepared(
            try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                      progress: { _ in }))
        XCTAssertEqual(launch.core, PlatformSupport.core(forSlug: "psx"))
    }

    /// A save decision is the only thing a conflict costs: neither the BIOS nor a
    /// single byte of disc content has been asked for.
    func testSaveConflictSuspendsBeforeFirmwareOrPackageDownload() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: Date(timeIntervalSince1970: 10),
                                    remoteModifiedAt: Date(timeIntervalSince1970: 20))
        harness.reconcileResult = { self.harness.log.record("reconcile"); return .conflict(token) }
        let service = makeService()

        let decision = try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                                 progress: { _ in })

        guard case let .conflict(published) = decision else {
            return XCTFail("expected a conflict, got \(decision)")
        }
        XCTAssertEqual(published, token)
        XCTAssertEqual(harness.log.all, ["reconcile"])
        XCTAssertEqual(harness.firmwareCalls.count, 0)
        XCTAssertEqual(harness.packageGames.count, 0)
    }

    /// Offline reconciliation, real firmware manager, real package store: the
    /// BIOS is already on disk and the package's metadata refresh fails with a
    /// connectivity error, so both fall back to what is cached and the launch
    /// still happens.
    func testOfflineReconciliationStillPreparesFromCachedFirmwareAndPackage() async throws {
        let offline = URLError(.notConnectedToInternet)
        let library = MiniLibrary(romID: 501)
        let store = try PS1PackageStore(cacheRoot: tmp,
                                        loadDetails: { _ in library.details },
                                        buildRequest: { id, _ in library.request(fileID: id) },
                                        transfer: library.transfer)
        let game = PS1Game(representative: makeRom(id: 501, fsName: "Invented Offline (USA).cue",
                                                   sizeBytes: nil),
                           canonicalRomID: 501,
                           discs: [PS1Disc(romID: 501, fileStem: "Invented Offline (USA)",
                                           index: 1, label: "Disc 1")],
                           excludedSiblings: [])
        // One online run to leave a valid package on disk.
        _ = try await store.prepare(game)

        let catalog = MiniCatalog.make()
        let firmware = try PS1FirmwareManager(cacheRoot: tmp, catalog: catalog.catalog,
                                              loadFirmware: { _ in throw offline },
                                              buildRequest: { _, _ in
                                                  URLRequest(url: URL(string: "file:///none")!)
                                              },
                                              transfer: { _, _, _, _ in
                                                  throw offline
                                              })
        try catalog.install(into: firmware.systemDirectory)

        let offlineStore = try PS1PackageStore(cacheRoot: tmp,
                                               loadDetails: { _ in throw offline },
                                               buildRequest: { id, _ in library.request(fileID: id) },
                                               transfer: library.transfer)
        let dependencies = LaunchPreparationDependencies(
            legacy: harness.dependencies().legacy) { _ in
                PlayStationLaunchDependencies(
                    reconcileSave: { .ready },          // offline, local card in hand
                    resolveConflict: { _, _ in },
                    prepareFirmware: { platformID, regions, progress in
                        try await firmware.prepare(platformID: platformID, regions: regions,
                                                   progress: progress)
                    },
                    preparePackage: { game, progress in
                        let package = try await offlineStore.prepare(game, progress: progress)
                        return PreparedDiscSet(entryURL: package.launchURL,
                                               canonicalRomID: package.canonicalRomID,
                                               discLabels: package.discLabels)
                    },
                    saveDirectory: self.tmp.appendingPathComponent("ps1-saves"),
                    saveStore: self.harness.playStationStore,
                    onLocalSave: { _ in }, retrySaveSync: { _ in }, saveStatuses: nil)
            }

        let service = LaunchPreparationService(dependencies: dependencies)
        let launch = try prepared(
            try await service.prepare(.playStation(game: game, platformID: 35),
                                      progress: { _ in }))

        XCTAssertEqual(launch.systemDirectory, firmware.systemDirectory)
        XCTAssertEqual(launch.entryURL.lastPathComponent, "game.m3u")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.entryURL.path))
        XCTAssertEqual(launch.discLabels, ["Disc 1"])
    }

    // MARK: Cancellation

    func testCancellationReachesTheActivePackageOperationAndReturnsNoLaunch() async throws {
        let gate = LaunchGate()
        harness.packageHandler = { _, _ in
            self.harness.log.record("package")
            gate.enter()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            XCTFail("the package operation was not cancelled")
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: [])
        }
        let service = makeService()
        let attempt = Task { try await service.prepare(.playStation(game: makeGame(),
                                                                    platformID: 35),
                                                       progress: { _ in }) }
        await gate.waitUntilEntered()
        await service.cancel()

        do {
            _ = try await attempt.value
            XCTFail("a cancelled preparation returned a decision")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(harness.log.all, ["reconcile", "firmware", "package"])
    }

    func testCancellationReachesTheActiveFirmwareOperation() async throws {
        let gate = LaunchGate()
        harness.firmwareHandler = { _, _, _ in
            gate.enter()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            XCTFail("the firmware operation was not cancelled")
            return self.harness.systemDirectory
        }
        let service = makeService()
        let attempt = Task { try await service.prepare(.playStation(game: makeGame(),
                                                                    platformID: 35),
                                                       progress: { _ in }) }
        await gate.waitUntilEntered()
        await service.cancel()

        do {
            _ = try await attempt.value
            XCTFail("a cancelled preparation returned a decision")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(harness.packageGames.count, 0)
    }

    /// Both routes out of this boundary spell a cancellation the same way.
    /// `CacheManager` reports one as `URLError.cancelled`, which is a failure
    /// shape, not a decision shape.
    func testALegacyCancellationIsReportedAsCancellationNotAsAFailure() async throws {
        let gate = LaunchGate()
        harness.legacyDownload = { _, _ in
            gate.enter()
            await gate.waitUntilOpen()
            // What Foundation raises for an interrupted transfer.
            throw URLError(.cancelled)
        }
        let service = makeService()
        let attempt = Task { try await service.prepare(.legacy(rom: makeRom(), core: legacyCore),
                                                       progress: { _ in }) }
        await gate.waitUntilEntered()
        await service.cancel()
        gate.open()

        do {
            _ = try await attempt.value
            XCTFail("a cancelled legacy preparation returned a launch")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testACancelledServiceRefusesToPrepareAgain() async throws {
        let service = makeService()
        await service.cancel()
        do {
            _ = try await service.prepare(.legacy(rom: makeRom(), core: legacyCore),
                                          progress: { _ in })
            XCTFail("a cancelled service prepared a launch")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(harness.log.all, [])
    }

    /// One service is one attempt. A second concurrent `prepare` would put two
    /// writers on one staging path, which is the uniqueness the package store's
    /// promotion assumes.
    func testASecondConcurrentPreparationIsRefused() async throws {
        let gate = LaunchGate()
        harness.packageHandler = { _, _ in
            gate.enter()
            await gate.waitUntilOpen()
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: [])
        }
        let service = makeService()
        let first = Task { try await service.prepare(.playStation(game: makeGame(),
                                                                  platformID: 35),
                                                     progress: { _ in }) }
        await gate.waitUntilEntered()

        do {
            _ = try await service.prepare(.legacy(rom: makeRom(), core: legacyCore),
                                          progress: { _ in })
            XCTFail("a second concurrent preparation was allowed")
        } catch LaunchPreparationError.alreadyPreparing {
        } catch {
            XCTFail("expected alreadyPreparing, got \(error)")
        }
        gate.open()
        _ = try await first.value
    }

    // MARK: Conflict resolution

    func testResolveContinuesTheSameRequestForTheMatchingToken() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        harness.reconcileResult = { self.harness.log.record("reconcile"); return .conflict(token) }
        let game = makeGame(canonicalRomID: 101)
        let service = makeService()
        _ = try await service.prepare(.playStation(game: game, platformID: 35), progress: { _ in })

        let launch = try prepared(try await service.resolve(token, choice: .remote,
                                                            progress: { _ in }))

        XCTAssertEqual(harness.log.all, ["reconcile", "resolve", "firmware", "package"])
        XCTAssertEqual(harness.resolves.map(\.0), [token.id])
        XCTAssertEqual(harness.resolves.map(\.1), [.remote])
        XCTAssertEqual(harness.packageGames.map(\.canonicalRomID), [101])
        XCTAssertEqual(launch.entryURL, harness.playlistURL)
    }

    func testResolveRefusesATokenThisAttemptDidNotPublish() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        harness.reconcileResult = { .conflict(token) }
        let service = makeService()
        _ = try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                      progress: { _ in })

        let foreign = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        do {
            _ = try await service.resolve(foreign, choice: .local, progress: { _ in })
            XCTFail("a foreign token continued this attempt")
        } catch PS1SaveSyncError.conflictExpired {
        } catch {
            XCTFail("expected conflictExpired, got \(error)")
        }
        XCTAssertEqual(harness.resolves.count, 0)
        XCTAssertEqual(harness.firmwareCalls.count, 0)
    }

    func testResolveRefusesWhenNoConflictWasPublished() async throws {
        let service = makeService()
        _ = try await service.prepare(.legacy(rom: makeRom(), core: legacyCore),
                                      progress: { _ in })
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        do {
            _ = try await service.resolve(token, choice: .local, progress: { _ in })
            XCTFail("resolve continued a request that never conflicted")
        } catch PS1SaveSyncError.conflictExpired {
        } catch {
            XCTFail("expected conflictExpired, got \(error)")
        }
    }

    /// The three refusals the coordinator leaves a live token behind for keep the
    /// suspended request, so choosing again continues it rather than starting a
    /// fresh reconciliation that would mint a second token for the same cards.
    func testARecoverableResolutionFailureKeepsTheSuspendedRequest() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        harness.reconcileResult = { .conflict(token) }
        let attempts = Counter()
        harness.resolveHandler = { _, _ in
            if attempts.next() == 1 { throw PS1SaveSyncError.serverUnreachableDuringResolution }
        }
        let service = makeService()
        _ = try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                      progress: { _ in })

        do {
            _ = try await service.resolve(token, choice: .local, progress: { _ in })
            XCTFail("expected the resolution to fail")
        } catch PS1SaveSyncError.serverUnreachableDuringResolution {
        }
        let launch = try prepared(try await service.resolve(token, choice: .local,
                                                            progress: { _ in }))
        XCTAssertEqual(launch.entryURL, harness.playlistURL)
        XCTAssertEqual(harness.resolves.count, 2)
    }

    func testAnExpiredResolutionRetiresTheSuspendedRequest() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        harness.reconcileResult = { .conflict(token) }
        harness.resolveHandler = { _, _ in throw PS1SaveSyncError.conflictExpired }
        let service = makeService()
        _ = try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                      progress: { _ in })

        do {
            _ = try await service.resolve(token, choice: .local, progress: { _ in })
            XCTFail("expected conflictExpired")
        } catch PS1SaveSyncError.conflictExpired {}

        do {
            _ = try await service.resolve(token, choice: .local, progress: { _ in })
            XCTFail("a retired token was still accepted")
        } catch PS1SaveSyncError.conflictExpired {}
        XCTAssertEqual(harness.resolves.count, 1)
        XCTAssertEqual(harness.firmwareCalls.count, 0)
    }

    // MARK: Stages

    func testStagesAreReportedInOrderForAPlayStationLaunch() async throws {
        let stages = StageRecorder()
        harness.packageHandler = { _, progress in
            progress(.planning)
            progress(.downloading(label: "Disc 1", completed: 1, total: 2))
            progress(.validating(label: "Disc 1"))
            progress(.promoting)
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: ["Disc 1"])
        }
        harness.firmwareHandler = { _, _, progress in
            progress(.validating(label: "scph5501.bin"))
            progress(.downloading(label: "scph5501.bin", completed: 1, total: 2))
            return self.harness.systemDirectory
        }
        let service = makeService(stage: { stages.record($0) })
        _ = try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                      progress: { _ in })

        // Nothing after `.validating`: the store's `.promoting` is the second
        // half of the same finishing phase, and letting it fall back to `.discs`
        // made the last frame before a game started read "Discs" with an
        // indeterminate bar.
        XCTAssertEqual(stages.distinct,
                       [.checkingCache, .preparingSave, .firmware, .discs, .validating])
    }

    /// The firmware phase has no promotion of its own, and a `.promoting` that
    /// somehow arrived there must not be relabelled as the package's validation.
    func testPromotingOutsideTheDiscPhaseKeepsItsOwnStage() async throws {
        let stages = StageRecorder()
        harness.firmwareHandler = { _, _, progress in
            progress(.downloading(label: "scph5501.bin", completed: 1, total: 2))
            progress(.promoting)
            return self.harness.systemDirectory
        }
        harness.packageHandler = { _, _ in
            PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                            discLabels: [])
        }
        let service = makeService(stage: { stages.record($0) })
        _ = try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                      progress: { _ in })
        XCTAssertEqual(stages.distinct, [.checkingCache, .preparingSave, .firmware, .discs])
    }

    /// The firmware manager's own step-1 `.validating` is a BIOS check, not the
    /// package's per-disc validation, and must not read as a later stage.
    func testFirmwareValidationDoesNotReportTheValidatingStage() async throws {
        let stages = StageRecorder()
        harness.firmwareHandler = { _, _, progress in
            progress(.validating(label: "scph5501.bin"))
            return self.harness.systemDirectory
        }
        harness.packageHandler = { _, _ in
            PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                            discLabels: [])
        }
        let service = makeService(stage: { stages.record($0) })
        _ = try await service.prepare(.playStation(game: makeGame(), platformID: 35),
                                      progress: { _ in })
        XCTAssertEqual(stages.distinct, [.checkingCache, .preparingSave, .firmware, .discs])
    }

    /// A cartridge transfer says it is transferring.
    ///
    /// The screen this route replaced said "Downloading <name> — NN%". Leaving
    /// the stage on "Checking cache" for the whole of a multi-minute download
    /// was not a description of what the app was doing, and read as a hang.
    func testLegacyMovesOffCheckingCacheOnceTheTransferStarts() async throws {
        let stages = StageRecorder()
        let service = makeService(stage: { stages.record($0) })
        _ = try await service.prepare(.legacy(rom: makeRom(), core: legacyCore),
                                      progress: { _ in })
        XCTAssertEqual(stages.distinct, [.checkingCache, .downloading])
    }

    /// What the player actually reads: the stage names the transfer and the
    /// detail names the file, which is the sentence the deleted screen showed.
    func testLegacyDownloadHeadlineNamesTheTransferAndTheFile() async throws {
        harness.legacyDownload = { _, progress in
            progress(0.5)
            return self.tmp.appendingPathComponent("rom.sfc")
        }
        let snapshots = SnapshotSink()
        let throttle = LaunchProgressThrottle(interval: 0, now: { 0 },
                                              publish: { snapshots.record($0) })
        let service = makeService(stage: { throttle.setStage($0) })
        _ = try await service.prepare(.legacy(rom: makeRom(sizeBytes: 400), core: legacyCore),
                                      progress: { throttle.report($0) })
        throttle.flush()

        guard let last = snapshots.last else { return XCTFail("nothing was published") }
        XCTAssertEqual(last.headline, "Downloading")
        XCTAssertNotEqual(last.headline, LaunchStage.checkingCache.title)
        XCTAssertEqual(last.detail, "Invented Title (USA).sfc")
        XCTAssertEqual(last.completedBytes, 200)
        XCTAssertEqual(last.totalBytes, 400)
    }
}

// MARK: - Model

final class LaunchPreparationModelTests: XCTestCase {
    private var tmp: URL!
    private var harness: Harness!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        harness = Harness(root: tmp)
    }

    override func tearDown() {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    @MainActor
    private func makeModel(request: LaunchRequest,
                           clock: @escaping @Sendable () -> TimeInterval
                            = LaunchPreparationModel.monotonicSeconds,
                           interval: TimeInterval = 0) -> LaunchPreparationModel {
        LaunchPreparationModel(request: request, dependencies: harness.dependencies(),
                               throttleInterval: interval, clock: clock)
    }

    @MainActor
    private func settle(_ model: LaunchPreparationModel,
                        until predicate: @escaping (LaunchPreparationState) -> Bool) async {
        for _ in 0..<4000 {
            if predicate(model.state) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor
    func testRunPublishesReady() async throws {
        let model = makeModel(request: .legacy(rom: makeRom(), core: legacyCore))
        model.run()
        await settle(model) { if case .ready = $0 { return true }; return false }
        guard case let .ready(launch) = model.state else { return XCTFail("not ready") }
        XCTAssertEqual(launch.entryURL, harness.downloadedURL)
        XCTAssertEqual(model.attempt, 1)
    }

    @MainActor
    func testRunIsIdempotentForAReappearingScreen() async throws {
        let model = makeModel(request: .legacy(rom: makeRom(), core: legacyCore))
        model.run()
        model.run()
        model.run()
        await settle(model) { if case .ready = $0 { return true }; return false }
        XCTAssertEqual(model.attempt, 1)
        XCTAssertEqual(harness.log.all, ["legacy-download"])
    }

    /// The stale-completion rule. Attempt 1 ignores cancellation and finishes
    /// with a package of its own; by then the generation has moved on, so it can
    /// neither launch nor overwrite what attempt 2 produces.
    @MainActor
    func testLateCompletionFromAnObsoleteAttemptIsNotPublishedAsReady() async throws {
        let gate = LaunchGate()
        let stale = tmp.appendingPathComponent("stale.m3u")
        let fresh = tmp.appendingPathComponent("fresh.m3u")
        let counter = Counter()
        harness.packageHandler = { _, _ in
            let attempt = counter.next()
            guard attempt == 1 else {
                return PreparedDiscSet(entryURL: fresh, canonicalRomID: 101, discLabels: [])
            }
            gate.enter()
            await gate.waitUntilOpen()   // deliberately not a cancellation point
            return PreparedDiscSet(entryURL: stale, canonicalRomID: 101, discLabels: [])
        }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        var published: [URL] = []
        var transitions: [String] = []
        model.$state.sink { state in
            transitions.append(Self.name(of: state))
            if case let .ready(launch) = state { published.append(launch.entryURL) }
        }.store(in: &cancellables)

        model.run()
        await gate.waitUntilEntered()
        model.retry()
        XCTAssertEqual(model.attempt, 2)
        let afterRetry = transitions.count
        gate.open()

        await settle(model) { if case .ready = $0 { return true }; return false }
        guard case let .ready(launch) = model.state else { return XCTFail("not ready") }
        XCTAssertEqual(launch.entryURL, fresh)
        XCTAssertEqual(published, [fresh], "a superseded attempt published a prepared launch")
        // Nothing the superseded attempt did reaches the screen — not its
        // launch, and not the cancellation or failure it unwinds with. From the
        // retry onward the only transition is attempt 2 becoming ready.
        XCTAssertEqual(Array(transitions.dropFirst(afterRetry)), ["ready"],
                       "a superseded attempt changed the screen: \(transitions)")
    }

    /// The same rule on the resolution path, where a choice is in flight and the
    /// player backs out of the whole screen while it fails.
    @MainActor
    func testALateResolutionFailureFromAnObsoleteAttemptIsNotPublished() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        // Only the first attempt conflicts; the retry finds the cards agreeing,
        // which is what the player's own resolution elsewhere would produce.
        let reconciliations = Counter()
        harness.reconcileResult = {
            reconciliations.next() == 1 ? .conflict(token) : .ready
        }
        let gate = LaunchGate()
        harness.resolveHandler = { _, _ in
            gate.enter()
            await gate.waitUntilOpen()          // deliberately not a cancellation point
            throw PS1SaveSyncError.archiveFailed
        }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        model.run()
        await settle(model) { if case .conflict = $0 { return true }; return false }

        model.resolve(choice: .local)
        await gate.waitUntilEntered()
        var transitions: [String] = []
        model.$state.sink { transitions.append(Self.name(of: $0)) }.store(in: &cancellables)
        model.retry()
        gate.open()

        await settle(model) { if case .ready = $0 { return true }; return false }
        guard case .ready = model.state else { return XCTFail("the retry never completed") }
        // `archiveFailed` from the superseded resolution would have put the
        // chooser back over the live attempt.
        XCTAssertFalse(transitions.contains("conflict"),
                       "a superseded resolution restored the chooser: \(transitions)")
        XCTAssertFalse(transitions.contains("failed"),
                       "a superseded resolution published a failure: \(transitions)")
    }

    private static func name(of state: LaunchPreparationState) -> String {
        switch state {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .conflict: return "conflict"
        case .ready: return "ready"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// A retry does not merely cancel the previous attempt: it waits for it to
    /// return, so the previous staging directory and part file are gone before
    /// the next attempt can create its own.
    @MainActor
    func testRetryWaitsForThePreviousAttemptToFinishUnwinding() async throws {
        let gate = LaunchGate()
        let log = harness.log
        let counter = Counter()
        harness.packageHandler = { _, _ in
            let attempt = counter.next()
            guard attempt == 1 else {
                log.record("second-package-started")
                return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                       discLabels: [])
            }
            gate.enter()
            await gate.waitUntilOpen()
            log.record("first-package-finished")
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: [])
        }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        model.run()
        await gate.waitUntilEntered()
        model.retry()
        // Room for the retry to run. With the wait in place it can get no
        // further than awaiting the previous attempt, which is still gated;
        // without it, it runs its own preparation to completion here.
        await LaunchGate.pause(0.3)
        XCTAssertFalse(log.all.contains("second-package-started"),
                       "the retry started while the previous attempt was still writing")
        gate.open()
        await settle(model) { if case .ready = $0 { return true }; return false }

        let events = log.all.filter {
            $0.hasSuffix("package-finished") || $0.hasSuffix("package-started")
        }
        XCTAssertEqual(events, ["first-package-finished", "second-package-started"])
    }

    @MainActor
    func testCancelWaitsForCleanupAndNeverPublishesReady() async throws {
        let gate = LaunchGate()
        let cleaned = LaunchGate()
        harness.packageHandler = { _, _ in
            gate.enter()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                // Cleanup takes real time on a real filesystem — closing the
                // handle, removing the staging directory and the part file — and
                // it happens *after* cancellation is observed. A `cancel()` that
                // only cancelled without waiting would return before this ran.
                await LaunchGate.pause(0.2)
                cleaned.open()
                throw error
            }
            XCTFail("the package operation was not cancelled")
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: [])
        }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        var sawReady = false
        model.$state.sink { if case .ready = $0 { sawReady = true } }.store(in: &cancellables)

        model.run()
        await gate.waitUntilEntered()
        await model.cancel()

        XCTAssertTrue(cleaned.isOpen, "cancel returned before the attempt had unwound")
        XCTAssertFalse(sawReady)
        guard case .cancelled = model.state else { return XCTFail("expected cancelled") }
    }

    /// A cancellation that a *dependency* reports is still a cancellation, not a
    /// failure. `PS1PackageStore` and `PS1FirmwareManager` both raise
    /// `CancellationError` from their own internals, and
    /// `StreamingFileDownloader` normalizes `URLError.cancelled` into one — none
    /// of which involves this model cancelling anything, so the screen must not
    /// turn into "RommpleTV could not prepare this game".
    @MainActor
    func testACancellationReportedByADependencyIsNotShownAsAFailure() async throws {
        harness.packageHandler = { _, _ in throw CancellationError() }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        var failures = 0
        model.$state.sink { if case .failed = $0 { failures += 1 } }.store(in: &cancellables)

        model.run()
        await settle(model) { if case .cancelled = $0 { return true }; return false }

        guard case .cancelled = model.state else {
            return XCTFail("a reported cancellation became \(model.state)")
        }
        XCTAssertEqual(failures, 0)
    }

    @MainActor
    func testAFailureIsPublishedWithItsRecoveryAndRetrySucceeds() async throws {
        let counter = Counter()
        harness.firmwareHandler = { _, _, _ in
            if counter.next() == 1 {
                throw PS1FirmwareError.fetchFailed(fileName: "scph5501.bin",
                                                   reason: .network(.timedOut))
            }
            return self.harness.systemDirectory
        }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        model.run()
        await settle(model) { if case .failed = $0 { return true }; return false }
        guard case let .failed(failure) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.isRetryable)
        XCTAssertTrue(failure.message.contains("scph5501.bin"))

        model.retry()
        await settle(model) { if case .ready = $0 { return true }; return false }
        guard case .ready = model.state else { return XCTFail("retry did not reach ready") }
    }

    @MainActor
    func testConflictIsPublishedAndBothChoicesReachResolve() async throws {
        for choice in [PS1ConflictChoice.local, .remote] {
            harness = Harness(root: tmp)
            let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
            harness.reconcileResult = { .conflict(token) }
            let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
            model.run()
            await settle(model) { if case .conflict = $0 { return true }; return false }
            guard case let .conflict(published, failure) = model.state else {
                return XCTFail("expected a conflict")
            }
            XCTAssertEqual(published, token)
            XCTAssertNil(failure)

            model.resolve(choice: choice)
            await settle(model) { if case .ready = $0 { return true }; return false }
            guard case .ready = model.state else { return XCTFail("resolve did not reach ready") }
            XCTAssertEqual(harness.resolves.map(\.1), [choice])
        }
    }

    /// A resolution the coordinator says is still resolvable puts the chooser
    /// back with the same token and the reason attached — not a dead end.
    @MainActor
    func testARecoverableResolutionFailureReturnsToTheChooser() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        harness.reconcileResult = { .conflict(token) }
        harness.resolveHandler = { _, _ in throw PS1SaveSyncError.archiveFailed }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        model.run()
        await settle(model) { if case .conflict = $0 { return true }; return false }
        model.resolve(choice: .local)
        await settle(model) {
            if case let .conflict(_, failure) = $0 { return failure != nil }
            return false
        }
        guard case let .conflict(published, failure) = model.state else {
            return XCTFail("expected the chooser back")
        }
        XCTAssertEqual(published, token)
        XCTAssertEqual(failure?.message, PS1SaveSyncError.archiveFailed.errorDescription)
    }

    @MainActor
    func testAnExpiredResolutionBecomesAFailure() async throws {
        let token = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        harness.reconcileResult = { .conflict(token) }
        harness.resolveHandler = { _, _ in throw PS1SaveSyncError.conflictExpired }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        model.run()
        await settle(model) { if case .conflict = $0 { return true }; return false }
        model.resolve(choice: .remote)
        await settle(model) { if case .failed = $0 { return true }; return false }
        guard case .failed = model.state else { return XCTFail("expected a failure") }
    }

    /// The override for a disc set the classifier merged wrongly: a new attempt
    /// for the representative alone, with its own save identity.
    @MainActor
    func testOverrideRestartsWithTheSingleDiscRequest() async throws {
        let game = makeGame(canonicalRomID: 101, discs: [(101, "Disc 1"), (102, "Disc 2")],
                            representativeID: 102)
        let model = makeModel(request: .playStation(game: game, platformID: 35))
        model.run()
        await settle(model) { if case .ready = $0 { return true }; return false }

        model.override(with: .playStation(game: game.singleDiscOverride, platformID: 35))
        await settle(model) { if case .ready = $0 { return true }; return false }

        XCTAssertEqual(harness.packageGames.map(\.canonicalRomID), [101, 102])
        XCTAssertEqual(harness.packageGames.last?.discs.map(\.label), ["Disc 2"])
        XCTAssertEqual(model.attempt, 2)
    }

    // MARK: Throttled progress

    @MainActor
    func testPublishedProgressIsThrottledRatherThanPerChunk() async throws {
        let clock = FakeClock()
        harness.packageHandler = { _, progress in
            for chunk in 1...1000 {
                progress(.downloading(label: "Disc 1", completed: Int64(chunk),
                                      total: 1000))
            }
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: ["Disc 1"])
        }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35),
                              clock: { clock.seconds }, interval: 0.15)
        var snapshots: [LaunchProgressSnapshot] = []
        model.$progress.sink { snapshots.append($0) }.store(in: &cancellables)

        model.run()
        await settle(model) { if case .ready = $0 { return true }; return false }

        let byteUpdates = snapshots.filter { $0.totalBytes == 1000 }
        XCTAssertLessThan(byteUpdates.count, 10,
                          "1000 chunks produced \(byteUpdates.count) main-actor publications")
        XCTAssertGreaterThan(byteUpdates.count, 0)
        XCTAssertEqual(byteUpdates.last?.completedBytes, 1000, "the final position was swallowed")
    }

    @MainActor
    func testPublishedProgressNeverGoesBackwardsWithinAPhase() async throws {
        harness.packageHandler = { _, progress in
            // Out of order on purpose: what the model publishes must still climb.
            for value in [10, 900, 400, 500, 1000] as [Int64] {
                progress(.downloading(label: "Disc 1", completed: value, total: 1000))
            }
            return PreparedDiscSet(entryURL: self.harness.playlistURL, canonicalRomID: 101,
                                   discLabels: ["Disc 1"])
        }
        let model = makeModel(request: .playStation(game: makeGame(), platformID: 35))
        var byteFigures: [Int64] = []
        model.$progress.sink { snapshot in
            if snapshot.totalBytes == 1000 { byteFigures.append(snapshot.completedBytes) }
        }.store(in: &cancellables)

        model.run()
        await settle(model) { if case .ready = $0 { return true }; return false }

        XCTAssertEqual(byteFigures, byteFigures.sorted(), "progress went backwards: \(byteFigures)")
        XCTAssertEqual(byteFigures.last, 1000)
    }
}

// MARK: - Throttle and snapshot

final class LaunchProgressThrottleTests: XCTestCase {

    func testOnlyOneReportPerIntervalIsPublished() {
        let clock = FakeClock()
        let sink = SnapshotSink()
        let throttle = LaunchProgressThrottle(interval: 1, now: { clock.seconds },
                                              publish: { sink.record($0) })
        for chunk in 1...500 {
            throttle.report(.downloading(label: "Disc 1", completed: Int64(chunk), total: 500))
        }
        XCTAssertEqual(sink.count, 1)
        XCTAssertEqual(sink.last?.completedBytes, 1)

        clock.seconds += 1
        throttle.report(.downloading(label: "Disc 1", completed: 500, total: 500))
        XCTAssertEqual(sink.count, 2)
        XCTAssertEqual(sink.last?.completedBytes, 500)
    }

    func testFlushPublishesTheHeldPositionExactlyOnce() {
        let clock = FakeClock()
        let sink = SnapshotSink()
        let throttle = LaunchProgressThrottle(interval: 10, now: { clock.seconds },
                                              publish: { sink.record($0) })
        throttle.report(.downloading(label: "Disc 1", completed: 1, total: 10))
        throttle.report(.downloading(label: "Disc 1", completed: 9, total: 10))
        XCTAssertEqual(sink.count, 1)
        throttle.flush()
        XCTAssertEqual(sink.count, 2)
        XCTAssertEqual(sink.last?.completedBytes, 9)
        throttle.flush()
        XCTAssertEqual(sink.count, 2, "flush published a position that had not changed")
    }

    /// A phase change is the sentence on screen; it is never held back, and it
    /// resets the byte pair because the incoming phase's total describes
    /// different work.
    func testStageChangesPublishImmediatelyAndResetBytes() {
        let clock = FakeClock()
        let sink = SnapshotSink()
        let throttle = LaunchProgressThrottle(interval: 10, now: { clock.seconds },
                                              publish: { sink.record($0) })
        throttle.setStage(.firmware)
        throttle.report(.downloading(label: "scph5501.bin", completed: 512, total: 512))
        throttle.setStage(.discs)

        XCTAssertEqual(sink.snapshots.map(\.stage), [.firmware, .discs])
        XCTAssertEqual(sink.last?.completedBytes, 0)
        XCTAssertEqual(sink.last?.totalBytes, 0)
        XCTAssertEqual(sink.last?.detail, "")
    }

    func testRepeatingTheCurrentStagePublishesNothing() {
        let sink = SnapshotSink()
        let throttle = LaunchProgressThrottle(interval: 10, now: { 0 },
                                              publish: { sink.record($0) })
        throttle.setStage(.discs)
        throttle.setStage(.discs)
        throttle.setStage(.discs)
        XCTAssertEqual(sink.count, 1)
    }

    func testMergeKeepsBytesMonotonicWithinAPhaseAndResetsAcrossOne() {
        let current = LaunchProgressSnapshot(stage: .discs, detail: "Disc 1",
                                             completedBytes: 900, totalBytes: 1000)
        let backwards = LaunchProgressSnapshot(stage: .discs, detail: "Disc 1",
                                               completedBytes: 400, totalBytes: 1000)
        XCTAssertEqual(LaunchProgressSnapshot.merged(backwards, into: current).completedBytes, 900)

        let nextPhase = LaunchProgressSnapshot(stage: .validating, detail: "Disc 1",
                                               completedBytes: 0, totalBytes: 0)
        XCTAssertEqual(LaunchProgressSnapshot.merged(nextPhase, into: current), nextPhase)

        let newTotal = LaunchProgressSnapshot(stage: .discs, detail: "Disc 1",
                                              completedBytes: 5, totalBytes: 2000)
        XCTAssertEqual(LaunchProgressSnapshot.merged(newTotal, into: current), newTotal)
    }

    func testHeadlineNamesTheDiscAndFractionIsBounded() {
        let disc = LaunchProgressSnapshot(stage: .discs, detail: "Disc 2",
                                          completedBytes: 3, totalBytes: 2)
        XCTAssertEqual(disc.headline, "Disc 2")
        XCTAssertEqual(disc.fraction, 1)
        let bios = LaunchProgressSnapshot(stage: .firmware, detail: "scph5501.bin",
                                          completedBytes: 0, totalBytes: 0)
        XCTAssertEqual(bios.headline, "BIOS")
        XCTAssertNil(bios.fraction)
        XCTAssertEqual(LaunchStage.checkingCache.title, "Checking cache")
        XCTAssertEqual(LaunchStage.preparingSave.title, "Preparing save")
        XCTAssertEqual(LaunchStage.validating.title, "Validating")
    }

    /// A disc phase with no label yet must not present an empty headline.
    func testDiscHeadlineFallsBackToTheStageTitleWithoutALabel() {
        let disc = LaunchProgressSnapshot(stage: .discs, detail: "",
                                          completedBytes: 0, totalBytes: 0)
        XCTAssertEqual(disc.headline, "Discs")
    }
}

// MARK: - Failure presentation

final class LaunchFailurePresenterTests: XCTestCase {

    /// The carry-forward: `PS1FirmwareError.recoverySuggestion` says "check your
    /// connection" for every `fetchFailed`, which is wrong for its integrity
    /// sub-cases. The screen branches on the reason.
    func testFirmwareFetchRecoveryBranchesOnTheReason() {
        let network = LaunchFailurePresenter.describe(
            PS1FirmwareError.fetchFailed(fileName: "scph5501.bin",
                                         reason: .network(.notConnectedToInternet)))
        XCTAssertEqual(network.recovery, LaunchFailurePresenter.offlineRecovery)

        let integrity = LaunchFailurePresenter.describe(
            PS1FirmwareError.fetchFailed(fileName: "scph5501.bin",
                                         reason: .integrity(.digestMismatch(.md5,
                                                                            expected: "a",
                                                                            actual: "b"))))
        XCTAssertNotEqual(integrity.recovery, LaunchFailurePresenter.offlineRecovery)
        XCTAssertTrue(integrity.recovery?.contains("scph5501.bin") == true)
        XCTAssertTrue(integrity.recovery?.contains("verified copy") == true)
    }

    /// Not every `.network` is a connectivity failure. A `badServerResponse` is a
    /// reachable server behaving badly, and sending that player to check their
    /// router is the same class of wrong advice as the integrity case.
    func testAReachableServerFailureDoesNotAdviseCheckingTheNetwork() {
        let failure = LaunchFailurePresenter.describe(
            PS1FirmwareError.fetchFailed(fileName: "scph5501.bin",
                                         reason: .network(.badServerResponse)))
        XCTAssertNotEqual(failure.recovery, LaunchFailurePresenter.offlineRecovery)
        XCTAssertTrue(failure.recovery?.contains("RomM server") == true)
        XCTAssertTrue(failure.recovery?.contains("scph5501.bin") == true)
        XCTAssertTrue(failure.isRetryable)
    }

    func testMissingFirmwareNamesEveryFileTheServerCannotSupply() {
        let failure = LaunchFailurePresenter.describe(PS1FirmwareError.firmwareUnavailable([
            .init(fileName: "scph5500.bin", rejection: .notOnServer),
            .init(fileName: "scph5502.bin", rejection: .unverified),
        ]))
        XCTAssertTrue(failure.message.contains("scph5500.bin"))
        XCTAssertTrue(failure.message.contains("scph5502.bin"))
        XCTAssertTrue(failure.recovery?.contains("scph5500.bin") == true)
        XCTAssertTrue(failure.isRetryable)
    }

    /// The other half of the carry-forward: a firmware *list*-stage failure never
    /// becomes a `PS1FirmwareError` at all, so classification has to cover the
    /// untyped shape too.
    func testUntypedListStageConnectivityIsStillClassifiedAsOffline() {
        XCTAssertTrue(LaunchFailurePresenter.isConnectivityFailure(
            URLError(.notConnectedToInternet)))
        XCTAssertTrue(LaunchFailurePresenter.isConnectivityFailure(URLError(.timedOut)))
        XCTAssertFalse(LaunchFailurePresenter.isConnectivityFailure(URLError(.cancelled)))
        XCTAssertFalse(LaunchFailurePresenter.isConnectivityFailure(RommError.http(500)))

        let failure = LaunchFailurePresenter.describe(URLError(.cannotFindHost))
        XCTAssertEqual(failure.message, LaunchFailurePresenter.offlineMessage)
        XCTAssertTrue(failure.isRetryable)
    }

    func testTypedFirmwareConnectivityIsClassifiedThroughItsOwnRule() {
        let typed = PS1FirmwareError.fetchFailed(fileName: "scph5501.bin",
                                                 reason: .network(.timedOut))
        XCTAssertTrue(LaunchFailurePresenter.isConnectivityFailure(typed))
        // A 401 arrives as an integrity failure, never as connectivity — telling a
        // player with an expired token to check their router is the failure mode
        // this rule exists to prevent.
        let unauthorized = PS1FirmwareError.fetchFailed(
            fileName: "scph5501.bin", reason: .integrity(.httpStatus(401)))
        XCTAssertFalse(LaunchFailurePresenter.isConnectivityFailure(unauthorized))
    }

    /// `reconcileBeforeLaunch` rethrows `RommError.http(…)` and decode failures
    /// verbatim; neither conforms to `LocalizedError`, so neither may reach the
    /// screen through `localizedDescription`.
    func testServerAndDecodeErrorsGetWrittenSentences() {
        let unauthorized = LaunchFailurePresenter.describe(RommError.http(401))
        XCTAssertFalse(unauthorized.message.contains("error 1"))
        XCTAssertFalse(unauthorized.message.contains("couldn't be completed"))
        XCTAssertTrue(unauthorized.message.contains("token"))
        XCTAssertFalse(unauthorized.isRetryable)

        XCTAssertEqual(LaunchFailurePresenter.describe(RommError.http(401)).message,
                       LaunchFailurePresenter.describe(RommError.http(403)).message)
        XCTAssertTrue(LaunchFailurePresenter.describe(RommError.http(404)).isRetryable)
        XCTAssertTrue(LaunchFailurePresenter.describe(RommError.http(503)).message.contains("503"))
        XCTAssertFalse(LaunchFailurePresenter.describe(RommError.badResponse).message.isEmpty)

        let decode = LaunchFailurePresenter.describe(
            DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "no value for \"playlist\"")))
        XCTAssertFalse(decode.message.contains("playlist"))
        XCTAssertTrue(decode.message.contains("could not read"))
    }

    /// Nothing rendered on screen carries the player's server address, and the
    /// numeric code is what a `URLError` is allowed to contribute.
    func testANetworkFailureNeverRendersTheServerAddress() {
        let error = URLError(.badServerResponse,
                             userInfo: [NSURLErrorFailingURLStringErrorKey:
                                            "https://private.invalid/api/roms/1"])
        let failure = LaunchFailurePresenter.describe(error)
        XCTAssertFalse(failure.message.contains("private.invalid"))
        XCTAssertFalse(failure.recovery?.contains("private.invalid") == true)
        XCTAssertTrue(failure.message.contains("\(URLError.Code.badServerResponse.rawValue)"))
    }

    func testPackageShapeRefusalsAreNotRetryableAndTransientOnesAre() {
        XCTAssertFalse(LaunchFailurePresenter.describe(
            PS1PackageError.multipleLaunchFiles(label: "Disc 1",
                                                names: ["a.cue", "b.cue"])).isRetryable)
        XCTAssertFalse(LaunchFailurePresenter.describe(
            PS1PackageError.remoteFileNameIsAPath("../x.bin")).isRetryable)
        XCTAssertTrue(LaunchFailurePresenter.describe(
            PS1PackageError.insufficientCapacity(required: 10, available: 1)).isRetryable)
        XCTAssertTrue(LaunchFailurePresenter.describe(
            PS1PackageError.stagedFileMissing("disc-01/track01.bin")).isRetryable)

        let capacity = LaunchFailurePresenter.describe(
            PS1PackageError.insufficientCapacity(required: 12345, available: 99))
        XCTAssertTrue(capacity.message.contains("12345"))
        XCTAssertTrue(capacity.message.contains("99"))
    }

    func testSaveSyncFailuresKeepTheirOwnSentences() {
        let failure = LaunchFailurePresenter.describe(
            PS1SaveSyncError.serverUnreachableWithMissingCard)
        XCTAssertEqual(failure.message,
                       PS1SaveSyncError.serverUnreachableWithMissingCard.errorDescription)
        XCTAssertEqual(failure.recovery,
                       PS1SaveSyncError.serverUnreachableWithMissingCard.recoverySuggestion)
        XCTAssertTrue(failure.isRetryable)
    }

    func testAnUnknownErrorGetsASentenceRatherThanADebugDump() {
        struct Opaque: Error { let secret = "https://private.invalid" }
        let failure = LaunchFailurePresenter.describe(Opaque())
        XCTAssertEqual(failure.message, LaunchFailurePresenter.genericMessage)
        XCTAssertNil(failure.recovery)
    }
}

// MARK: - Single-disc override

final class SingleDiscOverrideTests: XCTestCase {

    func testOverrideKeepsTheRepresentativeAsItsOwnGame() {
        let representative = Rom(id: 202, name: "Invented Demo Disc 2",
                                 fsName: "Invented Demo (USA) (Disc 2).cue", platformId: 35,
                                 sizeBytes: nil, coverPath: nil, siblingRoms: [], regions: ["USA"],
                                 fsNameNoExt: "Invented Demo (USA) (Disc 2)")
        let merged = PS1Game(
            representative: representative,
            canonicalRomID: 201,
            discs: [PS1Disc(romID: 201, fileStem: "Invented Demo (USA) (Disc 1)",
                            index: 1, label: "Disc 1"),
                    PS1Disc(romID: 202, fileStem: "Invented Demo (USA) (Disc 2)",
                            index: 2, label: "Disc 2")],
            excludedSiblings: [])

        let override = merged.singleDiscOverride

        XCTAssertEqual(override.canonicalRomID, 202)
        XCTAssertEqual(override.discs.count, 1)
        XCTAssertEqual(override.discs[0].romID, 202)
        XCTAssertEqual(override.discs[0].index, 1)
        XCTAssertEqual(override.discs[0].label, "Disc 2")
        XCTAssertEqual(override.discs[0].fileStem, "Invented Demo (USA) (Disc 2)")
        XCTAssertEqual(override.representative.id, 202)
    }

    func testOverrideOfASingleDiscGameIsItself() {
        let rom = Rom(id: 303, name: nil, fsName: "Invented Solo (USA).cue", platformId: 35,
                      sizeBytes: nil, coverPath: nil, siblingRoms: [], regions: [],
                      fsNameNoExt: "Invented Solo (USA)")
        let game = PS1GameClassifier.classify(rom)
        let override = game.singleDiscOverride
        XCTAssertEqual(override.canonicalRomID, game.canonicalRomID)
        XCTAssertEqual(override.discs.map(\.label), game.discs.map(\.label))
    }
}

// MARK: - Live wiring details

final class LaunchPreparationLiveWiringTests: XCTestCase {

    /// Every prepared package's playlist is `game.m3u`, and Beetle PSX names its
    /// memory card after the loaded content — so one shared save directory would
    /// give every PlayStation game the same card.
    func testPlayStationSaveDirectoriesAreDistinctPerGame() {
        let root = URL(fileURLWithPath: "/tmp/caches")
        let first = LaunchPreparationDependencies.playStationSaveDirectory(cachesRoot: root,
                                                                           canonicalRomID: 1)
        let second = LaunchPreparationDependencies.playStationSaveDirectory(cachesRoot: root,
                                                                            canonicalRomID: 2)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.path.hasSuffix("/ps1/saves/1"))
        XCTAssertTrue(second.path.hasSuffix("/ps1/saves/2"))
    }
}

// MARK: - Small helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); value += 1; let result = value; lock.unlock(); return result }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval = 0
    var seconds: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class SnapshotSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LaunchProgressSnapshot] = []
    func record(_ snapshot: LaunchProgressSnapshot) {
        lock.lock(); storage.append(snapshot); lock.unlock()
    }
    var snapshots: [LaunchProgressSnapshot] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
    var count: Int { snapshots.count }
    var last: LaunchProgressSnapshot? { snapshots.last }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LaunchStage] = []
    func record(_ stage: LaunchStage) {
        lock.lock()
        if storage.last != stage { storage.append(stage) }
        lock.unlock()
    }
    /// Consecutive repeats collapsed, which is what a stage channel means.
    var distinct: [LaunchStage] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PS1PreparationProgress] = []
    func record(_ value: PS1PreparationProgress) {
        lock.lock(); storage.append(value); lock.unlock()
    }
    var all: [PS1PreparationProgress] { lock.lock(); defer { lock.unlock() }; return storage }
    var downloads: [(label: String, completed: Int64, total: Int64)] {
        all.compactMap {
            guard case let .downloading(label, completed, total) = $0 else { return nil }
            return (label, completed, total)
        }
    }
}

/// One synthetic disc: a cue and one track, generated bytes, digests computed by
/// the same code the store checks them with.
private final class MiniLibrary: @unchecked Sendable {
    let details: RomDetails
    private let contents: [Int: Data]

    init(romID: Int) {
        let trackBytes = Data(repeating: 0x5A, count: 4096)
        let cueText = "FILE \"track01.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
        let cueBytes = Data(cueText.utf8)
        let track = Self.file(id: 9001, name: "track01.bin", path: "Invented Offline",
                              data: trackBytes)
        let cue = Self.file(id: 9002, name: "game.cue", path: "Invented Offline", data: cueBytes)
        details = RomDetails(id: romID, fsName: "Invented Offline", files: [track, cue])
        contents = [9001: trackBytes, 9002: cueBytes]
    }

    func request(fileID: Int) -> URLRequest {
        URLRequest(url: URL(string: "https://library.invalid/files/\(fileID)")!)
    }

    var transfer: PS1FileTransfer {
        { [contents] request, partURL, expected, progress in
            let id = Int(request.url?.lastPathComponent ?? "") ?? -1
            guard let data = contents[id] else { throw RommError.http(404) }
            try data.write(to: partURL)
            var digest = IncrementalFileDigest()
            digest.update(data)
            let result = digest.finalized()
            progress(result.size)
            try expected.verify(result)
            return result
        }
    }

    private static func file(id: Int, name: String, path: String, data: Data) -> RomFile {
        var digest = IncrementalFileDigest()
        digest.update(data)
        let computed = digest.finalized()
        return RomFile(id: id, fileName: name, filePath: path, sizeBytes: Int64(data.count),
                       isTopLevel: true, crcHash: computed.crc32, md5Hash: computed.md5,
                       sha1Hash: computed.sha1, updatedAt: "2026-01-01T00:00:00")
    }
}

/// A BIOS catalogue over a few hundred synthetic bytes. The shipped catalogue's
/// MD5s cannot be satisfied without a real BIOS image, which this repository
/// never contains.
private struct MiniCatalog {
    let catalog: PS1BIOSCatalog
    let bytes: Data

    static func make() -> MiniCatalog {
        let bytes = Data(repeating: 0x7E, count: 256)
        var digest = IncrementalFileDigest()
        digest.update(bytes)
        let md5 = digest.finalized().md5
        return MiniCatalog(
            catalog: PS1BIOSCatalog(
                byteCount: 256,
                japan: .init(fileName: "scph5500.bin", md5: md5),
                usa: .init(fileName: "scph5501.bin", md5: md5),
                europe: .init(fileName: "scph5502.bin", md5: md5),
                excludedFileNames: []),
            bytes: bytes)
    }

    func install(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in catalog.allEntries {
            try bytes.write(to: directory.appendingPathComponent(entry.fileName))
        }
    }
}

import XCTest
@testable import RommpleTVKit

// MARK: - Doubles

/// A card store whose failures are chosen rather than provoked, so "unreadable"
/// and "not there" can be told apart in a test the way `PS1SaveCoordinator` has to
/// tell them apart in the field.
final class FakeCardStore: SaveRAMStoring, SaveRAMModificationDating, @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [Int: Data] = [:]
    private var dates: [Int: Date] = [:]
    private var _loadError: Error?
    private var _saveError: Error?
    private var _saveCount = 0
    private var _loadCount = 0

    init(cards: [Int: Data] = [:]) { self.cards = cards }

    var loadError: Error? {
        get { lock.withLock { _loadError } }
        set { lock.withLock { _loadError = newValue } }
    }
    var saveError: Error? {
        get { lock.withLock { _saveError } }
        set { lock.withLock { _saveError = newValue } }
    }
    var saveCount: Int { lock.withLock { _saveCount } }
    var loadCount: Int { lock.withLock { _loadCount } }

    func card(_ romID: Int) -> Data? { lock.withLock { cards[romID] } }
    func put(_ data: Data?, romID: Int) {
        lock.withLock { cards[romID] = data; dates[romID] = Date() }
    }

    func load(romID: Int) throws -> Data? {
        try lock.withLock {
            _loadCount += 1
            if let _loadError { throw _loadError }
            return cards[romID]
        }
    }

    func save(_ data: Data, romID: Int) throws {
        try lock.withLock {
            if let _saveError { throw _saveError }
            _saveCount += 1
            cards[romID] = data
            dates[romID] = Date()
        }
    }

    func modificationDate(romID: Int) -> Date? { lock.withLock { dates[romID] } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

/// An async gate the test opens by hand, so debounce and in-flight-upload
/// behaviour is exercised without a single real delay.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private var arrivals = 0
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { $0.0 <= arrivals }
        arrivalWaiters.removeAll { $0.0 <= arrivals }
        ready.forEach { $0.1.resume() }
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func arrivalCount() -> Int { arrivals }

    /// Suspends until at least `count` callers have reached `wait()`.
    func untilArrivals(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }
}

/// A RomM that records what was asked of it. Slot uploads append, exactly as the
/// real server does: the filename is stamped and a new row is inserted.
///
/// A lock rather than an actor, so assertions about what it was asked can be
/// written inside `XCTAssert…`, which cannot await.
final class FakeRomM: @unchecked Sendable {
    private let lock = NSLock()
    private var _saves: [RommSave] = []
    private var _blobs: [Int: Data] = [:]
    private var _devices: [RommDevice] = []
    private var _uploads: [PS1SaveUploadRequest] = []
    private var _downloads: [(id: Int, deviceID: String?)] = []
    private var _listCalls = 0
    private var _deviceListCalls = 0
    private var _registrations: [String] = []
    private var _createErrors: [Error?] = []
    private var _nextSaveID = 500

    var listError: Error? {
        get { lock.withLock { _listError } }
        set { lock.withLock { _listError = newValue } }
    }
    var downloadError: Error? {
        get { lock.withLock { _downloadError } }
        set { lock.withLock { _downloadError = newValue } }
    }
    var deviceListError: Error? {
        get { lock.withLock { _deviceListError } }
        set { lock.withLock { _deviceListError = newValue } }
    }
    var registerError: Error? {
        get { lock.withLock { _registerError } }
        set { lock.withLock { _registerError = newValue } }
    }
    var createGate: Gate? {
        get { lock.withLock { _createGate } }
        set { lock.withLock { _createGate = newValue } }
    }
    var downloadGate: Gate? {
        get { lock.withLock { _downloadGate } }
        set { lock.withLock { _downloadGate = newValue } }
    }
    private var _listError: Error?
    private var _downloadError: Error?
    private var _deviceListError: Error?
    private var _registerError: Error?
    private var _createGate: Gate?
    private var _downloadGate: Gate?

    var saves: [RommSave] { lock.withLock { _saves } }
    var blobs: [Int: Data] { lock.withLock { _blobs } }
    var devices: [RommDevice] {
        get { lock.withLock { _devices } }
        set { lock.withLock { _devices = newValue } }
    }
    var uploads: [PS1SaveUploadRequest] { lock.withLock { _uploads } }
    var downloads: [(id: Int, deviceID: String?)] { lock.withLock { _downloads } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var deviceListCalls: Int { lock.withLock { _deviceListCalls } }
    var registrations: [String] { lock.withLock { _registrations } }
    var uploadCount: Int { uploads.count }
    var activeUploads: [PS1SaveUploadRequest] {
        uploads.filter { $0.slot == PS1SaveCoordinator.activeSlot }
    }
    var archiveUploads: [PS1SaveUploadRequest] {
        uploads.filter { $0.slot != PS1SaveCoordinator.activeSlot }
    }

    /// Consumed one per create; `nil` entries succeed. Runs out into success.
    func setCreateErrors(_ errors: [Error?]) { lock.withLock { _createErrors = errors } }

    func seed(_ record: RommSave, bytes: Data?) {
        lock.withLock {
            _saves.append(record)
            if let bytes { _blobs[record.id] = bytes }
        }
    }

    func list(_ romID: Int) throws -> [RommSave] {
        try lock.withLock {
            _listCalls += 1
            if let _listError { throw _listError }
            return _saves.filter { $0.romID == romID }
        }
    }

    func removeSave(_ id: Int) {
        lock.withLock {
            _saves.removeAll { $0.id == id }
            _blobs[id] = nil
        }
    }

    func download(_ id: Int, deviceID: String?) async throws -> Data {
        if let gate = downloadGate { await gate.wait() }
        return try lock.withLock {
            _downloads.append((id, deviceID))
            if let _downloadError { throw _downloadError }
            guard let blob = _blobs[id] else { throw RommError.http(404) }
            return blob
        }
    }

    func create(_ request: PS1SaveUploadRequest) async throws -> RommSave {
        if let gate = createGate { await gate.wait() }
        return try lock.withLock {
            _uploads.append(request)
            if !_createErrors.isEmpty, let error = _createErrors.removeFirst() { throw error }
            // Content-hash dedup, slot-scoped, exactly like RomM: an identical
            // byte sequence already in this slot returns that row and writes
            // nothing.
            if let existing = _saves.first(where: {
                $0.slot == request.slot && _blobs[$0.id] == request.data
            }) {
                return existing
            }
            _nextSaveID = max(_nextSaveID, _saves.map(\.id).max() ?? 0) + 1
            let stamp = String(format: "2026-03-01_12-00-%02d", _nextSaveID % 60)
            let record = RommSave(
                id: _nextSaveID, romID: request.romID,
                fileName: "RommpleTV Memory Card [\(stamp)].mcr",
                fileSizeBytes: Int64(request.data.count),
                createdAt: "2026-03-01T12:00:00", updatedAt: "2026-03-01T12:00:00",
                emulator: request.emulator, slot: request.slot, contentHash: nil,
                originDeviceID: request.deviceID)
            _saves.append(record)
            _blobs[record.id] = request.data
            return record
        }
    }

    func listDevices() throws -> [RommDevice] {
        try lock.withLock {
            _deviceListCalls += 1
            if let _deviceListError { throw _deviceListError }
            return _devices
        }
    }

    func register(_ hostname: String) throws -> String {
        try lock.withLock {
            _registrations.append(hostname)
            if let _registerError { throw _registerError }
            let device = RommDevice(id: "device-\(_registrations.count)", name: "RommpleTV",
                                    platform: "tvOS", hostname: hostname)
            _devices.append(device)
            return device.id
        }
    }
}

// MARK: - Tests

final class PS1SaveCoordinatorTests: XCTestCase {
    let romID = 8343
    var suiteName: String!
    var defaults: UserDefaults!
    var store: FakeCardStore!
    var server: FakeRomM!

    override func setUpWithError() throws {
        suiteName = "PS1SaveCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = FakeCardStore()
        server = FakeRomM()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Fixtures

    let cardA = Data((0..<131_072).map { UInt8($0 % 251) })
    let cardB = Data((0..<131_072).map { UInt8(($0 &* 7) % 251) })
    let cardC = Data(repeating: 0xAB, count: 131_072)
    let cardD = Data((0..<131_072).map { UInt8(($0 &* 13 &+ 5) % 251) })

    func hash(_ data: Data) -> String { PS1SaveCoordinator.sha256(data) }

    /// The filename RomM actually stores for a slotted upload.
    func storedName(_ stamp: String = "2026-03-01_10-00-00") -> String {
        "RommpleTV Memory Card [\(stamp)].mcr"
    }

    func record(id: Int, updatedAt: String = "2026-03-01T10:00:00",
                slot: String? = "0", fileName: String? = nil,
                emulator: String? = "mednafen_psx", originDeviceID: String? = "device-1",
                missingFromFS: Bool = false, romID: Int? = nil) -> RommSave {
        RommSave(id: id, romID: romID ?? self.romID,
                 fileName: fileName ?? storedName(), fileSizeBytes: 131_072,
                 missingFromFS: missingFromFS, createdAt: updatedAt, updatedAt: updatedAt,
                 emulator: emulator, slot: slot, contentHash: nil,
                 originDeviceID: originDeviceID)
    }

    func seams(now: Date = Date(timeIntervalSince1970: 1_772_000_000),
               suffix: String = "aaaa",
               installIdentifier: String = "00000000-1111-2222-3333-444444444444",
               sleepGate: Gate? = nil) -> PS1SaveSeams {
        let server = self.server!
        return PS1SaveSeams(
            listSaves: { try server.list($0) },
            downloadSave: { try await server.download($0, deviceID: $1) },
            createSave: { try await server.create($0) },
            listDevices: { try server.listDevices() },
            registerDevice: { try server.register($0) },
            now: { now },
            uniqueSuffix: { suffix },
            makeInstallIdentifier: { installIdentifier },
            sleep: { _ in
                if let sleepGate { await sleepGate.wait() } else { await Task.yield() }
            },
            isConnectivityError: { PS1PackageStore.isLikelyConnectivityError($0) })
    }

    func makeCoordinator(_ seams: PS1SaveSeams? = nil) -> PS1SaveCoordinator {
        PS1SaveCoordinator(canonicalRomID: romID, localStore: store,
                           defaults: defaults, seams: seams ?? self.seams())
    }

    /// What `body` published, in order.
    ///
    /// The stream buffers from the moment the coordinator was built, so the
    /// consumer is first allowed to catch up and everything it had already seen is
    /// dropped. Both waits are against `publishedCount` — the number of statuses
    /// the coordinator actually yielded — rather than against a number of yields
    /// or a sleep, so this cannot decide "nothing more is coming" while the
    /// consumer simply has not been scheduled yet.
    func drain(_ coordinator: PS1SaveCoordinator, _ body: () async throws -> Void) async rethrows
    -> [PS1SaveSyncStatus] {
        let collector = StatusCollector()
        let stream = coordinator.statuses
        let task = Task { for await status in stream { await collector.append(status) } }
        let before = await coordinator.publishedCount
        await receive(before, into: collector)
        try await body()
        let after = await coordinator.publishedCount
        await receive(after, into: collector)
        task.cancel()
        return Array(await collector.all().dropFirst(before))
    }

    private func receive(_ count: Int, into collector: StatusCollector) async {
        while await collector.count() < count { await Task.yield() }
    }

    actor StatusCollector {
        private var seen: [PS1SaveSyncStatus] = []
        func append(_ status: PS1SaveSyncStatus) { seen.append(status) }
        func all() -> [PS1SaveSyncStatus] { seen }
        func count() -> Int { seen.count }
    }

    func offline() -> URLError { URLError(.notConnectedToInternet) }

    /// Puts a baseline on disk the way a previous successful sync would have.
    func seedBaseline(hash: String, remoteID: Int) {
        defaults.set(hash, forKey: "ps1sync.rom.\(romID).baselineHash")
        defaults.set(remoteID, forKey: "ps1sync.rom.\(romID).baselineRemoteID")
    }

    var storedBaselineHash: String? {
        defaults.string(forKey: "ps1sync.rom.\(romID).baselineHash")
    }
    var storedBaselineRemoteID: Int? {
        defaults.object(forKey: "ps1sync.rom.\(romID).baselineRemoteID") as? Int
    }
    var storedPending: Bool { defaults.bool(forKey: "ps1sync.rom.\(romID).pending") }

    // MARK: - Device identity

    func testStableInstallIdentifierPersistsAcrossCoordinatorInstances() async throws {
        let first = await makeCoordinator().installIdentifier
        XCTAssertTrue(first.hasPrefix("rommpletv-"))
        // A different generator on the second instance proves the value came from
        // storage rather than being regenerated to the same thing.
        let second = makeCoordinator(seams(installIdentifier: "a-completely-different-uuid"))
        await XCTAssertEqualAsync(await second.installIdentifier, first)
    }

    func testRegistrationRecoversAnExistingDeviceByHostname() async throws {
        let identifier = "rommpletv-00000000-1111-2222-3333-444444444444"
        server.devices = ([
            RommDevice(id: "someone-else", hostname: "other-box"),
            RommDevice(id: "ours", hostname: identifier),
        ])
        let coordinator = makeCoordinator()
        _ = try await coordinator.reconcileBeforeLaunch()

        await XCTAssertEqualAsync(await coordinator.deviceID, "ours")
        let registrations = server.registrations
        XCTAssertTrue(registrations.isEmpty, "a device already on file must not be registered again")
        await XCTAssertFalseAsync(await coordinator.deviceRegistrationDidFail)
    }

    func testRegistrationCreatesADeviceWhenTheHostnameIsUnknown() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.reconcileBeforeLaunch()
        let registrations = server.registrations
        XCTAssertEqual(registrations,
                       ["rommpletv-00000000-1111-2222-3333-444444444444"])
        await XCTAssertEqualAsync(await coordinator.deviceID, "device-1")
        XCTAssertEqual(server.deviceListCalls, 1)
    }

    /// Registration failure must not stop anybody playing, and must not be
    /// silent: losing it turns off both of the server's conflict branches.
    func testRegistrationFailureIsRecordedAndNonFatal() async throws {
        server.deviceListError = (RommError.http(403))
        store.put(cardA, romID: romID)

        let coordinator = makeCoordinator()
        let decision = try await coordinator.reconcileBeforeLaunch()

        XCTAssertEqual(decision, .ready)
        await XCTAssertTrueAsync(await coordinator.deviceRegistrationDidFail)
        await XCTAssertNilAsync(await coordinator.deviceID)
        // The card still went up — anonymously, which is the documented downgrade.
        let uploads = server.activeUploads
        guard uploads.count == 1 else { return XCTFail("expected one upload, got \(uploads.count)") }
        XCTAssertNil(uploads[0].deviceID)
    }

    /// Every download identifies this device, because that is the only thing that
    /// tells RomM this device holds the newest save in the slot — without it the
    /// slot's 409 branch fires on the very next upload.
    func testDownloadsCarryTheDeviceIDSoTheServerRecordsTheSync() async throws {
        server.seed(record(id: 700), bytes: cardA)
        let coordinator = makeCoordinator()
        _ = try await coordinator.reconcileBeforeLaunch()

        let downloads = server.downloads
        guard downloads.count == 1 else { return XCTFail("expected one download") }
        XCTAssertEqual(downloads[0].id, 700)
        XCTAssertEqual(downloads[0].deviceID, "device-1")
    }

    // MARK: - Decision table, no baseline

    func testNoLocalAndNoRemoteStartsEmpty() async throws {
        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        }
        XCTAssertNil(store.card(romID))
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertNil(storedBaselineHash)
        XCTAssertFalse(storedPending)
        XCTAssertEqual(statuses, [.idle])
    }

    func testRemoteOnlyIsDownloadedAndWrittenLocally() async throws {
        server.seed(record(id: 700), bytes: cardA)
        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)

        XCTAssertEqual(store.card(romID), cardA)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(server.uploadCount, 0, "installing the server's card writes nothing back")
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertEqual(storedBaselineRemoteID, 700)
        XCTAssertFalse(storedPending)
    }

    func testLocalOnlyLaunchesAndUploads() async throws {
        store.put(cardA, romID: romID)
        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        }
        let uploads = server.activeUploads
        guard uploads.count == 1 else { return XCTFail("expected one upload, got \(uploads.count)") }
        XCTAssertEqual(uploads[0].data, cardA)
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertFalse(storedPending)
        XCTAssertEqual(statuses, [.pending, .syncing, .synced])
    }

    func testLocalOnlyStaysPendingUntilTheUploadSucceeds() async throws {
        store.put(cardA, romID: romID)
        server.setCreateErrors([RommError.http(500)])
        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        }
        XCTAssertTrue(storedPending)
        XCTAssertNil(storedBaselineHash, "a refused upload records no baseline")
        XCTAssertEqual(store.card(romID), cardA)
        XCTAssertEqual(statuses, [.pending, .syncing, .failed])
    }

    func testEqualBytesLaunchImmediatelyWithNoWriteAndEstablishTheBaseline() async throws {
        store.put(cardA, romID: romID)
        server.seed(record(id: 700), bytes: cardA)
        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        }
        XCTAssertEqual(store.saveCount, 0, "equal cards must not be rewritten locally")
        XCTAssertEqual(server.uploadCount, 0, "equal cards must not be re-uploaded")
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertEqual(storedBaselineRemoteID, 700)
        XCTAssertEqual(statuses, [.synced])
    }

    func testDifferentBytesWithNoBaselineIsAConflict() async throws {
        store.put(cardA, romID: romID)
        server.seed(record(id: 700), bytes: cardB)
        let coordinator = makeCoordinator()
        guard case .conflict = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("two unexplained cards must not be resolved automatically")
        }
        XCTAssertEqual(store.card(romID), cardA)
        XCTAssertEqual(server.uploadCount, 0)
    }

    // MARK: - Decision table, with a baseline

    func testLocalChangedSinceBaselineUploads() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardA)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)

        let uploads = server.activeUploads
        guard uploads.count == 1 else { return XCTFail("expected one upload, got \(uploads.count)") }
        XCTAssertEqual(uploads[0].data, cardB)
        XCTAssertEqual(storedBaselineHash, hash(cardB))
        XCTAssertEqual(store.saveCount, 0, "the local card was already the winner")
    }

    func testRemoteChangedSinceBaselineReplacesLocalAtomically() async throws {
        store.put(cardA, romID: romID)
        server.seed(record(id: 701), bytes: cardB)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)

        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertEqual(storedBaselineHash, hash(cardB))
        XCTAssertEqual(storedBaselineRemoteID, 701)
    }

    func testBothChangedToDifferentBytesIsAConflictThatOverwritesNeitherSide() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 701), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            guard case .conflict = try await coordinator.reconcileBeforeLaunch() else {
                return XCTFail("divergent cards must reach a person")
            }
        }
        XCTAssertEqual(store.card(romID), cardB, "local bytes survive a conflict untouched")
        XCTAssertEqual(server.blobs[701], cardC, "remote bytes survive a conflict untouched")
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertEqual(storedBaselineHash, hash(cardA), "an unresolved conflict moves no baseline")
        XCTAssertEqual(statuses, [.conflict])
    }

    func testBaselinedMissingLocalWithRemotePresentRestoresRemote() async throws {
        server.seed(record(id: 700), bytes: cardA)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        XCTAssertEqual(store.card(romID), cardA)
    }

    /// "Regardless of whether it changed" — an unchanged remote card is still the
    /// one to restore when this device has none.
    func testBaselinedMissingLocalRestoresAnUnchangedRemoteCard() async throws {
        server.seed(record(id: 701), bytes: cardB)
        seedBaseline(hash: hash(cardB), remoteID: 701)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(server.uploadCount, 0)
    }

    func testBaselinedMissingRemoteWithLocalPresentRecreatesRemote() async throws {
        store.put(cardA, romID: romID)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)

        let uploads = server.activeUploads
        guard uploads.count == 1 else {
            return XCTFail("an unchanged local card is still re-created when the server has none")
        }
        XCTAssertEqual(uploads[0].data, cardA)
        XCTAssertFalse(storedPending)
    }

    func testBaselinedBothMissingClearsTheStaleBaseline() async throws {
        seedBaseline(hash: hash(cardA), remoteID: 700)
        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)

        XCTAssertNil(storedBaselineHash)
        XCTAssertNil(storedBaselineRemoteID)
        XCTAssertNil(store.card(romID))
        XCTAssertEqual(server.uploadCount, 0)
    }

    // MARK: - Connectivity is not absence

    /// The worst outcome available in this file: launching a blank card that the
    /// next sync uploads over a card known to exist.
    func testConnectivityFailureWithABaselinedMissingCardBlocksLaunch() async throws {
        server.listError = (offline())
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        do {
            _ = try await coordinator.reconcileBeforeLaunch()
            XCTFail("a baselined card that is missing locally must not launch blank")
        } catch let error as PS1SaveSyncError {
            XCTAssertEqual(error, .serverUnreachableWithMissingCard)
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }
        XCTAssertNil(store.card(romID))
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertEqual(storedBaselineHash, hash(cardA), "the baseline survives an outage")
    }

    /// The same failure with no baseline is a first launch, and must not be
    /// blocked — there is no card anywhere that a blank one could replace.
    func testConnectivityFailureWithNoBaselineAndNoCardStillLaunches() async throws {
        server.listError = (offline())
        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        XCTAssertFalse(storedPending)
    }

    func testConnectivityFailureWithALocalCardLaunchesOfflineAndPending() async throws {
        server.listError = (offline())
        store.put(cardB, romID: romID)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        }
        XCTAssertTrue(storedPending)
        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(statuses, [.pending])
    }

    func testConnectivityFailureWithAnUnchangedLocalCardLaunchesWithNothingOwed() async throws {
        server.listError = (offline())
        store.put(cardA, romID: romID)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        XCTAssertFalse(storedPending)
    }

    /// A connectivity failure part-way through — the list answered, the download
    /// did not — is still unreachable, not "the server has no card".
    func testConnectivityFailureDuringDownloadIsNotRemoteAbsence() async throws {
        server.seed(record(id: 700), bytes: cardA)
        server.downloadError = (offline())
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        do {
            _ = try await coordinator.reconcileBeforeLaunch()
            XCTFail("expected the missing-card refusal")
        } catch let error as PS1SaveSyncError {
            XCTAssertEqual(error, .serverUnreachableWithMissingCard)
        }
        XCTAssertEqual(server.uploadCount, 0)
    }

    func testHTTPErrorsAreSurfacedRatherThanTreatedAsOffline() async throws {
        server.listError = (RommError.http(401))
        store.put(cardA, romID: romID)

        let coordinator = makeCoordinator()
        do {
            _ = try await coordinator.reconcileBeforeLaunch()
            XCTFail("an authentication failure must not read as an outage")
        } catch let error as RommError {
            XCTAssertEqual(error, .http(401))
        }
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testDecodeErrorsAreSurfacedRatherThanTreatedAsOffline() async throws {
        struct Decode: Error {}
        server.listError = (Decode())
        store.put(cardA, romID: romID)

        let coordinator = makeCoordinator()
        do {
            _ = try await coordinator.reconcileBeforeLaunch()
            XCTFail("a decode failure must not read as an outage")
        } catch is Decode {
            // expected
        }
        XCTAssertEqual(server.uploadCount, 0)
    }

    // MARK: - A local read failure is not absence

    func testLocalReadErrorStopsEverythingAndWritesNeitherSide() async throws {
        store.loadError = CocoaError(.fileReadNoPermission)
        server.seed(record(id: 700), bytes: cardA)
        seedBaseline(hash: hash(cardB), remoteID: 699)

        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            do {
                _ = try await coordinator.reconcileBeforeLaunch()
                XCTFail("an unreadable card must not be treated as a missing one")
            } catch let error as PS1SaveSyncError {
                XCTAssertEqual(error, .localCardUnreadable)
            }
        }
        XCTAssertEqual(store.saveCount, 0, "no local write")
        XCTAssertEqual(server.uploadCount, 0, "no remote write")
        XCTAssertEqual(server.listCalls, 0, "not one request is made")
        XCTAssertEqual(storedBaselineHash, hash(cardB), "the baseline is untouched")
        XCTAssertEqual(statuses, [.failed])
    }

    /// Specifically: it never falls through to the remote-replacement branch that
    /// a genuinely absent card would take.
    func testLocalReadErrorNeverFallsBackToRemoteReplacement() async throws {
        server.seed(record(id: 700), bytes: cardA)
        seedBaseline(hash: hash(cardA), remoteID: 700)
        store.loadError = CocoaError(.fileReadUnknown)

        let coordinator = makeCoordinator()
        _ = try? await coordinator.reconcileBeforeLaunch()
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(store.card(romID))
    }

    // MARK: - Selection

    func testUnrelatedSavesAreNeverSelected() async throws {
        // Everything here is a save the server holds for this ROM and none of it
        // is this client's active memory card.
        server.seed(record(id: 1, slot: "conflict-20260301T100000Z-aaaa"), bytes: cardB)
        server.seed(record(id: 2, slot: "1"), bytes: cardB)
        server.seed(record(id: 3, slot: nil), bytes: cardB)
        server.seed(record(id: 4, fileName: "Some Other Emulator.srm"), bytes: cardB)
        server.seed(record(id: 5, missingFromFS: true), bytes: cardB)
        server.seed(record(id: 6, romID: 9999), bytes: cardB)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        XCTAssertNil(store.card(romID), "nothing on that list is a card to install")
        XCTAssertEqual(server.downloads.count, 0)
    }

    /// The safety-critical half of selection: a card another Apple TV wrote is
    /// exactly the card this one must see. Filtering on `origin_device_id` would
    /// hide it, and a card that cannot be seen cannot be compared or preserved.
    func testACardWrittenByAnotherDeviceIsSelected() async throws {
        server.seed(record(id: 700, originDeviceID: "some-other-apple-tv"), bytes: cardA)
        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        XCTAssertEqual(store.card(romID), cardA)
    }

    func testTheNewestActiveRecordWinsAndTiesBreakOnID() throws {
        let older = record(id: 900, updatedAt: "2026-03-01T10:00:00")
        let newer = record(id: 800, updatedAt: "2026-03-02T10:00:00")
        XCTAssertEqual(
            PS1SaveCoordinator.selectActive(from: [older, newer], romID: romID)?.id, 800)

        let tieLow = record(id: 810, updatedAt: "2026-03-02T10:00:00")
        let tieHigh = record(id: 811, updatedAt: "2026-03-02T10:00:00")
        XCTAssertEqual(
            PS1SaveCoordinator.selectActive(from: [tieHigh, tieLow], romID: romID)?.id, 811)
    }

    /// RomM rewrites a slotted upload's filename with a datetime tag, so an
    /// equality test against the constant would match nothing that was ever
    /// stored — and a filter that matched everything would let some other
    /// client's save be installed as a memory card.
    func testMemoryCardFileNameAcceptsTheServersDatetimeTagAndNothingElse() {
        XCTAssertTrue(PS1SaveCoordinator.isMemoryCardFileName("RommpleTV Memory Card.mcr"))
        XCTAssertTrue(PS1SaveCoordinator.isMemoryCardFileName(
            "RommpleTV Memory Card [2026-03-01_10-00-00].mcr"))
        XCTAssertFalse(PS1SaveCoordinator.isMemoryCardFileName("RommpleTV Memory Card.srm"))
        XCTAssertFalse(PS1SaveCoordinator.isMemoryCardFileName("Something Else.mcr"))
        XCTAssertFalse(PS1SaveCoordinator.isMemoryCardFileName(
            "RommpleTV Memory Card [not-a-timestamp].mcr"))
        XCTAssertFalse(PS1SaveCoordinator.isMemoryCardFileName(
            "Evil RommpleTV Memory Card.mcr"))
    }

    // MARK: - Active identity and archive slots

    func testActiveUploadCarriesTheExactIdentityAndArchivesUseADistinctSlot() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        try await coordinator.resolve(token, choice: .local)

        let active = server.activeUploads
        guard active.count == 1 else { return XCTFail("expected one active upload, got \(active.count)") }
        XCTAssertEqual(active[0].romID, romID)
        XCTAssertEqual(active[0].emulator, "mednafen_psx")
        XCTAssertEqual(active[0].slot, "0")
        XCTAssertEqual(active[0].deviceID, "device-1")
        XCTAssertTrue(active[0].autocleanup)
        XCTAssertEqual(active[0].autocleanupLimit, 10)

        let archives = server.archiveUploads
        guard archives.count == 1 else { return XCTFail("expected one archive, got \(archives.count)") }
        XCTAssertEqual(archives[0].slot, "conflict-20260225T061320Z-aaaa")
        XCTAssertFalse(archives[0].autocleanup, "an archive the server may prune is not an archive")
        XCTAssertEqual(archives[0].emulator, "mednafen_psx")
        XCTAssertEqual(archives[0].romID, romID)
    }

    /// Two attempts must not land in one slot: the second would deduplicate
    /// against the first and quietly write nothing.
    func testRetriedArchivesUseDistinctSlots() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator(seams(suffix: "first"))
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        // Stage 2 fails, so the whole thing is retried against a fresh coordinator
        // whose injected suffix differs, standing in for a new attempt.
        server.setCreateErrors([nil, RommError.http(500)])
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .local))

        let second = makeCoordinator(seams(suffix: "second"))
        guard case let .conflict(fresh) = try await second.reconcileBeforeLaunch() else {
            return XCTFail("the conflict must still be there")
        }
        try await second.resolve(fresh, choice: .local)

        let slots = server.archiveUploads.map(\.slot)
        XCTAssertEqual(slots.count, 2)
        XCTAssertNotEqual(slots[0], slots[1], "a retry must not reuse the first attempt's slot")
        XCTAssertTrue(slots.allSatisfy { $0.hasPrefix("conflict-") })
    }

    // MARK: - Two-stage resolution

    func testChoosingLocalArchivesRemoteFirstThenUploadsLocal() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        let statuses = try await drain(coordinator) {
            try await coordinator.resolve(token, choice: .local)
        }

        let uploads = server.uploads
        guard uploads.count == 2 else {
            return XCTFail("expected an archive then an active upload, got \(uploads.map(\.slot))")
        }
        XCTAssertNotEqual(uploads[0].slot, "0", "the archive goes first")
        XCTAssertEqual(uploads[0].data, cardC, "the archive holds the card being replaced")
        XCTAssertEqual(uploads[1].slot, "0")
        XCTAssertEqual(uploads[1].data, cardB)

        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(storedBaselineHash, hash(cardB))
        XCTAssertFalse(storedPending)
        XCTAssertEqual(statuses, [.synced])
    }

    func testChoosingRemoteArchivesLocalFirstThenReplacesLocal() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        try await coordinator.resolve(token, choice: .remote)

        let uploads = server.uploads
        guard uploads.count == 1 else {
            return XCTFail("expected exactly one archive, got \(uploads.map(\.slot))")
        }
        XCTAssertNotEqual(uploads[0].slot, "0")
        XCTAssertEqual(uploads[0].data, cardB, "the archive holds the local card being replaced")

        XCTAssertEqual(store.card(romID), cardC)
        XCTAssertEqual(storedBaselineHash, hash(cardC))
        XCTAssertEqual(storedBaselineRemoteID, 700)
        XCTAssertFalse(storedPending)
    }

    /// Stage 1 refused: the local card must still be the local card and nothing
    /// may have gone up as active.
    func testArchiveFailureChoosingLocalWritesNothing() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        server.setCreateErrors([RommError.http(500)])
        do {
            try await coordinator.resolve(token, choice: .local)
            XCTFail("a failed archive must refuse the whole resolution")
        } catch let error as PS1SaveSyncError {
            XCTAssertEqual(error, .archiveFailed(.serverError(status: 500)))
        }

        XCTAssertEqual(server.activeUploads.count, 0, "no active upload after a failed archive")
        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(server.blobs[700], cardC)
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertTrue(storedPending)

        // ...and it is still resolvable with the same token.
        server.setCreateErrors([])
        try await coordinator.resolve(token, choice: .local)
        XCTAssertEqual(storedBaselineHash, hash(cardB))
    }

    func testArchiveFailureChoosingRemoteWritesNothing() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        server.setCreateErrors([RommError.http(500)])
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .remote)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .archiveFailed(.serverError(status: 500)))
        }

        XCTAssertEqual(store.card(romID), cardB, "the local card must not be replaced")
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertTrue(storedPending)

        server.setCreateErrors([])
        try await coordinator.resolve(token, choice: .remote)
        XCTAssertEqual(store.card(romID), cardC)
    }

    /// The ordering test that matters most: the archive lands, the install does
    /// not, and everything is exactly where it was — with the token still good.
    func testStageTwoFailureChoosingLocalLeavesTheTokenRetryable() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        // Archive succeeds; the active create that follows it fails.
        server.setCreateErrors([nil, RommError.http(500)])
        let statuses = try await drain(coordinator) {
            await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .local)) {
                XCTAssertEqual($0 as? PS1SaveSyncError, .conflictNotResolved(.serverError(status: 500)))
            }
        }

        // Stage 1 did happen, and it holds the loser.
        let archives = server.archiveUploads
        guard archives.count == 1 else { return XCTFail("expected one archive, got \(archives.count)") }
        XCTAssertEqual(archives[0].data, cardC)
        // Both originals are intact.
        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(server.blobs[700], cardC)
        // And nothing moved on.
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertEqual(storedBaselineRemoteID, 700)
        XCTAssertTrue(storedPending)
        // `statuses` publishes changes, and the status was already `.conflict`, so
        // the point is what did *not* happen: no `.synced` claiming a resolution
        // that did not occur, and no `.failed` retiring a conflict that is still
        // outstanding.
        XCTAssertFalse(statuses.contains(.synced))
        XCTAssertFalse(statuses.contains(.failed))
        let standing = await coordinator.status
        XCTAssertEqual(standing, .conflict,
                       "a conflict that failed to resolve is still a conflict")

        // The same token still resolves.
        try await coordinator.resolve(token, choice: .local)
        XCTAssertEqual(storedBaselineHash, hash(cardB))
        XCTAssertEqual(store.card(romID), cardB)
    }

    func testStageTwoFailureChoosingRemoteLeavesTheTokenRetryable() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        // Archive succeeds; the local write that follows it fails.
        store.saveError = CocoaError(.fileWriteNoPermission)
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .remote)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .conflictNotResolved(.localWriteFailed))
        }

        let archives = server.archiveUploads
        guard archives.count == 1 else { return XCTFail("expected one archive, got \(archives.count)") }
        XCTAssertEqual(archives[0].data, cardB, "the local card was preserved before it could be lost")
        XCTAssertEqual(store.card(romID), cardB, "and it is still the local card")
        XCTAssertEqual(server.blobs[700], cardC)
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertTrue(storedPending)

        store.saveError = nil
        try await coordinator.resolve(token, choice: .remote)
        XCTAssertEqual(store.card(romID), cardC)
        XCTAssertEqual(storedBaselineHash, hash(cardC))
    }

    // MARK: - Why a resolution failed, not just that it did

    /// Every way the server can refuse an archive, and the cause each one has to
    /// survive as.
    ///
    /// The defect this pins is advice that contradicts its own cause: a single
    /// untyped `archiveFailed` whose recovery text is unconditionally "check your
    /// connection" tells a player whose token expired to go and look at their
    /// router. `probeRemote` already branches on `isConnectivityError` before
    /// deciding `unreachable` versus rethrowing; this is the same rule one layer
    /// up, where the state ("nothing was changed") has to survive alongside the
    /// reason.
    func testAFailedArchiveKeepsWhyItFailed() async throws {
        let cases: [(Error, PS1SaveSyncCause)] = [
            (URLError(.notConnectedToInternet), .serverUnreachable),
            (RommError.http(401), .tokenRejected),
            (RommError.http(403), .tokenRejected),
            (RommError.http(409), .anotherDeviceWrote),
            (RommError.http(500), .serverError(status: 500)),
            (RommError.badResponse, .unreadableAnswer),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")),
             .unreadableAnswer)
        ]
        for (thrown, expected) in cases {
            store = FakeCardStore()
            server = FakeRomM()
            store.put(cardB, romID: romID)
            server.seed(record(id: 700), bytes: cardC)
            seedBaseline(hash: hash(cardA), remoteID: 700)

            let coordinator = makeCoordinator()
            guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
                return XCTFail("expected a conflict for \(expected)")
            }
            server.setCreateErrors([thrown])
            await XCTAssertThrowsErrorAsync(
                try await coordinator.resolve(token, choice: .local)
            ) {
                XCTAssertEqual($0 as? PS1SaveSyncError, .archiveFailed(expected),
                               "\(thrown) was collapsed into the wrong cause")
            }
            // The state half of the sentence must survive alongside the reason.
            XCTAssertEqual(store.card(romID), cardB)
            XCTAssertEqual(storedBaselineHash, hash(cardA))
        }
    }

    /// The point of carrying the cause: the sentence a player reads changes with
    /// it. An expired token must not be answered with "check your connection",
    /// and a local write failure must not be answered with anything about the
    /// network at all.
    func testTheAdviceMatchesTheCauseRatherThanTheStage() {
        let offline = PS1SaveSyncError.archiveFailed(.serverUnreachable).recoverySuggestion
        XCTAssertEqual(offline,
                       "Check your connection to your RomM server, then choose again.")

        let token = PS1SaveSyncError.archiveFailed(.tokenRejected).recoverySuggestion ?? ""
        XCTAssertFalse(token.lowercased().contains("connection"), token)
        XCTAssertTrue(token.contains("token"), token)

        let server = PS1SaveSyncError.conflictNotResolved(.serverError(status: 503))
            .recoverySuggestion ?? ""
        XCTAssertFalse(server.lowercased().contains("connection"), server)
        XCTAssertTrue(server.contains("503"), server)

        let decode = PS1SaveSyncError.conflictNotResolved(.unreadableAnswer)
            .recoverySuggestion ?? ""
        XCTAssertFalse(decode.lowercased().contains("connection"), decode)

        let local = PS1SaveSyncError.conflictNotResolved(.localWriteFailed)
            .recoverySuggestion ?? ""
        XCTAssertFalse(local.lowercased().contains("connection"), local)
        XCTAssertFalse(local.lowercased().contains("server"), local)

        // Whatever the cause, the state half of the message is unchanged: an
        // archive that failed changed nothing, and a stage-2 failure archived the
        // loser and stopped.
        for cause in [PS1SaveSyncCause.serverUnreachable, .tokenRejected, .other] {
            XCTAssertEqual(PS1SaveSyncError.archiveFailed(cause).errorDescription,
                           PS1SaveSyncError.archiveFailed(.other).errorDescription)
            XCTAssertEqual(PS1SaveSyncError.conflictNotResolved(cause).errorDescription,
                           PS1SaveSyncError.conflictNotResolved(.other).errorDescription)
        }
    }

    /// The advice is only ever read on the chooser, where the one action a
    /// player has is to choose again — so every cause has to end by saying so.
    ///
    /// Asserted over `allCases` rather than over the handful the resolution
    /// tests happen to produce: a cause that explains itself and then stops
    /// leaves a player reading an explanation on a screen that is waiting for a
    /// decision, which is the same defect as advice that contradicts its cause.
    /// `allCases` cannot be synthesized — `serverError` carries a status — so it
    /// is built from `PS1SaveSyncCause.Kind`, the payload-free shadow of the
    /// enum, and this pins the two together in both directions:
    ///
    /// - a case **added** to `PS1SaveSyncCause` stops `var kind` compiling, and a
    ///   `Kind` added without a `sample` stops that switch compiling, so the list
    ///   grows by construction rather than by somebody remembering;
    /// - a `sample` that answers with the *wrong* case — the mistake the compiler
    ///   cannot see — collapses two kinds onto one and fails the set equality
    ///   below.
    ///
    /// The old spelling was a hand-written array and a hard-coded count of 8.
    /// That caught a case being dropped and caught a duplicated message, but a
    /// case added to the enum and not to the array passed both silently, which is
    /// the direction that actually happens.
    func testAllCasesReallyIsEveryCause() {
        XCTAssertEqual(Set(PS1SaveSyncCause.allCases.map(\.kind)),
                       Set(PS1SaveSyncCause.Kind.allCases),
                       "`allCases` does not cover every kind exactly once, so at least one "
                           + "cause is exempt from every assertion written over it")
        XCTAssertEqual(PS1SaveSyncCause.allCases.count, PS1SaveSyncCause.Kind.allCases.count,
                       "`allCases` repeats or omits a kind")
        XCTAssertEqual(Set(PS1SaveSyncCause.allCases.map(\.recoverySuggestion)).count,
                       PS1SaveSyncCause.allCases.count,
                       "two causes give the same advice, so at least one of them is wrong "
                           + "about what happened")
    }

    func testEveryCauseSaysWhatToDoNext() {
        XCTAssertFalse(PS1SaveSyncCause.allCases.isEmpty)
        for cause in PS1SaveSyncCause.allCases {
            let advice = cause.recoverySuggestion
            XCTAssertTrue(advice.lowercased().contains("choose again"),
                          "\(cause) leaves the player with nothing to do: \"\(advice)\"")
            // And it reaches the player through both stages, unchanged.
            for error in [PS1SaveSyncError.archiveFailed(cause),
                          PS1SaveSyncError.conflictNotResolved(cause)] {
                XCTAssertEqual(error.recoverySuggestion, advice, "\(error)")
            }
        }
    }

    /// Stage 2's local write is not a server failure at all, and used to be
    /// reported as one.
    func testAFailedLocalInstallIsNotReportedAsAConnectionProblem() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        store.saveError = CocoaError(.fileWriteNoPermission)
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .remote)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .conflictNotResolved(.localWriteFailed))
        }
    }

    /// The server accepted the upload but kept an older row — the dedup case
    /// `isAuthoritative` refuses. Nothing about that is a connection problem
    /// either.
    func testAnUnauthoritativeCreateSaysTheServerKeptAnOlderCopy() async throws {
        // The local card is bytes the server already holds under an *older* row,
        // so the create dedups back to it and cannot outrank the row it replaces.
        store.put(cardB, romID: romID)
        server.seed(record(id: 600, updatedAt: "2026-03-01T09:00:00"), bytes: cardB)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .local)) {
            XCTAssertEqual($0 as? PS1SaveSyncError,
                           .conflictNotResolved(.serverKeptAnOlderVersion))
        }
    }

    // MARK: - Token validity

    func testAnUnknownConflictTokenIsRejectedWithoutChangingEitherSide() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        _ = try await coordinator.reconcileBeforeLaunch()
        let stranger = PS1SaveConflict(id: UUID(), localModifiedAt: nil, remoteModifiedAt: nil)
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(stranger, choice: .local)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .conflictExpired)
        }
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertEqual(store.card(romID), cardB)
    }

    func testAResolvedTokenCannotBeResolvedTwice() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        try await coordinator.resolve(token, choice: .remote)
        let uploadsAfterFirst = server.uploadCount
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .local)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .conflictExpired)
        }
        XCTAssertEqual(server.uploadCount, uploadsAfterFirst)
    }

    /// The record moved on while the player was choosing. The token is refused
    /// and a fresh conflict describing the two cards that actually exist now is
    /// published in its place.
    func testASupersededTokenIsRejectedAndAFreshConflictIsSurfaced() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        // Another device writes a newer card into the slot — a third card, so the
        // fresh conflict is a genuine three-way disagreement rather than a
        // coincidence with the baseline.
        server.seed(record(id: 900, updatedAt: "2026-03-05T10:00:00"), bytes: cardD)

        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .local)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .conflictExpired)
        }
        XCTAssertEqual(server.uploadCount, 0, "a superseded token archives nothing")
        XCTAssertEqual(store.card(romID), cardB)

        // A fresh token was minted, and it resolves against the card that is
        // actually there now.
        let fresh = try await coordinator.reconcileBeforeLaunch()
        guard case let .conflict(freshToken) = fresh else {
            return XCTFail("expected a fresh conflict")
        }
        XCTAssertNotEqual(freshToken.id, token.id)
        try await coordinator.resolve(freshToken, choice: .remote)
        XCTAssertEqual(store.card(romID), cardD)
    }

    /// A conflict whose cause went away must not outlive it: a retained token
    /// blocks every retry, so one that nothing supports any more would wedge
    /// synchronization until the app was restarted.
    func testAReconciliationThatFindsNoDisagreementRetiresAStandingConflict() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator(seams(sleepGate: Gate()))
        guard case .conflict = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        // The other device replaces its card with one identical to this one, so
        // there is nothing left for anybody to choose between.
        server.seed(record(id: 900, updatedAt: "2026-03-05T10:00:00"), bytes: cardB)
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)
        let settled = await coordinator.status
        XCTAssertEqual(settled, .synced)

        // And the next card genuinely goes out rather than being held behind a
        // conflict that no longer exists.
        store.put(cardD, romID: romID)
        await coordinator.scheduleUpload(cardD)
        await coordinator.retryPending(reason: .quit)
        XCTAssertEqual(server.activeUploads.count, 1,
                       "a retired conflict must not keep blocking retries")
    }

    /// The local card changed under the token. Resolving `.remote` would destroy
    /// bytes that were never archived, so the token is refused.
    func testALocalCardThatChangedUnderTheTokenExpiresIt() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        store.put(cardA, romID: romID)
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .remote)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .conflictExpired)
        }
        XCTAssertEqual(store.card(romID), cardA, "the newer local card was not overwritten")
        XCTAssertEqual(server.uploadCount, 0)
    }

    func testAConflictCarriesBothModificationDates() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700, updatedAt: "2026-03-04T09:30:00"), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        XCTAssertNotNil(token.localModifiedAt)
        XCTAssertEqual(token.remoteModifiedAt,
                       PS1SaveCoordinator.parseTimestamp("2026-03-04T09:30:00"))
    }

    // MARK: - Debounce and retries

    func testDebounceCoalescesSeveralFlushesIntoOneUpload() async throws {
        let gate = Gate()
        let coordinator = makeCoordinator(seams(sleepGate: gate))
        store.put(cardA, romID: romID)

        await coordinator.scheduleUpload(cardA)
        await coordinator.scheduleUpload(cardB)
        await coordinator.scheduleUpload(cardC)
        XCTAssertEqual(server.uploadCount, 0, "nothing goes out while the timer is running")

        await gate.release()
        await coordinator.drainDebounce()

        let uploads = server.activeUploads
        guard uploads.count == 1 else {
            return XCTFail("three flushes must be one upload, got \(uploads.count)")
        }
        XCTAssertEqual(uploads[0].data, cardC, "and it is the newest card")
        XCTAssertFalse(storedPending)
    }

    func testRetryBypassesTheDebounce() async throws {
        // A gate that is never released: only a retry can get past it.
        let coordinator = makeCoordinator(seams(sleepGate: Gate()))
        store.put(cardA, romID: romID)
        await coordinator.scheduleUpload(cardA)
        XCTAssertEqual(server.uploadCount, 0)

        for reason: RetryReason in [.pause] {
            await coordinator.retryPending(reason: reason)
        }
        XCTAssertEqual(server.activeUploads.count, 1)
        XCTAssertFalse(storedPending)
    }

    func testEveryRetryReasonBypassesTheDebounce() async throws {
        for reason: RetryReason in [.launch, .pause, .quit, .background, .user] {
            server = FakeRomM()
            store = FakeCardStore()
            defaults.removePersistentDomain(forName: suiteName)
            let coordinator = makeCoordinator(seams(sleepGate: Gate()))
            store.put(cardA, romID: romID)
            await coordinator.scheduleUpload(cardA)
            await coordinator.retryPending(reason: reason)
            XCTAssertEqual(server.activeUploads.count, 1, "\(reason) must not wait")
        }
    }

    func testRetryDoesNothingWhenNothingIsOwed() async throws {
        let coordinator = makeCoordinator()
        await coordinator.retryPending(reason: .quit)
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertEqual(server.listCalls, 0)
    }

    /// An outstanding conflict outranks a pending upload: sending now would pick
    /// a side on the player's behalf.
    func testRetryWillNotUploadWhileAConflictIsOutstanding() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case .conflict = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        await coordinator.retryPending(reason: .quit)
        XCTAssertEqual(server.uploadCount, 0)
    }

    func testUploadFailurePreservesLocalBytesAndPending() async throws {
        let coordinator = makeCoordinator()
        store.put(cardA, romID: romID)
        server.setCreateErrors([RommError.http(503)])

        await coordinator.scheduleUpload(cardA)
        await coordinator.retryPending(reason: .user)

        XCTAssertTrue(storedPending)
        XCTAssertEqual(store.card(romID), cardA)
        XCTAssertNil(storedBaselineHash)
    }

    func testALaterRetryClearsPendingOnlyAfterASuccessfulResponse() async throws {
        let coordinator = makeCoordinator()
        store.put(cardA, romID: romID)
        server.setCreateErrors([RommError.http(503)])

        await coordinator.scheduleUpload(cardA)
        await coordinator.retryPending(reason: .pause)
        XCTAssertTrue(storedPending)

        let statuses = await drain(coordinator) {
            await coordinator.retryPending(reason: .user)
        }
        XCTAssertFalse(storedPending)
        XCTAssertEqual(storedBaselineHash, hash(cardA))
        XCTAssertEqual(statuses, [.syncing, .synced])
    }

    /// A cold start finds the flag but not the bytes, and re-reads the card from
    /// the store rather than sending anything it invented.
    func testAColdStartRetryReloadsTheCardFromTheStore() async throws {
        defaults.set(true, forKey: "ps1sync.rom.\(romID).pending")
        store.put(cardA, romID: romID)

        let coordinator = makeCoordinator()
        await coordinator.retryPending(reason: .launch)

        let uploads = server.activeUploads
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads[0].data, cardA)
    }

    /// Owed an upload with no card to send: uploading a blank card here is the
    /// same overwrite this file exists to prevent.
    func testAColdStartRetryWithNoLocalCardUploadsNothing() async throws {
        defaults.set(true, forKey: "ps1sync.rom.\(romID).pending")
        let coordinator = makeCoordinator()
        let statuses = await drain(coordinator) {
            await coordinator.retryPending(reason: .launch)
        }
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertTrue(storedPending)
        XCTAssertEqual(statuses, [.failed])
    }

    func testAColdStartRetryWithAnUnreadableCardUploadsNothing() async throws {
        defaults.set(true, forKey: "ps1sync.rom.\(romID).pending")
        store.loadError = CocoaError(.fileReadNoPermission)
        let coordinator = makeCoordinator()
        await coordinator.retryPending(reason: .launch)
        XCTAssertEqual(server.uploadCount, 0)
        XCTAssertTrue(storedPending)
    }

    /// A card that arrives while an older one is in flight keeps the flag set,
    /// and the older upload's completion cannot clear it.
    func testANewerCardDuringAnUploadStaysPending() async throws {
        let createGate = Gate()
        server.createGate = (createGate)
        let coordinator = makeCoordinator(seams(sleepGate: Gate()))
        store.put(cardA, romID: romID)
        await coordinator.scheduleUpload(cardA)

        let upload = Task { await coordinator.retryPending(reason: .user) }
        await createGate.untilArrivals(1)
        // Reentrancy: the actor is suspended inside the create.
        store.put(cardB, romID: romID)
        await coordinator.scheduleUpload(cardB)
        await createGate.release()
        await upload.value

        guard server.activeUploads.count == 1 else {
            return XCTFail("only the older card may go out, got \(server.activeUploads.count)")
        }
        XCTAssertEqual(server.activeUploads[0].data, cardA)
        XCTAssertTrue(storedPending, "the newer card is still owed")

        // Owed is not enough: the next retry has to actually send it.
        await coordinator.retryPending(reason: .quit)
        XCTAssertEqual(server.activeUploads.map(\.data), [cardA, cardB])
        XCTAssertFalse(storedPending)
    }

    // MARK: - One flush at a time

    /// Two retries are an ordinary tvOS sequence (pause, then background), and the
    /// pending flag is not cleared until an upload succeeds, so both get past
    /// `guard isPending`. Actor isolation protects each state access but not the
    /// operation across its awaits, and unserialized the second one compares the
    /// record it downloaded against the baseline the first one has since written —
    /// producing a conflict between the player's live card and a stale copy of
    /// that same card. Choosing `remote` there reverts their session.
    func testASecondRetryNeverConflictsWithTheFirstRetrysOwnUpload() async throws {
        let downloadGate = Gate()
        server.downloadGate = downloadGate
        server.seed(record(id: 5), bytes: cardA)
        seedBaseline(hash: hash(cardA), remoteID: 5)
        store.put(cardB, romID: romID)

        let coordinator = makeCoordinator(seams(sleepGate: Gate()))
        await coordinator.scheduleUpload(cardB)

        let pause = Task { await coordinator.retryPending(reason: .pause) }
        await downloadGate.untilArrivals(1)
        let background = Task { await coordinator.retryPending(reason: .background) }
        // Bounded rather than a condition wait: serialized, the second retry never
        // reaches the server at all, so waiting for a second arrival would hang.
        var spins = 0
        while await downloadGate.arrivalCount() < 2, spins < 200 {
            await Task.yield()
            spins += 1
        }
        await downloadGate.release()
        await pause.value
        await background.value

        XCTAssertEqual(server.activeUploads.count, 1, "two retries must not both upload")
        let standing = await coordinator.status
        XCTAssertEqual(standing, .synced,
                       "a device must never end up in conflict with its own upload")
        XCTAssertEqual(store.card(romID), cardB, "the live card must not be reverted")
        XCTAssertFalse(storedPending)
        XCTAssertEqual(storedBaselineHash, hash(cardB))
    }

    /// Waiting out an in-flight flush is not the same as absorbing into it. A card
    /// that arrives mid-flush leaves `settlePending` holding the flag, and both
    /// callers that reach `flush()` have already retired the trigger that would
    /// have sent it — `retryPending` bumps the generation on its way in, and a
    /// debounce firing is consumed. A caller that returned without doing a pass
    /// would leave the newest card on disk, flagged, with nothing scheduled: a
    /// silent stall, and this is the quit path.
    func testACardThatArrivesDuringAFlushIsSentByTheRetryThatFollowsIt() async throws {
        let downloadGate = Gate()
        server.downloadGate = downloadGate
        server.seed(record(id: 5), bytes: cardA)
        seedBaseline(hash: hash(cardA), remoteID: 5)
        store.put(cardB, romID: romID)

        let coordinator = makeCoordinator(seams(sleepGate: Gate()))
        await coordinator.scheduleUpload(cardB)
        let inFlight = Task { await coordinator.retryPending(reason: .user) }
        await downloadGate.untilArrivals(1)

        // The pause path: a newer card arrives and arms a debounce, and the pause
        // retry then retires that debounce on its way in.
        store.put(cardC, romID: romID)
        await coordinator.scheduleUpload(cardC)
        let pause = Task { await coordinator.retryPending(reason: .pause) }
        var spins = 0
        while await downloadGate.arrivalCount() < 2, spins < 200 {
            await Task.yield()
            spins += 1
        }
        await downloadGate.release()
        await inFlight.value
        await pause.value

        XCTAssertEqual(server.activeUploads.map(\.data), [cardB, cardC],
                       "the card that arrived mid-flush must actually go out, not just stay flagged")
        XCTAssertFalse(storedPending)
        XCTAssertEqual(storedBaselineHash, hash(cardC))
        let standing = await coordinator.status
        XCTAssertEqual(standing, .synced)
    }

    /// An owed upload must not displace an outstanding conflict in the published
    /// vocabulary. `performFlush` returns without publishing anything, so nothing
    /// would put `.conflict` back, and a stream-driven chooser would dismiss.
    ///
    /// The same test pins the guard inside `performFlush`: after a 409 the retained
    /// record still matches the baseline, so the pre-upload comparison would wave
    /// this upload through on its own.
    func testAnUploadScheduledDuringAConflictNeitherPublishesNorUploads() async throws {
        store.put(cardB, romID: romID)
        seedBaseline(hash: hash(cardA), remoteID: 700)
        server.seed(record(id: 700), bytes: cardA)
        server.setCreateErrors([RommError.http(409)])

        let gate = Gate()
        let coordinator = makeCoordinator(seams(sleepGate: gate))
        await coordinator.scheduleUpload(cardB)
        await coordinator.retryPending(reason: .quit)

        let afterConflict = server.activeUploads.count
        let standing = await coordinator.status
        XCTAssertEqual(standing, .conflict)

        // The next frame flush arms the debounce again.
        await coordinator.scheduleUpload(cardB)
        let duringConflict = await coordinator.status
        XCTAssertEqual(duringConflict, .conflict,
                       "an owed upload must not displace an outstanding conflict")
        await gate.release()
        await coordinator.drainDebounce()

        XCTAssertEqual(server.activeUploads.count, afterConflict,
                       "nothing may be uploaded while a conflict is outstanding")
        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(server.blobs[700], cardA)
        let settled = await coordinator.status
        XCTAssertEqual(settled, .conflict)
    }

    // MARK: - Resolution against a server that moved or went away

    /// A blip while the chooser is on screen must not make the player start over:
    /// nothing was asked of the server, so the two cards are still the ones the
    /// token names.
    func testAnUnreachableServerWhileChoosingKeepsTheToken() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        server.listError = offline()
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .remote)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .serverUnreachableDuringResolution)
        }
        XCTAssertEqual(server.uploadCount, 0, "nothing was archived")
        XCTAssertEqual(store.card(romID), cardB, "nothing was replaced")
        let standing = await coordinator.status
        XCTAssertEqual(standing, .conflict)

        // And the very same token resolves once the server is back.
        server.listError = nil
        try await coordinator.resolve(token, choice: .remote)
        XCTAssertEqual(store.card(romID), cardC)
        XCTAssertEqual(server.archiveUploads.count, 1)
    }

    /// The remote half of the token is gone. There is nothing to archive against
    /// and nothing to install, so the token is retired rather than acted on.
    func testARecordThatVanishedWhileChoosingRetiresTheToken() async throws {
        store.put(cardB, romID: romID)
        server.seed(record(id: 700), bytes: cardC)
        seedBaseline(hash: hash(cardA), remoteID: 700)

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("expected a conflict")
        }
        server.removeSave(700)
        await XCTAssertThrowsErrorAsync(try await coordinator.resolve(token, choice: .local)) {
            XCTAssertEqual($0 as? PS1SaveSyncError, .conflictExpired)
        }
        XCTAssertEqual(server.uploadCount, 0, "a token whose remote half is gone archives nothing")
        XCTAssertEqual(store.card(romID), cardB)
        let standing = await coordinator.status
        XCTAssertEqual(standing, .failed)
    }

    /// A crash leaves the flag set; the next run may retry before it ever prepares
    /// a launch. Without registering here that whole pass is anonymous, which is
    /// exactly when the server's conflict detection matters most.
    func testAColdStartRetryRegistersTheDeviceBeforeItSyncs() async throws {
        defaults.set(true, forKey: "ps1sync.rom.\(romID).pending")
        store.put(cardA, romID: romID)
        server.seed(record(id: 700), bytes: cardA)

        let coordinator = makeCoordinator()
        await coordinator.retryPending(reason: .launch)

        XCTAssertEqual(server.registrations,
                       ["rommpletv-00000000-1111-2222-3333-444444444444"])
        let resolved = await coordinator.deviceID
        XCTAssertEqual(resolved, "device-1")
        let downloads = server.downloads
        guard downloads.count == 1 else { return XCTFail("expected one download") }
        XCTAssertEqual(downloads[0].deviceID, "device-1",
                       "a cold-start sync must identify itself or every later upload 409s")
    }

    // MARK: - Lost updates

    /// A remote card that does not match the baseline is a card written since
    /// this device last synchronized. Publishing a conflict is what stops the
    /// pending upload from being the thing that decides.
    func testARemoteChangeDiscoveredBeforeAPendingUploadBecomesAConflict() async throws {
        store.put(cardB, romID: romID)
        seedBaseline(hash: hash(cardA), remoteID: 700)
        server.seed(record(id: 900, updatedAt: "2026-03-05T10:00:00"), bytes: cardC)

        let coordinator = makeCoordinator(seams(sleepGate: Gate()))
        let statuses = await drain(coordinator) {
            await coordinator.scheduleUpload(cardB)
            await coordinator.retryPending(reason: .quit)
        }
        XCTAssertEqual(server.uploadCount, 0, "neither version is overwritten")
        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(server.blobs[900], cardC)
        XCTAssertTrue(storedPending)
        XCTAssertEqual(statuses, [.pending, .syncing, .conflict])
    }

    /// The server's own refusal. It is a conflict, not a failure, and it costs
    /// neither byte sequence.
    func testAServerConflictBecomesAConflictNotAFailure() async throws {
        store.put(cardB, romID: romID)
        seedBaseline(hash: hash(cardA), remoteID: 700)
        // The list still shows the baseline record, so the client-side check
        // passes and only the server knows another device got there first.
        server.seed(record(id: 700), bytes: cardA)
        server.setCreateErrors([RommError.http(409)])

        let coordinator = makeCoordinator(seams(sleepGate: Gate()))
        let statuses = await drain(coordinator) {
            await coordinator.scheduleUpload(cardB)
            await coordinator.retryPending(reason: .quit)
        }
        XCTAssertEqual(store.card(romID), cardB)
        XCTAssertEqual(server.blobs[700], cardA)
        XCTAssertTrue(storedPending)
        XCTAssertEqual(storedBaselineHash, hash(cardA), "a 409 moves no baseline")
        XCTAssertEqual(statuses, [.pending, .syncing, .conflict])
    }

    /// And the conflict a 409 produces is resolvable — with the archive-first
    /// ordering intact.
    func testAServerConflictProducesAResolvableToken() async throws {
        store.put(cardB, romID: romID)
        seedBaseline(hash: hash(cardA), remoteID: 700)
        server.seed(record(id: 700), bytes: cardA)
        server.setCreateErrors([RommError.http(409)])

        let coordinator = makeCoordinator()
        guard case let .conflict(token) = try await coordinator.reconcileBeforeLaunch() else {
            return XCTFail("a 409 during preparation must surface as a conflict")
        }
        try await coordinator.resolve(token, choice: .remote)
        XCTAssertEqual(store.card(romID), cardA)
        let archives = server.archiveUploads
        guard archives.count == 1 else { return XCTFail("expected one archive, got \(archives.count)") }
        XCTAssertEqual(archives[0].data, cardB)
    }

    /// A create that returns a row older than the one it was meant to replace did
    /// not become the newest card. Believing it would file a baseline the server
    /// disagrees with, and the next reconciliation would overwrite the player's
    /// card without archiving it.
    func testACreateDeduplicatedOntoAnOlderRowIsNotBelieved() async throws {
        // The slot already holds cardA (older) and cardC (newest). The local card
        // has gone back to exactly cardA, so RomM's content-hash dedup answers
        // with the older row.
        server.seed(record(id: 700, updatedAt: "2026-03-01T10:00:00"), bytes: cardA)
        server.seed(record(id: 900, updatedAt: "2026-03-05T10:00:00"), bytes: cardC)
        store.put(cardA, romID: romID)
        seedBaseline(hash: hash(cardC), remoteID: 900)

        let coordinator = makeCoordinator()
        await XCTAssertEqualAsync(try await coordinator.reconcileBeforeLaunch(), .ready)

        XCTAssertEqual(storedBaselineHash, hash(cardC),
                       "a deduplicated create must not move the baseline onto the older row")
        XCTAssertTrue(storedPending)
        XCTAssertEqual(store.card(romID), cardA, "and the player's card is untouched")
    }

    // MARK: - What is persisted

    func testSynchronizationMetadataIsPersistedButCardBytesAreNot() async throws {
        // A real store, so the ≤64 KiB mirror rule is exercised alongside the
        // coordinator's own keys against one defaults suite.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = BatterySaveStore(cachesRoot: root, defaults: defaults)
        try real.save(cardA, romID: romID)

        let coordinator = PS1SaveCoordinator(canonicalRomID: romID, localStore: real,
                                             defaults: defaults, seams: seams())
        _ = try await coordinator.reconcileBeforeLaunch()
        // Drive the in-play write path as well, since that is where a card is
        // most tempting to stash: `scheduleUpload` is handed the bytes directly.
        try real.save(cardB, romID: romID)
        await coordinator.scheduleUpload(cardB)
        await coordinator.retryPending(reason: .quit)

        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNotNil(domain["ps1sync.rom.\(romID).baselineHash"])
        XCTAssertNotNil(domain["ps1sync.rom.\(romID).baselineRemoteID"])
        XCTAssertNotNil(domain["ps1sync.rom.\(romID).baselineAt"])
        XCTAssertNotNil(domain["ps1sync.rom.\(romID).remoteUpdatedAt"])
        XCTAssertNotNil(domain["ps1sync.device.installIdentifier"])
        XCTAssertNotNil(domain["ps1sync.device.id"])

        for (key, value) in domain {
            guard let data = value as? Data else { continue }
            XCTAssertLessThanOrEqual(data.count, BatterySaveStore.mirrorLimit,
                                     "\(key) is too big for the ~500KB defaults budget")
            XCTAssertNotEqual(data, cardA, "\(key) holds memory-card bytes")
            XCTAssertNotEqual(data, cardB, "\(key) holds memory-card bytes")
        }
        XCTAssertNil(domain["srm.\(romID)"], "a 128 KiB card must not be mirrored at all")
    }

    // MARK: - Status hygiene

    func testStatusesNeverCarryServerDetail() async throws {
        // Every case the stream can publish, all of them from this one enum.
        let every: [PS1SaveSyncStatus] = [.idle, .pending, .syncing, .conflict, .failed, .synced]
        for status in every {
            XCTAssertFalse(String(describing: status).contains("http"))
            XCTAssertFalse(String(describing: status).contains("401"))
        }

        store.put(cardA, romID: romID)
        server.setCreateErrors([RommError.http(418)])
        let coordinator = makeCoordinator()
        let statuses = try await drain(coordinator) {
            _ = try await coordinator.reconcileBeforeLaunch()
        }
        XCTAssertEqual(statuses, [.pending, .syncing, .failed])
        for status in statuses { XCTAssertTrue(every.contains(status)) }
    }
}

// MARK: - Helpers

// MARK: - Async assertion helpers
//
// `XCTAssert…`'s autoclosures are not async, so anything read off an actor has to
// come through one of these rather than being inlined into the assertion.

func XCTAssertEqualAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> T, _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertEqual(value, expected, message(), file: file, line: line)
    }
    catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertNotEqualAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> T, _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNotEqual(value, expected, message(), file: file, line: line)
    }
    catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNil(value, message(), file: file, line: line)
    }
    catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertNotNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNotNil(value, message(), file: file, line: line)
    }
    catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertTrueAsync(
    _ expression: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertTrue(value, message(), file: file, line: line)
    }
    catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertFalseAsync(
    _ expression: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertFalse(value, message(), file: file, line: line)
    }
    catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertLessThanOrEqualAsync<T: Comparable>(
    _ expression: @autoclosure () async throws -> T, _ limit: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertLessThanOrEqual(value, limit, message(), file: file, line: line)
    }
    catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertGreaterThanOrEqualAsync<T: Comparable>(
    _ expression: @autoclosure () async throws -> T, _ limit: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertGreaterThanOrEqual(value, limit, message(), file: file, line: line)
    } catch { XCTFail("threw \(error). \(message())", file: file, line: line) }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "expected a throw",
    file: StaticString = #filePath, line: UInt = #line,
    _ inspect: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        inspect(error)
    }
}

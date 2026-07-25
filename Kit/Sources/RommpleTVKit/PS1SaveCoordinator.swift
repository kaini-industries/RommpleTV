import CryptoKit
import Foundation

// MARK: - Public vocabulary

/// What preparing a PlayStation memory card concluded.
public enum PS1SaveLaunchDecision: Sendable, Equatable {
    /// The local card is the one to play. Launch.
    case ready
    /// Two cards disagree and only a person can say which one is theirs. Nothing
    /// has been written on either side.
    case conflict(PS1SaveConflict)
}

/// An outstanding disagreement between the local card and the server's.
///
/// Opaque on purpose: the two dates are everything a chooser needs, and the
/// record id and digests the coordinator binds this token to are held internally
/// so a caller cannot hand back a token describing a state that has moved on.
public struct PS1SaveConflict: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let localModifiedAt: Date?
    public let remoteModifiedAt: Date?

    public init(id: UUID, localModifiedAt: Date?, remoteModifiedAt: Date?) {
        self.id = id
        self.localModifiedAt = localModifiedAt
        self.remoteModifiedAt = remoteModifiedAt
    }
}

public enum PS1ConflictChoice: Sendable, Equatable { case local, remote }

/// The only things this coordinator will ever say out loud. No status carries a
/// status code, a URL, a host name or a server message.
public enum PS1SaveSyncStatus: Sendable, Equatable {
    case idle, pending, syncing, conflict, failed, synced
}

/// Why a retry is happening. Every one of these bypasses the debounce — a player
/// quitting is not going to wait out a timer.
public enum RetryReason: Sendable, Equatable { case launch, pause, quit, background, user }

/// Why a resolution stage could not be carried out.
///
/// This exists because the advice a player needs depends entirely on it, while
/// the *state* they need to be told about — "nothing was changed" against "the
/// loser was archived and then the change stopped" — depends entirely on the
/// stage. Collapsing the two into one untyped refusal is how a player whose token
/// expired gets told to check their router. `probeRemote` already branches on
/// `seams.isConnectivityError` before deciding `unreachable` versus rethrowing;
/// this is the same rule where the stage has to survive alongside the reason.
public enum PS1SaveSyncCause: Equatable, Sendable {
    /// The device could not reach the server — and nothing else. A reachable
    /// server behaving badly is one of the cases below.
    case serverUnreachable
    /// The server refused this app's access token (401/403).
    case tokenRejected
    /// Another device wrote this game's card while the chooser was on screen —
    /// RomM's 409. Not a server problem, and not something logs will explain.
    case anotherDeviceWrote
    /// The server answered with a status that is not a refusal of the token.
    case serverError(status: Int)
    /// The server answered with something this app could not read: a non-HTTP
    /// response, or a body that did not decode.
    case unreadableAnswer
    /// The winning card could not be written to this device. Not a server
    /// failure at all, and used to be reported as one.
    case localWriteFailed
    /// The upload was accepted but did not become the newest version — RomM
    /// deduplicated it against an older row. See `isAuthoritative`.
    case serverKeptAnOlderVersion
    /// Anything else. No advice beyond trying again is honest for this.
    case other

    /// What to do about it.
    ///
    /// **Every one of these names choosing again as the next action** — a rule
    /// rather than a habit, because the only screen they are ever shown on is
    /// the chooser, and a player standing in front of two memory cards has
    /// exactly one action available. A branch that explains the cause and stops
    /// is the same defect this type exists to remove, one notch softer.
    /// `PS1SaveCoordinatorTests.testEveryCauseSaysWhatToDoNext` asserts it over
    /// `allCases`.
    var recoverySuggestion: String {
        switch self {
        case .serverUnreachable:
            return "Check your connection to your RomM server, then choose again."
        case .tokenRejected:
            return "Create a fresh token on your RomM server and enter it in Server Settings, "
                + "then choose again."
        case .anotherDeviceWrote:
            return "Another device saved this game while you were choosing. Choose again."
        case let .serverError(status):
            return "Your RomM server answered with status \(status). Choose again; if it keeps "
                + "happening, check your server's logs."
        case .unreadableAnswer:
            return "Your RomM server sent an answer RommpleTV could not read, which usually "
                + "means it is a version RommpleTV does not understand yet. Choose again."
        case .localWriteFailed:
            return "Restart RommpleTV, then choose again."
        case .serverKeptAnOlderVersion:
            return "Your RomM server kept an older copy instead of the one RommpleTV sent. "
                + "Choose again."
        case .other:
            return "Choose again."
        }
    }
}

extension PS1SaveSyncCause {
    /// The payload-free shadow of `PS1SaveSyncCause`.
    ///
    /// It exists so `allCases` can be built rather than written down.
    /// `serverError` carries a status, so nothing is synthesized for the cause
    /// itself — and the hand-written list this replaced only guarded one
    /// direction: a case *dropped* from it was caught by a count assertion, but a
    /// case *added* to the enum and not to the list passed silently, which is the
    /// direction that actually happens.
    ///
    /// With this, a new cause breaks compilation twice — once at `kind`, once at
    /// `sample` — and the list grows by construction, with no count to bump.
    enum Kind: CaseIterable, Hashable {
        case serverUnreachable, tokenRejected, anotherDeviceWrote, serverError,
             unreadableAnswer, localWriteFailed, serverKeptAnOlderVersion, other
    }

    /// Which kind this cause is. Exhaustive by the compiler.
    var kind: Kind {
        switch self {
        case .serverUnreachable: return .serverUnreachable
        case .tokenRejected: return .tokenRejected
        case .anotherDeviceWrote: return .anotherDeviceWrote
        case .serverError: return .serverError
        case .unreadableAnswer: return .unreadableAnswer
        case .localWriteFailed: return .localWriteFailed
        case .serverKeptAnOlderVersion: return .serverKeptAnOlderVersion
        case .other: return .other
        }
    }
}

extension PS1SaveSyncCause.Kind {
    /// One inhabitant of this kind, which is all `allCases` needs: the status on
    /// `serverError` is a payload every assertion written over `allCases` is
    /// deliberately indifferent to.
    var sample: PS1SaveSyncCause {
        switch self {
        case .serverUnreachable: return .serverUnreachable
        case .tokenRejected: return .tokenRejected
        case .anotherDeviceWrote: return .anotherDeviceWrote
        case .serverError: return .serverError(status: 500)
        case .unreadableAnswer: return .unreadableAnswer
        case .localWriteFailed: return .localWriteFailed
        case .serverKeptAnOlderVersion: return .serverKeptAnOlderVersion
        case .other: return .other
        }
    }
}

extension PS1SaveSyncCause: CaseIterable {
    /// Every cause, one per `Kind`, by construction.
    public static var allCases: [PS1SaveSyncCause] { Kind.allCases.map(\.sample) }
}

/// The refusals this coordinator raises on its own behalf. Errors from the server
/// (`RommError.http`, decode failures) are rethrown as themselves so a caller can
/// tell an expired token from a broken server; only `statuses` is sanitized.
public enum PS1SaveSyncError: Error, Equatable, Sendable, LocalizedError {
    /// The local card exists, or may exist, but could not be read. Never the same
    /// answer as "there is no card".
    case localCardUnreadable
    /// The winning card could not be written locally.
    case localCardNotWritable
    /// A card was synchronized before, is not on this device now, and the server
    /// cannot be reached to find out whether it still has one. Launching would
    /// hand the core a blank card, which the next sync would then upload over a
    /// card that is known to exist.
    case serverUnreachableWithMissingCard
    /// The conflict being resolved no longer describes the two cards on hand. A
    /// fresh conflict is published when there is still one.
    case conflictExpired
    /// The losing card could not be archived. Nothing was replaced. The cause
    /// travels with it: the sentence a player reads is "what happened" from the
    /// case and "what to do" from the cause, and the second one is wrong for most
    /// causes if it is written once for the case.
    case archiveFailed(PS1SaveSyncCause)
    /// The loser was archived but the winner could not be installed. Both cards
    /// are exactly as they were and the conflict is still resolvable.
    case conflictNotResolved(PS1SaveSyncCause)
    /// The server could not be reached while resolving. Nothing was archived,
    /// nothing was replaced, and the same conflict is still resolvable.
    case serverUnreachableDuringResolution

    public var errorDescription: String? {
        switch self {
        case .localCardUnreadable:
            return "RommpleTV could not read this game's memory card on this Apple TV."
        case .localCardNotWritable:
            return "RommpleTV could not save this game's memory card to this Apple TV."
        case .serverUnreachableWithMissingCard:
            return "This game's memory card is on your RomM server, and RommpleTV "
                + "cannot reach it right now."
        case .conflictExpired:
            return "This game's memory card changed while you were choosing."
        case .archiveFailed:
            return "RommpleTV could not put a copy of the memory card you are "
                + "replacing on your RomM server, so nothing was changed."
        case .conflictNotResolved:
            return "RommpleTV saved a copy of the memory card you are replacing, "
                + "but could not finish the change."
        case .serverUnreachableDuringResolution:
            return "RommpleTV cannot reach your RomM server, so nothing was changed."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .localCardUnreadable, .localCardNotWritable:
            return "Restart RommpleTV, then try again."
        case .serverUnreachableWithMissingCard:
            return "Check your connection to your RomM server, then try again."
        case .conflictExpired:
            return "Choose again."
        case let .archiveFailed(cause), let .conflictNotResolved(cause):
            // The one place the cause is spent. Every branch of it ends in
            // "choose again", so the stage's own message still reads as one
            // sentence with it.
            return cause.recoverySuggestion
        case .serverUnreachableDuringResolution:
            // Not a classified cause: this one is raised only where the probe
            // already answered `unreachable`, so there is nothing to classify.
            return "Check your connection to your RomM server, then choose again."
        }
    }
}

/// One upload, as the coordinator asks for it. A value type so a test can assert
/// on exactly what identity went out, rather than on six positional arguments.
public struct PS1SaveUploadRequest: Sendable, Equatable {
    public let romID: Int
    public let emulator: String
    public let slot: String
    public let deviceID: String?
    public let data: Data
    public let autocleanup: Bool
    public let autocleanupLimit: Int
}

/// Everything the coordinator reaches outside itself for. Bundled rather than
/// spread across a nine-argument initializer, and defaulted for the three that
/// only exist so tests can run without a clock or a delay.
public struct PS1SaveSeams: Sendable {
    public var listSaves: @Sendable (Int) async throws -> [RommSave]
    /// `(saveID, deviceID)`. The device id travels with the download because that
    /// is what makes RomM record this device as holding the save — see
    /// `RommClient.saveContentRequest`.
    public var downloadSave: @Sendable (Int, String?) async throws -> Data
    public var createSave: @Sendable (PS1SaveUploadRequest) async throws -> RommSave
    public var listDevices: @Sendable () async throws -> [RommDevice]
    /// `(hostname) -> device id`.
    public var registerDevice: @Sendable (String) async throws -> String
    public var now: @Sendable () -> Date
    /// The unique half of an archive slot name. Injected so a retry cannot land
    /// on the slot a previous attempt used even within the same clock second.
    public var uniqueSuffix: @Sendable () -> String
    /// The stable per-install identifier, generated once and then persisted.
    public var makeInstallIdentifier: @Sendable () -> String
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    public var isConnectivityError: @Sendable (Error) -> Bool

    public init(
        listSaves: @escaping @Sendable (Int) async throws -> [RommSave],
        downloadSave: @escaping @Sendable (Int, String?) async throws -> Data,
        createSave: @escaping @Sendable (PS1SaveUploadRequest) async throws -> RommSave,
        listDevices: @escaping @Sendable () async throws -> [RommDevice],
        registerDevice: @escaping @Sendable (String) async throws -> String,
        now: @escaping @Sendable () -> Date = { Date() },
        uniqueSuffix: @escaping @Sendable () -> String = {
            String(UUID().uuidString.prefix(8)).lowercased()
        },
        makeInstallIdentifier: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        isConnectivityError: @escaping @Sendable (Error) -> Bool = {
            PS1PackageStore.isLikelyConnectivityError($0)
        }
    ) {
        self.listSaves = listSaves
        self.downloadSave = downloadSave
        self.createSave = createSave
        self.listDevices = listDevices
        self.registerDevice = registerDevice
        self.now = now
        self.uniqueSuffix = uniqueSuffix
        self.makeInstallIdentifier = makeInstallIdentifier
        self.sleep = sleep
        self.isConnectivityError = isConnectivityError
    }
}

// MARK: - The coordinator

/// Keeps one PlayStation memory card the same on this Apple TV and on RomM.
///
/// ## The rule everything else serves
///
/// **No path here destroys a card.** Three arrangements carry that, and they are
/// worth naming because each of them looks like an ordinary line of code:
///
/// 1. **The local read is the first statement of every entry point**, and it
///    distinguishes "no card" from "could not read the card". `SaveRAMStoring`
///    throws for the second, and a throw stops reconciliation before a single
///    request is made. If a read error read as absence, a card that is present
///    but momentarily unreadable would be replaced by the server's copy.
/// 2. **Unreachable is not absent.** A card that has a baseline is a card that is
///    known to exist somewhere. If it is not on this device and the server cannot
///    be asked, preparation fails rather than launching the core against a blank
///    card — because the core would then write that blank card, and the next sync
///    would upload it over the real one. This is the single worst thing this file
///    could do, and it is the one branch with no fallback.
/// 3. **Conflict resolution archives before it installs.** Two awaits in a fixed
///    order: the losing bytes go to their own autocleanup-exempt slot and the
///    archive must succeed, and only then is the winner written. A failure
///    between the two leaves the baseline, the pending flag, the retained
///    conflict and both byte sequences untouched, so the token is still good.
///
/// ## What the server actually does (RomM 5.0.0, read rather than assumed)
///
/// - `POST /api/saves` with a non-empty `slot` stamps the stored filename with a
///   fresh `[YYYY-MM-DD_HH-MM-SS]` tag *before* looking the save up by filename,
///   so a slotted upload inserts a new row rather than updating one. Slot `"0"` is
///   therefore a version stream that `autocleanup` prunes to `autocleanupLimit`,
///   and `autocleanup: false` on the archive slots is what makes them permanent.
///   Nothing here relies on that: selection is deterministic over whatever set of
///   rows comes back, and the comparison that decides everything is over bytes.
/// - Both of `add_save`'s 409 branches are skipped when no device resolves, so an
///   unregistered client gets no conflict signal at all. Registration is
///   attempted once per instance and its failure is recorded, not fatal.
/// - `GET /api/saves/{id}/content` is what records that this device holds a save,
///   and only when `device_id` is on the request. The slot's 409 branch treats a
///   *missing* sync row as a conflict, so downloading anonymously would 409 every
///   subsequent upload. Downloads therefore carry the device id.
/// - An upload whose content hash already exists in the slot returns the existing
///   row and writes nothing. That makes a no-op sync free, and it is also why a
///   create is only believed when the row it returns is newer than the row that
///   was newest before it — see `isAuthoritative`.
///
/// ## What is persisted
///
/// Namespaced UserDefaults keys hold the install identifier, the server's device
/// id, the baseline digest, the baseline record id, timestamps and the pending
/// flag. **No card bytes.** A PlayStation card is ~128 KiB against a ~500 KB
/// budget for the whole app; the pending card lives in memory while the app runs
/// and is re-read from `localStore` after a cold start.
public actor PS1SaveCoordinator {

    // MARK: Identity

    /// The emulator every active card is filed under.
    public static let emulator = "mednafen_psx"
    /// The one slot an active card ever occupies. Archives never use it.
    public static let activeSlot = "0"
    /// Every archive slot starts with this, and nothing else does.
    public static let conflictSlotPrefix = "conflict-"
    /// How many versions of the active slot the server is asked to keep.
    public static let activeSlotRetention = 10
    /// How long frame flushes are collected before one upload goes out.
    public static let debounceInterval: TimeInterval = 5

    private static let devicePlatform = "tvOS"
    private static let deviceClient = "RommpleTV"

    // MARK: Stored

    public nonisolated let localStore: any SaveRAMStoring
    public nonisolated let statuses: AsyncStream<PS1SaveSyncStatus>
    public nonisolated let canonicalRomID: Int

    private nonisolated let continuation: AsyncStream<PS1SaveSyncStatus>.Continuation
    private let defaults: UserDefaults
    private nonisolated let seams: PS1SaveSeams

    private var lastPublished: PS1SaveSyncStatus?
    private var retained: RetainedConflict?
    private var pendingBytes: Data?
    private var pendingHash: String?
    private var uploadGeneration = 0
    private var debounceTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var didAttemptRegistration = false
    private var registeredDeviceID: String?

    /// The conflict the caller was handed, plus everything it was minted against.
    /// Both byte sequences are held here so resolution never has to go and fetch
    /// a card it already had.
    private struct RetainedConflict {
        let id: UUID
        let localBytes: Data
        let localHash: String
        let remoteID: Int
        let remoteHash: String
        let remoteBytes: Data
    }

    private struct Baseline: Equatable {
        let hash: String
        let remoteID: Int
    }

    // MARK: Init

    public init(canonicalRomID: Int,
                localStore: any SaveRAMStoring,
                defaults: UserDefaults,
                seams: PS1SaveSeams) {
        self.canonicalRomID = canonicalRomID
        self.localStore = localStore
        self.defaults = defaults
        self.seams = seams
        var escaped: AsyncStream<PS1SaveSyncStatus>.Continuation!
        // Unbounded: a status a caller has not read yet is a transition it still
        // needs, and there are at most a handful per sync.
        self.statuses = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
    }

    /// A `RommClient`-backed coordinator, which is how the app builds one.
    public init(canonicalRomID: Int,
                client: RommClient,
                localStore: any SaveRAMStoring,
                defaults: UserDefaults = .standard) {
        self.init(
            canonicalRomID: canonicalRomID,
            localStore: localStore,
            defaults: defaults,
            seams: PS1SaveSeams(
                listSaves: { [client] romID in try await client.saves(romID: romID) },
                downloadSave: { [client] saveID, deviceID in
                    let request = client.saveContentRequest(id: saveID, deviceID: deviceID)
                    let (data, response) = try await client.sessionForDownloads.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw RommError.badResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw RommError.http(http.statusCode)
                    }
                    return data
                },
                createSave: { [client] upload in
                    try await client.createSave(
                        romID: upload.romID, emulator: upload.emulator, slot: upload.slot,
                        deviceID: upload.deviceID, data: upload.data,
                        autocleanup: upload.autocleanup,
                        autocleanupLimit: upload.autocleanupLimit)
                },
                listDevices: { [client] in try await client.devices() },
                registerDevice: { [client] hostname in
                    try await client.registerDevice(
                        name: PS1SaveCoordinator.deviceClient,
                        platform: PS1SaveCoordinator.devicePlatform,
                        client: PS1SaveCoordinator.deviceClient,
                        clientVersion: Bundle.main
                            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                        hostname: hostname).deviceID
                }))
    }

    deinit { continuation.finish() }

    // MARK: - Device identity

    /// The stable per-install identifier this Apple TV is fingerprinted by,
    /// generated once and persisted. RomM dedups registrations on
    /// `hostname` + `platform`, so this is what makes a re-registration return
    /// the device already on file instead of adding another one.
    public var installIdentifier: String {
        if let existing = defaults.string(forKey: Keys.installIdentifier), !existing.isEmpty {
            return existing
        }
        let created = "rommpletv-" + seams.makeInstallIdentifier()
        defaults.set(created, forKey: Keys.installIdentifier)
        return created
    }

    /// Whether the last registration attempt left this device without an id RomM
    /// will accept. Recorded rather than thrown: play continues, but the server's
    /// own conflict detection is off while this is true, so it is worth surfacing.
    public var deviceRegistrationDidFail: Bool {
        defaults.bool(forKey: Keys.registrationFailed)
    }

    /// The server's id for this device, once one has been obtained.
    public var deviceID: String? { registeredDeviceID }

    /// Finds or creates this device's RomM registration. At most once per
    /// instance; a new instance retries, which is what heals a server whose
    /// device table was reset.
    ///
    /// Listing first rather than registering blind serves two purposes: it is how
    /// an existing registration is recovered by fingerprint, and it proves the
    /// token carries the device read scope that downloads will need — so by the
    /// time any `device_id` is put on a request, both scopes are known good.
    ///
    /// Failure is not fatal. A cached id from a previous run is used if there is
    /// one (better a possibly-stale id than no conflict detection at all); with
    /// no id, the flag is set and uploads go out anonymously.
    private func ensureDeviceRegistered() async {
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true
        let hostname = installIdentifier
        do {
            let known = try await seams.listDevices()
            if let match = known.first(where: { $0.hostname == hostname }) {
                registeredDeviceID = match.id
            } else {
                registeredDeviceID = try await seams.registerDevice(hostname)
            }
            defaults.set(registeredDeviceID, forKey: Keys.deviceID)
            defaults.set(false, forKey: Keys.registrationFailed)
        } catch {
            registeredDeviceID = defaults.string(forKey: Keys.deviceID)
            defaults.set(registeredDeviceID == nil, forKey: Keys.registrationFailed)
        }
    }

    // MARK: - Preparation

    /// Decides what card this game should launch with, and gets the two sides
    /// agreeing when it can do so without asking anyone.
    ///
    /// Reads local before anything else so that a local read failure costs no
    /// request and can write nothing, anywhere.
    public func reconcileBeforeLaunch() async throws -> PS1SaveLaunchDecision {
        let local = try readLocal()
        await ensureDeviceRegistered()
        let probe = try await probeRemote()
        // This reconciliation supersedes any conflict an earlier one left
        // standing. Every branch below either mints a fresh token or has just
        // established there is nothing left to disagree about — and a conflict
        // that outlived its cause would block `retryPending` indefinitely.
        // Cleared only once the local read, the registration and the probe have
        // all come back, so a failed probe never costs a live token.
        retained = nil

        switch probe {
        case .unreachable:
            return try offlineDecision(local)
        case .absent:
            return try await remoteAbsentDecision(local)
        case let .present(record, bytes, hash):
            return try await remotePresentDecision(local, record: record,
                                                   bytes: bytes, hash: hash)
        }
    }

    /// The server could not be reached. Not the same as it having no card.
    private func offlineDecision(_ local: LocalCard) throws -> PS1SaveLaunchDecision {
        guard case let .present(_, localHash) = local else {
            // No card here. If one was ever synchronized, it exists somewhere and
            // a blank launch would eventually replace it.
            guard baseline == nil else {
                publish(.failed)
                throw PS1SaveSyncError.serverUnreachableWithMissingCard
            }
            publish(.idle)
            return .ready
        }
        // Local bytes in hand: play offline. Anything not known to match the
        // baseline is owed to the server.
        if baseline?.hash == localHash {
            publish(.idle)
        } else {
            setPending(true)
            publish(.pending)
        }
        return .ready
    }

    /// The server answered, and has no active card for this game.
    private func remoteAbsentDecision(_ local: LocalCard) async throws -> PS1SaveLaunchDecision {
        switch local {
        case .absent:
            // Neither side has one. A baseline pointing at a card that is gone
            // from both places is stale; keeping it would make the next offline
            // launch refuse for a card nobody has.
            clearBaseline()
            setPending(false)
            publish(.idle)
            return .ready
        case let .present(bytes, hash):
            // Whether it changed or not: the server has nothing, so send it.
            return await upload(bytes, hash: hash, replacing: nil)
        }
    }

    /// The server answered with a card.
    private func remotePresentDecision(_ local: LocalCard, record: RommSave,
                                       bytes: Data, hash: String) async throws
    -> PS1SaveLaunchDecision {
        guard case let .present(localBytes, localHash) = local else {
            // Nothing here, something there — restore it, baseline or not, and
            // whether or not it changed.
            try writeLocal(bytes)
            adopt(hash: hash, record: record)
            return .ready
        }
        if localHash == hash {
            // Equal. No write on either side; this is the launch that costs
            // nothing but the comparison.
            adopt(hash: hash, record: record)
            return .ready
        }
        guard let baseline else {
            // Two different cards and no history saying which came from which.
            return .conflict(retainConflict(localBytes: localBytes, localHash: localHash,
                                            record: record, remoteBytes: bytes,
                                            remoteHash: hash))
        }
        let localChanged = localHash != baseline.hash
        let remoteChanged = hash != baseline.hash
        if localChanged && remoteChanged {
            return .conflict(retainConflict(localBytes: localBytes, localHash: localHash,
                                            record: record, remoteBytes: bytes,
                                            remoteHash: hash))
        }
        if localChanged {
            return await upload(localBytes, hash: localHash, replacing: record)
        }
        // Only the server's card moved. It wins, atomically.
        try writeLocal(bytes)
        adopt(hash: hash, record: record)
        return .ready
    }

    // MARK: - Conflict resolution

    /// Archives the card that loses, then installs the one that wins.
    ///
    /// The order is the guarantee, and it is not incidental to the control flow —
    /// it *is* the control flow. Stage 1 is a `try await` whose failure returns
    /// from this function, so no statement that replaces a card can be reached
    /// with the loser unarchived. Stage 2 mutates the baseline, the pending flag
    /// and the retained conflict only after it has itself succeeded, so a failure
    /// there leaves this coordinator in exactly the state it started in and the
    /// token still resolvable.
    ///
    /// A retry archives again, under a new slot name, rather than trusting that
    /// the previous archive landed. One redundant copy on the server is a much
    /// cheaper mistake than one missing one.
    public func resolve(_ conflict: PS1SaveConflict, choice: PS1ConflictChoice) async throws {
        guard let held = retained, held.id == conflict.id else {
            throw PS1SaveSyncError.conflictExpired
        }

        // Both originals must still be the ones this token was minted against.
        // The local half matters most for `.remote`, where stage 2 overwrites the
        // local card: a card that changed since the token was issued would be
        // destroyed without ever having been archived.
        let local = try readLocal()
        guard case let .present(localBytes, localHash) = local, localHash == held.localHash else {
            retained = nil
            publish(.failed)
            throw PS1SaveSyncError.conflictExpired
        }
        let probe = try await probeRemote()
        if case .unreachable = probe {
            // Nothing was asked of the server and nothing was replaced. The two
            // cards are still the ones this token names, so it stays valid — a
            // blip while the chooser is on screen must not make the player start
            // over.
            publish(.conflict)
            throw PS1SaveSyncError.serverUnreachableDuringResolution
        }
        guard case let .present(record, remoteBytes, remoteHash) = probe,
              record.id == held.remoteID, remoteHash == held.remoteHash else {
            retained = nil
            if case let .present(record, remoteBytes, remoteHash) = probe {
                _ = retainConflict(localBytes: localBytes, localHash: localHash,
                                   record: record, remoteBytes: remoteBytes,
                                   remoteHash: remoteHash)
            } else {
                publish(.failed)
            }
            throw PS1SaveSyncError.conflictExpired
        }

        // ---- Stage 1: preserve the loser. Required. -------------------------
        let loser = choice == .local ? remoteBytes : localBytes
        do {
            _ = try await create(loser, slot: archiveSlot(), autocleanup: false)
        } catch {
            publish(.conflict)
            throw PS1SaveSyncError.archiveFailed(cause(of: error))
        }

        // ---- Stage 2: install the winner. ------------------------------------
        // Nothing below this line runs unless the archive above returned.
        switch choice {
        case .local:
            let created: RommSave
            do {
                created = try await create(localBytes, slot: Self.activeSlot, autocleanup: true)
            } catch {
                publish(.conflict)
                throw PS1SaveSyncError.conflictNotResolved(cause(of: error))
            }
            guard isAuthoritative(created, replacing: record) else {
                publish(.conflict)
                // Not a failure the server reported: it accepted the upload and
                // answered with a row older than the one being replaced.
                throw PS1SaveSyncError.conflictNotResolved(.serverKeptAnOlderVersion)
            }
            setBaseline(hash: localHash, record: created)
        case .remote:
            do {
                try localStore.save(remoteBytes, romID: canonicalRomID)
            } catch {
                publish(.conflict)
                // This device, not the server. Advice about a connection here is
                // the defect this classification exists to remove.
                throw PS1SaveSyncError.conflictNotResolved(.localWriteFailed)
            }
            setBaseline(hash: remoteHash, record: record)
        }

        retained = nil
        pendingBytes = nil
        pendingHash = nil
        setPending(false)
        publish(.synced)
    }

    // MARK: - Uploading during play

    /// Records a newer card and arms the debounce. Cheap and non-blocking: this
    /// is called from the emulator's flush, which runs on the main thread.
    ///
    /// **The caller must have written these bytes to `localStore` first, and only
    /// call this if that write succeeded.** This is a binding rule, not a
    /// convention. `data` is taken at its word and preferred over the stored card
    /// until the upload settles, so bytes that never reached the local file would
    /// be uploaded, clear the pending flag, and record a baseline the local card
    /// does not match — after which the next reconciliation reads "local changed,
    /// remote did not" and uploads the *older* card over the newer remote one.
    /// So the call belongs **inside** the `do` block, after `try save` has
    /// returned, and never on a tick where the write threw. The one caller is
    /// `EmulatorSaveFlow`, which reaches it from the statement after a local
    /// write that returned — and cannot reach it from one that threw.
    ///
    /// The bytes are kept in memory, never in UserDefaults. The *flag* is
    /// persisted, so a cold start after a crash knows there is an upload owed and
    /// re-reads the card from `localStore`.
    public func scheduleUpload(_ data: Data) {
        pendingBytes = data
        pendingHash = Self.sha256(data)
        setPending(true)
        // An outstanding conflict outranks an owed upload in the published
        // vocabulary too. Saying `.pending` here would leave the stream and
        // `status` claiming an upload is on its way while a conflict is waiting on
        // a person, and `flush` returns without publishing anything, so nothing
        // would put it back.
        publish(retained == nil ? .pending : .conflict)
        uploadGeneration &+= 1
        let generation = uploadGeneration
        debounceTask = Task { [weak self, seams] in
            try? await seams.sleep(PS1SaveCoordinator.debounceInterval)
            await self?.debounceElapsed(generation)
        }
    }

    /// Sends whatever is owed, now. Every `RetryReason` bypasses the debounce.
    public func retryPending(reason: RetryReason) async {
        guard retained == nil else {
            // An outstanding conflict outranks a pending upload: uploading now
            // would be choosing a side on the player's behalf. `flush` refuses
            // independently; this is the same rule stated where a reader looks
            // for it.
            publish(.conflict)
            return
        }
        guard isPending else { return }
        // Retire any armed debounce so it cannot fire a second upload behind this
        // one.
        uploadGeneration &+= 1
        await flush()
    }

    private func debounceElapsed(_ generation: Int) async {
        guard generation == uploadGeneration else { return }
        await flush()
    }

    /// Runs at most one upload attempt at a time.
    ///
    /// Actor isolation protects each state *access*; it does not protect a
    /// multi-step operation across its awaits, and `performFlush` suspends twice —
    /// at the probe and at the create. `retryPending(.pause)` followed by
    /// `retryPending(.background)` is an ordinary sequence on tvOS, and the flag is
    /// not cleared until an upload succeeds, so the second call gets past
    /// `guard isPending`. Two flushes then interleave like this:
    ///
    /// 1. the first lists and downloads the active record and finds it matches the
    ///    baseline;
    /// 2. the second lists and downloads the same record;
    /// 3. the first creates a newer record and moves the baseline onto it;
    /// 4. the second resumes and compares the record it downloaded against the
    ///    baseline the first one just wrote — they differ, so it publishes a
    ///    conflict between the player's current card and a stale copy of that same
    ///    card.
    ///
    /// Choosing `remote` there archives the live card and writes the stale one
    /// over it: a session silently reverted, recoverable only out of a
    /// `conflict-` slot.
    ///
    /// So a second caller **waits out** whatever is in flight and then does its
    /// own pass. It must not simply absorb into the running one and return:
    /// `settlePending` is exactly the success-with-work-still-owed branch, so the
    /// flush being waited on can finish having left a *newer* card owed — and both
    /// callers that get here have already retired the trigger that would have sent
    /// it (`retryPending` bumps `uploadGeneration` on the way in, and a debounce
    /// firing is consumed). Absorbing would leave the newest card on disk, flagged,
    /// with nothing scheduled to send it: a silent stall on the quit path whenever
    /// a flush is in flight.
    ///
    /// The loop terminates because each pass either clears the flag or returns at
    /// `performFlush`'s own `isPending` guard, and it cannot spin: the slot is
    /// released *inside* the task, so a waiter woken by a task's completion is
    /// guaranteed to observe the slot already empty rather than re-observing a
    /// finished task while its owner is still queued to clear it. Mutual exclusion
    /// is unchanged — there is no suspension point between the final `flushTask`
    /// check and the assignment, so two callers cannot both find it empty.
    private func flush() async {
        while let existing = flushTask { await existing.value }
        let task = Task { await self.runFlush() }
        flushTask = task
        await task.value
    }

    /// One flush plus the release of the in-flight slot, as one task. See
    /// `flush()` for why the release lives in here rather than after the await.
    private func runFlush() async {
        await performFlush()
        flushTask = nil
    }

    /// One upload attempt for the pending card. Only ever entered through
    /// `flush()`, which serializes it.
    ///
    /// Reloads the active record first and compares its bytes to the baseline.
    /// That client-side check — not the server's 409 — is the primary lost-update
    /// detector, which matters because the 409 needs a registered device and
    /// registration is allowed to fail. The 409 remains the backstop for the race
    /// between this check and the POST that follows it.
    private func performFlush() async {
        guard isPending, retained == nil else { return }
        // A cold start that retries before it ever prepares a launch would
        // otherwise download and upload anonymously for that whole pass, which
        // costs the server's conflict detection exactly when a crash has just made
        // it most relevant. Idempotent: at most one attempt per instance.
        await ensureDeviceRegistered()
        guard let bytes = loadPendingBytes() else { return }
        let hash = Self.sha256(bytes)
        publish(.syncing)

        let probe: RemoteProbe
        do {
            probe = try await probeRemote()
        } catch {
            // Including HTTP and decode failures: an upload never blocks play, so
            // there is nothing to raise this to. It stays owed.
            publish(.failed)
            return
        }

        var replacing: RommSave?
        switch probe {
        case .unreachable:
            publish(.failed)
            return
        case .absent:
            replacing = nil
        case let .present(record, remoteBytes, remoteHash):
            if remoteHash == hash {
                // Someone already put exactly these bytes there.
                setBaseline(hash: hash, record: record)
                settlePending(uploaded: hash)
                return
            }
            // A remote card that does not match the baseline is a card written
            // since this device last synchronized. With no baseline at all, any
            // remote card is unaccounted for and gets the same treatment — that is
            // what stops a blank offline first launch from later erasing a card
            // this device has never seen.
            guard remoteHash == baseline?.hash else {
                _ = retainConflict(localBytes: bytes, localHash: hash, record: record,
                                   remoteBytes: remoteBytes, remoteHash: remoteHash)
                return
            }
            replacing = record
        }

        do {
            let created = try await create(bytes, slot: Self.activeSlot, autocleanup: true)
            guard isAuthoritative(created, replacing: replacing) else {
                publish(.failed)
                return
            }
            setBaseline(hash: hash, record: created)
            settlePending(uploaded: hash)
        } catch RommError.http(409) {
            // The server is saying another device wrote since this one last
            // synchronized. That is a conflict, not a failure: neither card is
            // overwritten and both byte sequences survive.
            await conflictFrom409(localBytes: bytes, localHash: hash)
        } catch {
            publish(.failed)
        }
    }

    /// Clears the owed-upload flag only if what went out is still the newest card
    /// this device has. A card that arrived mid-upload keeps the flag set and is
    /// sent by the debounce its own `scheduleUpload` armed.
    private func settlePending(uploaded hash: String) {
        guard pendingHash == nil || pendingHash == hash else {
            publish(.pending)
            return
        }
        pendingBytes = nil
        pendingHash = nil
        setPending(false)
        publish(.synced)
    }

    @discardableResult
    private func conflictFrom409(localBytes: Data,
                                 localHash: String) async -> PS1SaveConflict? {
        guard let probe = try? await probeRemote(),
              case let .present(record, remoteBytes, remoteHash) = probe else {
            // A 409 with nothing to show for it — the row that caused it is gone,
            // or unreadable, or the server is now unreachable. Nothing was
            // written; the card is still owed and still here.
            publish(.failed)
            return nil
        }
        return retainConflict(localBytes: localBytes, localHash: localHash, record: record,
                              remoteBytes: remoteBytes, remoteHash: remoteHash)
    }

    /// The bytes to upload: the newest this instance was handed, or — after a cold
    /// start, where the flag survived but the bytes did not — whatever
    /// `localStore` holds. Never a fabricated blank card.
    private func loadPendingBytes() -> Data? {
        if let pendingBytes { return pendingBytes }
        do {
            guard let stored = try localStore.load(romID: canonicalRomID) else {
                // Owed an upload with no card to send. Uploading nothing here is
                // exactly the blank-card overwrite this file exists to prevent.
                publish(.failed)
                return nil
            }
            return stored
        } catch {
            publish(.failed)
            return nil
        }
    }

    // MARK: - Remote reads

    private enum RemoteProbe {
        case present(record: RommSave, bytes: Data, hash: String)
        case absent
        case unreachable
    }

    private enum LocalCard {
        case present(Data, String)
        case absent
    }

    /// The active card on the server, or why there isn't one.
    ///
    /// `unreachable` is returned for connectivity failures and nothing else.
    /// HTTP status, authentication and decoding failures are thrown, because
    /// "your token expired" answered as "you are offline" is how a client decides
    /// the server has no card.
    private func probeRemote() async throws -> RemoteProbe {
        let saves: [RommSave]
        do {
            saves = try await seams.listSaves(canonicalRomID)
        } catch {
            if seams.isConnectivityError(error) { return .unreachable }
            throw error
        }
        guard let record = Self.selectActive(from: saves, romID: canonicalRomID) else {
            return .absent
        }
        let bytes: Data
        do {
            bytes = try await seams.downloadSave(record.id, registeredDeviceID)
        } catch {
            if seams.isConnectivityError(error) { return .unreachable }
            throw error
        }
        return .present(record: record, bytes: bytes, hash: Self.sha256(bytes))
    }

    /// What a server call that threw was actually complaining about.
    ///
    /// Connectivity is tested first and by the same seam `probeRemote` uses, so
    /// one rule decides "the device is offline" everywhere in this file. The rest
    /// preserves what the layer below already knew: `RommClient` throws
    /// `RommError.http` with the status and `RommError.badResponse` for a
    /// non-HTTP answer, and `JSONDecoder` throws `DecodingError` — all three
    /// reach here verbatim, and all three mean different things to a player.
    private func cause(of error: Error) -> PS1SaveSyncCause {
        if seams.isConnectivityError(error) { return .serverUnreachable }
        if let romm = error as? RommError {
            switch romm {
            case .badResponse:
                return .unreadableAnswer
            case let .http(status):
                switch status {
                case 401, 403: return .tokenRejected
                // The same status `performFlush` and `upload` both treat as a
                // conflict rather than a failure. Rare here — stage 1 uploads to
                // a slot no other writer uses — but "check your server's logs"
                // is the wrong sentence for another Apple TV having saved.
                case 409: return .anotherDeviceWrote
                default: return .serverError(status: status)
                }
            }
        }
        if error is DecodingError { return .unreadableAnswer }
        return .other
    }

    /// The active card among everything the server holds for this ROM.
    ///
    /// The filter is `slot "0"` plus this client's memory-card filename plus a
    /// file that is actually on disk. Two things are deliberately *not* in it:
    ///
    /// - **`originDeviceID`.** Selecting only this device's own rows would hide
    ///   the card another Apple TV wrote, and a card that cannot be seen is a card
    ///   that cannot be compared, archived or won against. The whole point of
    ///   synchronizing is that the other device's card is visible here.
    /// - **`emulator`.** RomM does not identify a save by it, and excluding a row
    ///   on it would silently outrank a card written under a different spelling.
    ///   It is still sent on every upload; it is just not a selection predicate.
    ///
    /// Archive slots are excluded because they are not slot `"0"` — the exclusion
    /// is the equality, not a separate prefix check, so an archive can never be
    /// selected however it is named.
    ///
    /// At most one row is expected. Selection is still deterministic — newest
    /// `updated_at`, then highest id — rather than asserting uniqueness, because
    /// how many rows a slot holds is the server's business and has changed
    /// between RomM versions.
    static func selectActive(from saves: [RommSave], romID: Int) -> RommSave? {
        saves
            .filter { $0.romID == romID }
            .filter { $0.slot == activeSlot }
            .filter { !$0.missingFromFS }
            .filter { isMemoryCardFileName($0.fileName) }
            .max { left, right in
                let leftDate = parseTimestamp(left.updatedAt) ?? .distantPast
                let rightDate = parseTimestamp(right.updatedAt) ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return left.id < right.id
            }
    }

    /// Whether a server-side filename is this client's memory card.
    ///
    /// RomM rewrites a slotted upload's filename to
    /// `"<stem> [YYYY-MM-DD_HH-MM-SS].<ext>"`, so an equality test against the
    /// constant matches nothing that was ever actually stored. Both spellings are
    /// accepted; nothing else is, which is what keeps some other client's save
    /// from being adopted as a PlayStation memory card and written over the real
    /// one.
    static func isMemoryCardFileName(_ name: String) -> Bool {
        let constant = RommClient.memoryCardFileName
        if name == constant { return true }
        let stem = (constant as NSString).deletingPathExtension
        let ext = (constant as NSString).pathExtension
        guard name.hasSuffix("." + ext) else { return false }
        let body = String(name.dropLast(ext.count + 1))
        guard body.hasPrefix(stem + " ["), body.hasSuffix("]") else { return false }
        let tag = body.dropFirst(stem.count + 2).dropLast()
        // `2026-03-01_10-00-00`
        return tag.count == 19 && tag.allSatisfy { $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// RomM sends naive UTC (`2026-03-01T10:00:00`), sometimes with fractional
    /// seconds, sometimes with an offset. Unparseable is not fatal anywhere it is
    /// used — ordering falls back to the record id, and a conflict screen shows no
    /// date rather than a wrong one.
    static func parseTimestamp(_ value: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static let timestampFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
         "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
         "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    // MARK: - Local reads and writes

    private func readLocal() throws -> LocalCard {
        do {
            guard let bytes = try localStore.load(romID: canonicalRomID) else { return .absent }
            return .present(bytes, Self.sha256(bytes))
        } catch {
            // Emphatically not `.absent`.
            publish(.failed)
            throw PS1SaveSyncError.localCardUnreadable
        }
    }

    private func writeLocal(_ bytes: Data) throws {
        do {
            try localStore.save(bytes, romID: canonicalRomID)
        } catch {
            publish(.failed)
            throw PS1SaveSyncError.localCardNotWritable
        }
    }

    private func localModifiedAt() -> Date? {
        (localStore as? any SaveRAMModificationDating)?.modificationDate(romID: canonicalRomID)
    }

    // MARK: - Remote writes

    private func create(_ bytes: Data, slot: String, autocleanup: Bool) async throws -> RommSave {
        try await seams.createSave(PS1SaveUploadRequest(
            romID: canonicalRomID,
            emulator: Self.emulator,
            slot: slot,
            deviceID: registeredDeviceID,
            data: bytes,
            autocleanup: autocleanup,
            autocleanupLimit: Self.activeSlotRetention))
    }

    /// Whether a create actually became the newest row in the slot.
    ///
    /// RomM deduplicates a slot upload against any row in that slot with the same
    /// content hash and returns *that* row, writing nothing. For a genuine no-op
    /// that is free and welcome. But when the card has gone back to bytes an older
    /// row already holds, the row that comes back is behind the one that was
    /// newest, and believing it would file a baseline the server disagrees with —
    /// after which the next reconciliation would see "only the server changed" and
    /// overwrite the player's card without archiving it.
    ///
    /// So a create is only believed when it outranks the row it was meant to
    /// replace. Refusing here is a visible stalled sync; accepting would be a
    /// silent loss.
    private func isAuthoritative(_ created: RommSave, replacing previous: RommSave?) -> Bool {
        guard let previous else { return true }
        return created.id > previous.id
    }

    /// `conflict-<timestamp>-<suffix>`, from the injected clock and the injected
    /// suffix. Both halves matter: the timestamp makes an archive findable, and
    /// the suffix is why two attempts a second apart cannot land in one slot and
    /// have the second dedupe against the first.
    private func archiveSlot() -> String {
        Self.conflictSlotPrefix + Self.slotTimestamp.string(from: seams.now())
            + "-" + seams.uniqueSuffix()
    }

    private static let slotTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    // MARK: - Deciding to upload

    private func upload(_ bytes: Data, hash: String,
                        replacing: RommSave?) async -> PS1SaveLaunchDecision {
        setPending(true)
        publish(.pending)
        publish(.syncing)
        do {
            let created = try await create(bytes, slot: Self.activeSlot, autocleanup: true)
            guard isAuthoritative(created, replacing: replacing) else {
                publish(.failed)
                return .ready
            }
            setBaseline(hash: hash, record: created)
            pendingBytes = nil
            pendingHash = nil
            setPending(false)
            publish(.synced)
            return .ready
        } catch RommError.http(409) {
            if let conflict = await conflictFrom409(localBytes: bytes, localHash: hash) {
                return .conflict(conflict)
            }
            return .ready
        } catch {
            // A failed upload never blocks play. The card is local, intact, owed.
            publish(.failed)
            return .ready
        }
    }

    // MARK: - Conflict bookkeeping

    private func retainConflict(localBytes: Data, localHash: String, record: RommSave,
                                remoteBytes: Data, remoteHash: String) -> PS1SaveConflict {
        let token = PS1SaveConflict(id: UUID(),
                                    localModifiedAt: localModifiedAt(),
                                    remoteModifiedAt: Self.parseTimestamp(record.updatedAt))
        retained = RetainedConflict(id: token.id, localBytes: localBytes, localHash: localHash,
                                    remoteID: record.id, remoteHash: remoteHash,
                                    remoteBytes: remoteBytes)
        // The local card is unsynchronized by definition while this stands.
        setPending(true)
        publish(.conflict)
        return token
    }

    // MARK: - Status

    /// Where synchronization stands right now, for an observer that attached
    /// after the fact. `statuses` publishes *changes*; a repeat of the status
    /// already showing is suppressed, so this is the value to read on appearance.
    public var status: PS1SaveSyncStatus { lastPublished ?? .idle }

    private func publish(_ status: PS1SaveSyncStatus) {
        guard status != lastPublished else { return }
        lastPublished = status
        publishedCount += 1
        continuation.yield(status)
    }

    /// How many statuses have actually been yielded. Module-internal, and it
    /// exists so a test can wait for its consumer to have received exactly what
    /// was produced rather than guessing with sleeps.
    private(set) var publishedCount = 0

    // MARK: - Persisted synchronization metadata

    private enum Keys {
        static let installIdentifier = "ps1sync.device.installIdentifier"
        static let deviceID = "ps1sync.device.id"
        static let registrationFailed = "ps1sync.device.registrationFailed"
        static func baselineHash(_ romID: Int) -> String { "ps1sync.rom.\(romID).baselineHash" }
        static func baselineRemoteID(_ romID: Int) -> String {
            "ps1sync.rom.\(romID).baselineRemoteID"
        }
        static func baselineAt(_ romID: Int) -> String { "ps1sync.rom.\(romID).baselineAt" }
        static func remoteUpdatedAt(_ romID: Int) -> String {
            "ps1sync.rom.\(romID).remoteUpdatedAt"
        }
        static func pending(_ romID: Int) -> String { "ps1sync.rom.\(romID).pending" }
    }

    private var baseline: Baseline? {
        guard let hash = defaults.string(forKey: Keys.baselineHash(canonicalRomID)),
              !hash.isEmpty,
              let remoteID = defaults.object(forKey: Keys.baselineRemoteID(canonicalRomID)) as? Int
        else { return nil }
        return Baseline(hash: hash, remoteID: remoteID)
    }

    /// A new baseline is only ever recorded here, and every caller reaches it
    /// having just confirmed equality, written the local card, or had an upload
    /// accepted. There is no path that records one hopefully.
    private func setBaseline(hash: String, record: RommSave) {
        defaults.set(hash, forKey: Keys.baselineHash(canonicalRomID))
        defaults.set(record.id, forKey: Keys.baselineRemoteID(canonicalRomID))
        defaults.set(record.updatedAt, forKey: Keys.remoteUpdatedAt(canonicalRomID))
        defaults.set(seams.now().timeIntervalSince1970, forKey: Keys.baselineAt(canonicalRomID))
    }

    private func clearBaseline() {
        defaults.removeObject(forKey: Keys.baselineHash(canonicalRomID))
        defaults.removeObject(forKey: Keys.baselineRemoteID(canonicalRomID))
        defaults.removeObject(forKey: Keys.remoteUpdatedAt(canonicalRomID))
        defaults.removeObject(forKey: Keys.baselineAt(canonicalRomID))
    }

    /// Confirmed equal, or written: record the baseline and settle.
    private func adopt(hash: String, record: RommSave) {
        setBaseline(hash: hash, record: record)
        pendingBytes = nil
        pendingHash = nil
        setPending(false)
        publish(.synced)
    }

    var isPending: Bool { defaults.bool(forKey: Keys.pending(canonicalRomID)) }

    private func setPending(_ value: Bool) {
        defaults.set(value, forKey: Keys.pending(canonicalRomID))
    }

    // MARK: - Digest

    /// The one SHA-256 in this file. Local bytes and downloaded bytes go through
    /// it and nothing else; the server's own `content_hash` is an MD5 it computes
    /// for deduplication and is never the oracle for whether two cards differ.
    static func sha256(_ data: Data) -> String {
        var characters = ""
        characters.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            characters += String(format: "%02x", byte)
        }
        return characters
    }

    // MARK: - Test support

    /// Awaits the armed debounce, if any, so a test can assert on what it did
    /// without sleeping. Not part of the shipping surface.
    func drainDebounce() async {
        await debounceTask?.value
    }
}

import Combine
import Foundation

// MARK: - What a launch is

/// The two kinds of launch this app knows how to prepare.
///
/// There are exactly two cases and there will not be a third without a
/// deliberate decision: every platform that works today is `.legacy` — one file,
/// downloaded, handed to a core — and PlayStation is the one platform that needs
/// a directory, a playlist, a BIOS and a memory card reconciled before the core
/// may see it. Anything that blurs the two would put a legacy game on the
/// PlayStation path, which is the regression this whole boundary exists to make
/// impossible.
public enum LaunchRequest: Sendable {
    case legacy(rom: Rom, core: CoreDescriptor)
    case playStation(game: PS1Game, platformID: Int)
}

/// Everything the emulator needs, and nothing about how it was obtained.
///
/// `EmulatorHostView` and `EmulatorEngine` are initialized from this value
/// alone. They never see a `RommClient`, a platform id, a sibling list or a
/// package layout, so there is no second place where "which file do I load" or
/// "which ROM id owns this save" can be decided differently.
public struct PreparedLaunch: Sendable {
    /// The file handed to `LibretroCore.loadGame` — a ROM for legacy, the
    /// generated `game.m3u` for PlayStation.
    public let entryURL: URL
    public let core: CoreDescriptor
    /// The directory the core reads firmware from. `Caches/system` for legacy,
    /// `PS1FirmwareManager.systemDirectory` for PlayStation. Both are inside
    /// Caches, which is the only place besides tmp a tvOS app may write.
    public let systemDirectory: URL
    /// The directory the core writes its own save files into. Per-game for
    /// PlayStation, because every prepared package's playlist is named
    /// `game.m3u` and Beetle PSX derives its memory-card filename from that —
    /// one shared directory would give every PlayStation game the same card.
    public let saveDirectory: URL
    /// The ROM id that owns this session's save identity: disc 1 of a recognized
    /// disc set, or the ROM itself.
    public let canonicalRomID: Int
    public let saveStore: any SaveRAMStoring
    /// Disc labels in playlist order, empty for a single-disc or legacy launch.
    ///
    /// - Important: This is the **only** authority for "this session has more
    ///   than one disc". `LibretroCore.discCount` is not: Genesis Plus GX
    ///   registers a Disk Control interface too, so a Sega CD launch reports a
    ///   non-zero disc count while `discLabels` is correctly empty. Any UI that
    ///   offers disc switching must read this, and Task 12's picker additionally
    ///   requires the two to agree before it indexes one by the other.
    public let discLabels: [String]
    /// Called after a memory card has been **successfully written to
    /// `saveStore`**, never before.
    ///
    /// - Important: This is a binding precondition, not a convention.
    ///   `PS1SaveCoordinator.scheduleUpload` takes these bytes at their word and
    ///   prefers them over the stored card until the upload settles, so bytes
    ///   that never reached the local file would be uploaded, clear the pending
    ///   flag, and record a baseline the local card does not match — after which
    ///   the next reconciliation reads "local changed, remote did not" and
    ///   uploads the *older* card over the newer remote one. The call belongs
    ///   inside the `do` block, after `try saveStore.save(…)` has returned, and
    ///   never on a tick where that write threw. A no-op on the legacy path.
    public let onLocalSave: @Sendable (Data) -> Void
    /// Sends whatever the card owes the server now, bypassing the debounce. A
    /// no-op on the legacy path.
    public let retrySaveSync: @Sendable (RetryReason) -> Void
    /// The coordinator's sanitized status stream, or `nil` for a legacy launch,
    /// which has no server-side save at all.
    public let saveStatuses: AsyncStream<PS1SaveSyncStatus>?

    public init(entryURL: URL,
                core: CoreDescriptor,
                systemDirectory: URL,
                saveDirectory: URL,
                canonicalRomID: Int,
                saveStore: any SaveRAMStoring,
                discLabels: [String],
                onLocalSave: @escaping @Sendable (Data) -> Void,
                retrySaveSync: @escaping @Sendable (RetryReason) -> Void,
                saveStatuses: AsyncStream<PS1SaveSyncStatus>?) {
        self.entryURL = entryURL
        self.core = core
        self.systemDirectory = systemDirectory
        self.saveDirectory = saveDirectory
        self.canonicalRomID = canonicalRomID
        self.saveStore = saveStore
        self.discLabels = discLabels
        self.onLocalSave = onLocalSave
        self.retrySaveSync = retrySaveSync
        self.saveStatuses = saveStatuses
    }
}

/// What one preparation attempt concluded. A conflict is not a failure: nothing
/// has been written on either side and only a person can say which card is
/// theirs.
public enum LaunchPreparationDecision: Sendable {
    case ready(PreparedLaunch)
    case conflict(PS1SaveConflict)
}

/// The package a PlayStation preparation produced, in the terms the launch
/// boundary needs.
///
/// Deliberately not `PS1PreparedPackage`: that type's initializer is internal to
/// this module, and this value has to be constructible by anything that
/// satisfies the preparation seam — a test double, or the argument-gated UI-test
/// fixture, which lives in the app target.
public struct PreparedDiscSet: Sendable, Equatable {
    /// The playlist the core is handed — `game.m3u` inside the package.
    public let entryURL: URL
    public let canonicalRomID: Int
    /// Disc labels in playlist order.
    public let discLabels: [String]

    public init(entryURL: URL, canonicalRomID: Int, discLabels: [String]) {
        self.entryURL = entryURL
        self.canonicalRomID = canonicalRomID
        self.discLabels = discLabels
    }
}

// MARK: - Stages

/// The coarse phase a preparation is in.
///
/// `PS1PreparationProgress` says *what* is happening to bytes; it cannot say
/// which phase those bytes belong to, because the package store and the firmware
/// manager both report `.downloading` and `.validating` and neither knows the
/// other exists. The phase is the launch boundary's own knowledge, so it travels
/// on its own channel rather than being guessed from label spellings.
public enum LaunchStage: Sendable, Equatable {
    case checkingCache
    case preparingSave
    case firmware
    case discs
    case validating

    public var title: String {
        switch self {
        case .checkingCache: return "Checking cache"
        case .preparingSave: return "Preparing save"
        case .firmware: return "BIOS"
        case .discs: return "Discs"
        case .validating: return "Validating"
        }
    }
}

/// One throttled view of where preparation stands. Bytes are per-phase: a phase
/// change resets both figures together, so the pair is always internally
/// consistent and a fraction computed from it is never a lie about a total that
/// belongs to something else.
public struct LaunchProgressSnapshot: Sendable, Equatable {
    public var stage: LaunchStage
    /// The disc label or file name currently in flight. Never a path, never a
    /// URL, never a server address.
    public var detail: String
    public var completedBytes: Int64
    public var totalBytes: Int64

    public static let idle = LaunchProgressSnapshot(stage: .checkingCache, detail: "",
                                                    completedBytes: 0, totalBytes: 0)

    public init(stage: LaunchStage, detail: String, completedBytes: Int64, totalBytes: Int64) {
        self.stage = stage
        self.detail = detail
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    /// `nil` when the total is not known, which is what an indeterminate bar is
    /// for. Never negative and never above 1.
    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// The one line that names what is happening. A disc phase says which disc,
    /// because "Discs" alone tells a player nothing they cannot already see.
    public var headline: String {
        if stage == .discs, !detail.isEmpty { return detail }
        return stage.title
    }

    /// The newer of two snapshots, with byte progress pinned monotonic.
    ///
    /// Publications cross a thread boundary and can therefore arrive out of the
    /// order they were produced in. Within one phase and one total, a snapshot
    /// that would move `completedBytes` backwards is merged rather than
    /// accepted, so a progress bar never retreats. A phase change — which is
    /// exactly the case where the totals describe different work — replaces both
    /// figures.
    public static func merged(_ incoming: LaunchProgressSnapshot,
                              into current: LaunchProgressSnapshot) -> LaunchProgressSnapshot {
        guard incoming.stage == current.stage, incoming.totalBytes == current.totalBytes else {
            return incoming
        }
        var merged = incoming
        merged.completedBytes = max(current.completedBytes, incoming.completedBytes)
        return merged
    }
}

/// Collects byte-level progress and lets at most one publication out per
/// interval.
///
/// The downloader validates every chunk and reports every 64 KiB, which for a
/// 480 MB disc is roughly 7,500 callbacks. Each one arrives on whatever thread
/// the transfer is running on. Forwarding them individually to a `@Published`
/// property would put 7,500 hops on the main actor for a bar that cannot show
/// more than a few hundred distinct positions — so the value is *stored* on
/// every callback and *published* on a timer, and the transfer keeps checking
/// every chunk regardless.
///
/// `@unchecked Sendable` is earned by `lock`: every stored property is read and
/// written inside it, and the publish closure is called outside it so a
/// downstream hop can never deadlock against a concurrent report.
final class LaunchProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let publish: @Sendable (LaunchProgressSnapshot) -> Void
    private var pending: LaunchProgressSnapshot
    private var lastPublishedAt: TimeInterval?
    private var isDirty = false

    init(interval: TimeInterval = LaunchPreparationModel.defaultThrottleInterval,
         now: @escaping @Sendable () -> TimeInterval = LaunchPreparationModel.monotonicSeconds,
         publish: @escaping @Sendable (LaunchProgressSnapshot) -> Void) {
        self.interval = interval
        self.now = now
        self.publish = publish
        self.pending = .idle
    }

    /// A phase change is rare and is published immediately: it is the whole
    /// sentence on screen, and holding it back for the throttle interval would
    /// leave "Preparing save" up while the BIOS is transferring. Byte figures
    /// reset with it, because the incoming phase's total is not known yet and
    /// the outgoing phase's is about something else.
    func setStage(_ stage: LaunchStage) {
        lock.lock()
        guard pending.stage != stage else { lock.unlock(); return }
        pending = LaunchProgressSnapshot(stage: stage, detail: "",
                                         completedBytes: 0, totalBytes: 0)
        let snapshot = pending
        lastPublishedAt = now()
        isDirty = false
        lock.unlock()
        publish(snapshot)
    }

    func report(_ progress: PS1PreparationProgress) {
        lock.lock()
        switch progress {
        case .planning:
            pending.detail = ""
        case .checkingSpace:
            // The required figure is a preflight, not progress. Naming it here
            // would put a byte count on screen that never advances.
            pending.detail = ""
        case let .downloading(label, completed, total):
            pending.detail = label
            if total == pending.totalBytes {
                pending.completedBytes = max(pending.completedBytes, completed)
            } else {
                pending.totalBytes = total
                pending.completedBytes = completed
            }
        case let .validating(label):
            pending.detail = label
        case .promoting:
            pending.detail = ""
        }
        isDirty = true
        let moment = now()
        let due = lastPublishedAt.map { moment - $0 >= interval } ?? true
        guard due else { lock.unlock(); return }
        lastPublishedAt = moment
        isDirty = false
        let snapshot = pending
        lock.unlock()
        publish(snapshot)
    }

    /// Publishes whatever the throttle is holding, if anything. Called when an
    /// attempt ends so the last position is never the one the timer swallowed.
    func flush() {
        lock.lock()
        guard isDirty else { lock.unlock(); return }
        isDirty = false
        lastPublishedAt = now()
        let snapshot = pending
        lock.unlock()
        publish(snapshot)
    }
}

// MARK: - Dependencies

/// The legacy route's seams. Three URLs and one store: nothing here reaches the
/// network until `download` is called, and nothing here is PlayStation.
public struct LegacyLaunchDependencies: Sendable {
    /// `CacheManager.download(_:progress:)`. The progress argument is the
    /// existing fraction, unchanged.
    public var download: @Sendable (Rom, @escaping @Sendable (Double) -> Void) async throws -> URL
    public var systemDirectory: URL
    public var saveDirectory: URL
    public var saveStore: any SaveRAMStoring

    public init(download: @escaping @Sendable (Rom, @escaping @Sendable (Double) -> Void)
                    async throws -> URL,
                systemDirectory: URL,
                saveDirectory: URL,
                saveStore: any SaveRAMStoring) {
        self.download = download
        self.systemDirectory = systemDirectory
        self.saveDirectory = saveDirectory
        self.saveStore = saveStore
    }
}

/// The PlayStation route's seams, one per stage in the order they run.
///
/// Closures rather than the three actors themselves, for the same reason
/// `PS1SaveCoordinator` takes `PS1SaveSeams`: the boundary's job is ordering and
/// cancellation, and it should be provable without a network, a BIOS image or a
/// real memory card. `LaunchPreparationDependencies.live` is the only place the
/// real `PS1SaveCoordinator`, `PS1FirmwareManager` and `PS1PackageStore` are
/// wired to them.
public struct PlayStationLaunchDependencies: Sendable {
    /// `PS1SaveCoordinator.reconcileBeforeLaunch()`.
    public var reconcileSave: @Sendable () async throws -> PS1SaveLaunchDecision
    /// `PS1SaveCoordinator.resolve(_:choice:)`.
    public var resolveConflict: @Sendable (PS1SaveConflict, PS1ConflictChoice) async throws -> Void
    /// `PS1FirmwareManager.prepare(platformID:regions:progress:)`, answering the
    /// directory the core reads its BIOS from.
    public var prepareFirmware: @Sendable (
        Int, [String], @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> URL
    /// `PS1PackageStore.prepare(_:progress:)`.
    public var preparePackage: @Sendable (
        PS1Game, @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> PreparedDiscSet
    public var saveDirectory: URL
    /// The same local card area the coordinator reconciled against.
    public var saveStore: any SaveRAMStoring
    public var onLocalSave: @Sendable (Data) -> Void
    public var retrySaveSync: @Sendable (RetryReason) -> Void
    public var saveStatuses: AsyncStream<PS1SaveSyncStatus>?

    public init(
        reconcileSave: @escaping @Sendable () async throws -> PS1SaveLaunchDecision,
        resolveConflict: @escaping @Sendable (PS1SaveConflict, PS1ConflictChoice) async throws
            -> Void,
        prepareFirmware: @escaping @Sendable (
            Int, [String], @escaping @Sendable (PS1PreparationProgress) -> Void
        ) async throws -> URL,
        preparePackage: @escaping @Sendable (
            PS1Game, @escaping @Sendable (PS1PreparationProgress) -> Void
        ) async throws -> PreparedDiscSet,
        saveDirectory: URL,
        saveStore: any SaveRAMStoring,
        onLocalSave: @escaping @Sendable (Data) -> Void,
        retrySaveSync: @escaping @Sendable (RetryReason) -> Void,
        saveStatuses: AsyncStream<PS1SaveSyncStatus>?
    ) {
        self.reconcileSave = reconcileSave
        self.resolveConflict = resolveConflict
        self.prepareFirmware = prepareFirmware
        self.preparePackage = preparePackage
        self.saveDirectory = saveDirectory
        self.saveStore = saveStore
        self.onLocalSave = onLocalSave
        self.retrySaveSync = retrySaveSync
        self.saveStatuses = saveStatuses
    }
}

/// Everything one launch attempt can reach outside itself.
public struct LaunchPreparationDependencies: Sendable {
    public var legacy: LegacyLaunchDependencies
    /// Built only when a PlayStation launch is prepared, and given the game so
    /// the save identity is settled before the coordinator exists.
    ///
    /// A closure and not a value, and that is the whole guarantee behind
    /// "legacy preparation constructs no PlayStation dependency": building these
    /// opens a `PS1PackageStore`, whose initialization deletes every staging
    /// directory under the cache root. A legacy launch that constructed one
    /// would delete a PlayStation preparation running beside it.
    public var makePlayStation: @Sendable (PS1Game) throws -> PlayStationLaunchDependencies

    public init(legacy: LegacyLaunchDependencies,
                makePlayStation: @escaping @Sendable (PS1Game) throws
                    -> PlayStationLaunchDependencies) {
        self.legacy = legacy
        self.makePlayStation = makePlayStation
    }
}

// MARK: - Failures

/// A failure in the two sentences a player can act on, and whether pressing
/// Retry is one of the things they can do.
public struct LaunchFailure: Sendable, Equatable {
    public let message: String
    public let recovery: String?
    /// Whether the screen offers Retry.
    ///
    /// False for exactly one class: a refusal that is a property of the ROM's
    /// own files, which this app will read identically every time — two cue
    /// sheets on one disc, a name that is a path, a cue larger than a cue sheet
    /// can be. Those need the library changed, and the message says so.
    /// Everything else is retryable, including a missing BIOS: adding a file to
    /// RomM does not change the ROM, and `PS1FirmwareError`'s own recovery text
    /// ends "then try again".
    public let isRetryable: Bool

    public init(message: String, recovery: String?, isRetryable: Bool) {
        self.message = message
        self.recovery = recovery
        self.isRetryable = isRetryable
    }
}

/// Turns the typed errors of five layers into two sentences.
///
/// Two rules run through all of it:
///
/// - **Nothing here renders `localizedDescription` for an error that does not
///   conform to `LocalizedError`.** `RommError` and `DecodingError` reach this
///   layer verbatim — `PS1SaveCoordinator.reconcileBeforeLaunch` rethrows an
///   HTTP status and a decode failure as themselves on purpose, so a caller can
///   tell an expired token from a broken server — and their default
///   descriptions are "The operation couldn't be completed. (… error 1.)" and a
///   coding-key dump. Both get a sentence written here instead.
/// - **Nothing here prints an error with `String(describing:)`.** A `URLError`
///   carries the failing URL, which is the player's server address.
public enum LaunchFailurePresenter {

    /// Whether a failure means the device could not reach the server.
    ///
    /// Both branches are needed and neither subsumes the other.
    /// `PS1FirmwareManager.prepare` wraps *transfer*-stage failures in
    /// `PS1FirmwareError.fetchFailed`, whose `.network` payload keeps the
    /// `URLError.Code`; but its *list*-stage failure — the `/api/firmware` call
    /// — escapes untyped as a raw `URLError` or a `RommError`, so a
    /// `catch let error as PS1FirmwareError` arm never sees it. The first branch
    /// classifies the typed one, the second classifies everything else by the
    /// same rule `PS1PackageStore` uses, so one screen speaks for both.
    public static func isConnectivityFailure(_ error: Error) -> Bool {
        if let firmware = error as? PS1FirmwareError { return firmware.isLikelyConnectivityFailure }
        return PS1PackageStore.isLikelyConnectivityError(error)
    }

    static let offlineMessage =
        "RommpleTV cannot reach your RomM server."
    static let offlineRecovery =
        "Check that your Apple TV and your RomM server are on the same network, then try again."

    public static func describe(_ error: Error) -> LaunchFailure {
        if let firmware = error as? PS1FirmwareError { return describe(firmware) }
        if let package = error as? PS1PackageError {
            return LaunchFailure(message: package.errorDescription ?? genericMessage,
                                 recovery: recovery(for: package),
                                 isRetryable: isRetryable(package))
        }
        if let save = error as? PS1SaveSyncError {
            return LaunchFailure(message: save.errorDescription ?? genericMessage,
                                 recovery: save.recoverySuggestion, isRetryable: true)
        }
        if let integrity = error as? FileIntegrityError {
            return LaunchFailure(message: integrity.errorDescription ?? genericMessage,
                                 recovery: integrity.recoverySuggestion, isRetryable: true)
        }
        if let cue = error as? CueSheetError {
            return LaunchFailure(message: cue.errorDescription ?? genericMessage,
                                 recovery: cue.recoverySuggestion, isRetryable: false)
        }
        if let romm = error as? RommError { return describe(romm) }
        if error is DecodingError {
            return LaunchFailure(
                message: "Your RomM server sent an answer RommpleTV could not read.",
                recovery: "This usually means the server is a version RommpleTV does not "
                    + "understand yet.",
                isRetryable: true)
        }
        if let url = error as? URLError { return describe(url) }
        // Last resort. `LocalizedError` conformances in this app are written for
        // players and carry no address, path or token; anything else gets a
        // sentence rather than a debug dump.
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return LaunchFailure(message: message, recovery: localized.recoverySuggestion,
                                 isRetryable: true)
        }
        return LaunchFailure(message: genericMessage, recovery: nil, isRetryable: true)
    }

    static let genericMessage = "RommpleTV could not prepare this game."

    private static func describe(_ error: PS1FirmwareError) -> LaunchFailure {
        let message = error.errorDescription ?? genericMessage
        switch error {
        case .firmwareUnavailable:
            return LaunchFailure(message: message, recovery: error.recoverySuggestion,
                                 isRetryable: true)
        case let .fetchFailed(fileName, reason):
            // `PS1FirmwareError.recoverySuggestion` says "check your connection"
            // for every `fetchFailed`, which is wrong advice for its integrity
            // sub-cases: a file whose bytes do not match the standard image will
            // not start matching because the network improved. Branch on the
            // reason rather than taking the type's own suggestion.
            switch reason {
            case .network:
                return LaunchFailure(message: message, recovery: offlineRecovery,
                                     isRetryable: true)
            case .integrity:
                return LaunchFailure(
                    message: message,
                    recovery: "The copy of \"\(fileName)\" on your RomM server is not the "
                        + "standard image. Replace it with a verified copy, then try again.",
                    isRetryable: true)
            case .other:
                return LaunchFailure(message: message, recovery: "Try again.", isRetryable: true)
            }
        case .installFailed:
            return LaunchFailure(message: message, recovery: error.recoverySuggestion,
                                 isRetryable: true)
        }
    }

    private static func describe(_ error: RommError) -> LaunchFailure {
        switch error {
        case .badResponse:
            return LaunchFailure(
                message: "Your RomM server sent an answer RommpleTV could not read.",
                recovery: "Try again.", isRetryable: true)
        case let .http(status):
            switch status {
            case 401, 403:
                return LaunchFailure(
                    message: "Your RomM server refused this app's access token.",
                    recovery: "Create a fresh token on your RomM server and enter it in "
                        + "Server Settings.", isRetryable: false)
            case 404:
                return LaunchFailure(
                    message: "Your RomM server no longer has this game's files.",
                    recovery: "Rescan your library on the server, then try again.",
                    isRetryable: true)
            default:
                return LaunchFailure(
                    message: "Your RomM server answered with status \(status).",
                    recovery: "Try again. If it keeps happening, check your server's logs.",
                    isRetryable: true)
            }
        }
    }

    private static func describe(_ error: URLError) -> LaunchFailure {
        guard PS1PackageStore.isLikelyConnectivityError(error) else {
            // Deliberately the numeric code and nothing else: `URLError`'s own
            // description embeds the failing URL.
            return LaunchFailure(message: "The transfer failed (network error "
                                    + "\(error.code.rawValue)).",
                                 recovery: "Try again.", isRetryable: true)
        }
        return LaunchFailure(message: offlineMessage, recovery: offlineRecovery,
                             isRetryable: true)
    }

    private static func recovery(for error: PS1PackageError) -> String? {
        switch error {
        case let .insufficientCapacity(required, available):
            _ = (required, available)   // already in the message, to the byte
            return "Delete something from this Apple TV, then try again."
        case .packageDamaged:
            return "Restart RommpleTV, then try again."
        case .stagedFileMissing, .stagedFileWrongSize, .stagedPackageInvalid:
            return "Try again."
        default:
            return "Fix this game's files on your RomM server, then try again."
        }
    }

    /// See `LaunchFailure.isRetryable`.
    private static func isRetryable(_ error: PS1PackageError) -> Bool {
        switch error {
        case .noDiscs, .duplicateDiscIndex, .noLaunchFile, .unsupportedLaunchFile,
             .multipleLaunchFiles, .multipleSubchannelFiles, .launchFileTooLarge,
             .unsafeRemoteFileName, .remoteFileNameIsAPath, .collidingPackagePaths,
             .duplicateRemoteFile, .emptyPlaylist:
            return false
        case .insufficientCapacity, .stagedFileMissing, .stagedFileWrongSize,
             .stagedPackageInvalid, .packageDamaged:
            return true
        }
    }
}

/// The launch boundary's own refusals. Everything else it raises comes from a
/// layer below it, unchanged.
public enum LaunchPreparationError: Error, Equatable, Sendable, LocalizedError {
    /// A second `prepare` or `resolve` on a service that is already running one.
    /// One service is one attempt; two would write the same staging path.
    case alreadyPreparing
    /// `PlatformSupport` has no core for PlayStation. Unreachable while `psx` is
    /// in the map, and a refusal rather than a hard-coded core name so a map
    /// edit cannot silently launch the wrong emulator.
    case noPlayStationCore

    public var errorDescription: String? {
        switch self {
        case .alreadyPreparing:
            return "RommpleTV is already preparing this game."
        case .noPlayStationCore:
            return "This build of RommpleTV has no PlayStation emulator."
        }
    }
}

// MARK: - The service

/// The one place a launch is prepared, whichever platform it is for.
///
/// Two paths and no third. `.legacy` is the route every accepted platform
/// already uses — `CacheManager` downloads one file, the core reads
/// `Caches/system`, `BatterySaveStore` holds the battery — reached through this
/// boundary but not changed by it: the same download, the same directories, the
/// same store instance, and callbacks that do nothing because there is no
/// server-side save to talk to. `.playStation` is the route Tasks 2–9 built.
///
/// **One service instance per launch attempt.** `prepare` refuses to run twice
/// concurrently, `cancel()` is terminal, and the model that owns it constructs a
/// fresh one for every retry — after awaiting the previous one's cleanup, which
/// is what keeps two attempts from writing one staging path.
public actor LaunchPreparationService {

    /// The RomM slug the PlayStation route is defined by. `ps1` is a stray empty
    /// platform on the live server and is mapped as an alias; `psx` is the one
    /// with the library behind it.
    public static let playStationSlug = "psx"

    private let dependencies: LaunchPreparationDependencies
    private let stageSink: @Sendable (LaunchStage) -> Void
    /// The attempt in flight, so `cancel()` — which cannot be `async` and so
    /// cannot await anything — still has something to interrupt.
    private var work: Task<LaunchPreparationDecision, Error>?
    private var isCancelled = false
    private var suspended: Suspended?

    /// A PlayStation request that stopped at a conflict, held so `resolve` can
    /// continue *it* rather than starting again. The token id is kept beside it
    /// because a caller must not be able to steer this attempt with a token from
    /// somewhere else.
    private struct Suspended {
        let conflictID: UUID
        let game: PS1Game
        let platformID: Int
        let core: CoreDescriptor
        let dependencies: PlayStationLaunchDependencies
    }

    /// - Parameters:
    ///   - dependencies: the two routes' seams.
    ///   - stage: which phase the values passed to `prepare`'s `progress`
    ///     closure belong to. A separate channel because
    ///     `PS1PreparationProgress` has no room for it and the phase is this
    ///     type's knowledge, not the package store's.
    public init(dependencies: LaunchPreparationDependencies,
                stage: @escaping @Sendable (LaunchStage) -> Void = { _ in }) {
        self.dependencies = dependencies
        self.stageSink = stage
    }

    // MARK: Entry points

    public func prepare(
        _ request: LaunchRequest,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> LaunchPreparationDecision {
        try await run { try await self.performPrepare(request, progress: progress) }
    }

    public func resolve(
        _ conflict: PS1SaveConflict,
        choice: PS1ConflictChoice,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> LaunchPreparationDecision {
        try await run { try await self.performResolve(conflict, choice: choice,
                                                      progress: progress) }
    }

    /// Interrupts whatever is in flight and refuses everything afterwards.
    ///
    /// Synchronous by design: the caller that needs to *wait* for cleanup waits
    /// on the `prepare` call itself, which does not return until the work task
    /// has unwound — removing the package store's staging directory and the
    /// downloader's `.part` file on its way out. Cancelling and then awaiting
    /// `prepare` is therefore the whole cleanup protocol, and
    /// `LaunchPreparationModel.cancel()` performs exactly those two steps.
    public func cancel() {
        isCancelled = true
        work?.cancel()
        suspended = nil
    }

    // MARK: Attempt bookkeeping

    /// Runs one attempt inside a task this actor holds, so `cancel()` has
    /// something to cancel, and forwards the caller's own cancellation into it.
    private func run(
        _ body: @escaping @Sendable () async throws -> LaunchPreparationDecision
    ) async throws -> LaunchPreparationDecision {
        if isCancelled { throw CancellationError() }
        guard work == nil else { throw LaunchPreparationError.alreadyPreparing }
        let task = Task { try await body() }
        work = task
        defer { work = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Preparation

    private func performPrepare(
        _ request: LaunchRequest,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> LaunchPreparationDecision {
        switch request {
        case let .legacy(rom, core):
            return .ready(try await prepareLegacy(rom: rom, core: core, progress: progress))
        case let .playStation(game, platformID):
            return try await preparePlayStation(game: game, platformID: platformID,
                                                progress: progress)
        }
    }

    /// The route every accepted platform takes, unchanged.
    ///
    /// Nothing in this function mentions a package, a BIOS, a memory card or a
    /// disc, and `dependencies.makePlayStation` is not called: what a legacy
    /// game downloads, where it saves and how it launches are the same
    /// decisions, made by the same code, that they were before this boundary
    /// existed.
    private func prepareLegacy(
        rom: Rom, core: CoreDescriptor,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> PreparedLaunch {
        let legacy = dependencies.legacy
        stageSink(.checkingCache)
        progress(.planning)
        try Task.checkCancellation()
        // The fraction `CacheManager` reports is turned into the byte pair the
        // shared progress vocabulary speaks. `fs_size_bytes` is the same figure
        // `CacheManager.cachedURL` already validates a cache hit against; when
        // the server omits it the total is zero and the bar is indeterminate,
        // which is the honest answer for a download whose size is unknown.
        let total = max(rom.sizeBytes ?? 0, 0)
        let label = rom.fsName
        let url: URL
        do {
            url = try await legacy.download(rom) { fraction in
                let clamped = min(max(fraction, 0), 1)
                progress(.downloading(label: label,
                                      completed: Int64(clamped * Double(total)),
                                      total: total))
            }
        } catch {
            // Foundation reports a cancelled transfer as `URLError.cancelled`,
            // not as `CancellationError`. Both routes out of this boundary have
            // to spell a cancellation the same way, or a caller that backed out
            // of a cartridge download gets a failure screen while the same
            // decision on a disc gets none.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        return PreparedLaunch(entryURL: url,
                              core: core,
                              systemDirectory: legacy.systemDirectory,
                              saveDirectory: legacy.saveDirectory,
                              canonicalRomID: rom.id,
                              saveStore: legacy.saveStore,
                              discLabels: [],
                              onLocalSave: { _ in },
                              retrySaveSync: { _ in },
                              saveStatuses: nil)
    }

    private func preparePlayStation(
        game: PS1Game, platformID: Int,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> LaunchPreparationDecision {
        guard let core = PlatformSupport.core(forSlug: Self.playStationSlug) else {
            throw LaunchPreparationError.noPlayStationCore
        }
        stageSink(.checkingCache)
        progress(.planning)
        try Task.checkCancellation()
        let playStation = try dependencies.makePlayStation(game)

        // The card first, and this order is the guarantee. A conflict is two
        // memory cards and a person who has not chosen yet; suspending here
        // means nothing has been transferred, nothing has been written to either
        // card, and backing out costs no bandwidth.
        stageSink(.preparingSave)
        try Task.checkCancellation()
        switch try await playStation.reconcileSave() {
        case let .conflict(conflict):
            suspended = Suspended(conflictID: conflict.id, game: game, platformID: platformID,
                                  core: core, dependencies: playStation)
            return .conflict(conflict)
        case .ready:
            break
        }
        return .ready(try await transfer(game: game, platformID: platformID, core: core,
                                         dependencies: playStation, progress: progress))
    }

    /// Firmware, then discs. Only reached with the memory card settled.
    private func transfer(
        game: PS1Game, platformID: Int, core: CoreDescriptor,
        dependencies playStation: PlayStationLaunchDependencies,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> PreparedLaunch {
        try Task.checkCancellation()
        stageSink(.firmware)
        let systemDirectory = try await playStation.prepareFirmware(
            platformID, game.representative.regions, staged(.firmware, progress))

        try Task.checkCancellation()
        stageSink(.discs)
        let discSet = try await playStation.preparePackage(game, staged(.discs, progress))

        try Task.checkCancellation()
        return PreparedLaunch(entryURL: discSet.entryURL,
                              core: core,
                              systemDirectory: systemDirectory,
                              saveDirectory: playStation.saveDirectory,
                              canonicalRomID: discSet.canonicalRomID,
                              saveStore: playStation.saveStore,
                              discLabels: discSet.discLabels,
                              onLocalSave: playStation.onLocalSave,
                              retrySaveSync: playStation.retrySaveSync,
                              saveStatuses: playStation.saveStatuses)
    }

    /// Tags every progress value a sub-stage produces with the phase it belongs
    /// to. The package store's per-disc `.validating` is the one value that
    /// names its own phase; everything else belongs to the phase that is running.
    private func staged(
        _ phase: LaunchStage,
        _ downstream: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) -> @Sendable (PS1PreparationProgress) -> Void {
        let stage = stageSink
        return { value in
            if case .validating = value, phase == .discs {
                stage(.validating)
            } else {
                stage(phase)
            }
            downstream(value)
        }
    }

    // MARK: Conflict resolution

    private func performResolve(
        _ conflict: PS1SaveConflict,
        choice: PS1ConflictChoice,
        progress: @escaping @Sendable (PS1PreparationProgress) -> Void
    ) async throws -> LaunchPreparationDecision {
        // Only the token this attempt published continues this attempt. A token
        // from another game, another attempt, or a state that has moved on is
        // refused here rather than handed to the coordinator, which would then
        // be deciding on this service's behalf which request it is finishing.
        guard let suspended, suspended.conflictID == conflict.id else {
            throw PS1SaveSyncError.conflictExpired
        }
        stageSink(.preparingSave)
        try Task.checkCancellation()
        do {
            try await suspended.dependencies.resolveConflict(conflict, choice)
        } catch let error as PS1SaveSyncError {
            // The coordinator keeps a token alive for exactly the failures it
            // can still be resolved after; `conflictExpired` is the one it
            // retires. Mirror that, so the model can put the chooser back with
            // the same two cards rather than restarting a preparation that would
            // only mint the same conflict again.
            if error == .conflictExpired { self.suspended = nil }
            throw error
        }
        self.suspended = nil
        return .ready(try await transfer(game: suspended.game, platformID: suspended.platformID,
                                         core: suspended.core,
                                         dependencies: suspended.dependencies,
                                         progress: progress))
    }
}

// MARK: - Live wiring

extension LaunchPreparationDependencies {

    /// The dependencies the app runs on.
    ///
    /// This function is the only place in the shipping app where a RomM endpoint,
    /// a cache path or a save identity is assembled. Views hand it a request and
    /// get a `PreparedLaunch`; they never see a URL that is not already a file on
    /// this device.
    ///
    /// - Parameters:
    ///   - client: the configured RomM client.
    ///   - cachesRoot: the app's Caches directory — the only place besides tmp a
    ///     tvOS app may write. Every subdirectory below is owned by the type that
    ///     names it.
    public static func live(
        client: RommClient,
        cachesRoot: URL = FileManager.default.urls(for: .cachesDirectory,
                                                   in: .userDomainMask)[0],
        defaults: UserDefaults = .standard
    ) -> LaunchPreparationDependencies {
        // One store instance, shared by the legacy route and by every
        // PlayStation coordinator: `PS1SaveCoordinator` reconciles against the
        // same local card area the engine writes through.
        let saveStore = BatterySaveStore(cachesRoot: cachesRoot, defaults: defaults)
        // Byte-for-byte the layout the app used before this boundary existed:
        // ROMs under `Caches/roms/<id>/<fs_name>`, the core's system directory at
        // `Caches/system`, battery saves at `Caches/saves`.
        let cache = CacheManager(client: client,
                                 cacheRoot: cachesRoot.appendingPathComponent("roms",
                                                                              isDirectory: true))
        let legacy = LegacyLaunchDependencies(
            download: { rom, progress in try await cache.download(rom, progress: progress) },
            systemDirectory: cachesRoot.appendingPathComponent("system", isDirectory: true),
            saveDirectory: cachesRoot.appendingPathComponent("saves", isDirectory: true),
            saveStore: saveStore)

        return LaunchPreparationDependencies(legacy: legacy) { game in
            let store = try PS1PackageStore(client: client, cacheRoot: cachesRoot)
            let firmware = try PS1FirmwareManager(client: client, cacheRoot: cachesRoot)
            let coordinator = PS1SaveCoordinator(canonicalRomID: game.canonicalRomID,
                                                 client: client,
                                                 localStore: saveStore,
                                                 defaults: defaults)
            return PlayStationLaunchDependencies(
                reconcileSave: { try await coordinator.reconcileBeforeLaunch() },
                resolveConflict: { conflict, choice in
                    try await coordinator.resolve(conflict, choice: choice)
                },
                prepareFirmware: { platformID, regions, progress in
                    try await firmware.prepare(platformID: platformID, regions: regions,
                                               progress: progress)
                },
                preparePackage: { game, progress in
                    let package = try await store.prepare(game, progress: progress)
                    return PreparedDiscSet(entryURL: package.launchURL,
                                           canonicalRomID: package.canonicalRomID,
                                           discLabels: package.discLabels)
                },
                saveDirectory: playStationSaveDirectory(cachesRoot: cachesRoot,
                                                        canonicalRomID: game.canonicalRomID),
                saveStore: saveStore,
                // Fire-and-forget on purpose: both of these are called from the
                // emulator's main-thread flush, and a frame must never wait on an
                // actor hop, let alone on the network.
                onLocalSave: { data in Task { await coordinator.scheduleUpload(data) } },
                retrySaveSync: { reason in
                    Task { await coordinator.retryPending(reason: reason) }
                },
                saveStatuses: coordinator.statuses)
        }
    }

    /// Per-game, and that is not tidiness.
    ///
    /// Every prepared PlayStation package's playlist is named `game.m3u`, and
    /// Beetle PSX derives its own memory-card filename from the loaded content's
    /// base name. One shared save directory would therefore give every
    /// PlayStation game the same `game.srm`, and a game with no synchronized card
    /// yet would boot on the last game's memory card.
    public static func playStationSaveDirectory(cachesRoot: URL,
                                                canonicalRomID: Int) -> URL {
        cachesRoot
            .appendingPathComponent(PS1FirmwareManager.platformDirectoryName, isDirectory: true)
            .appendingPathComponent("saves", isDirectory: true)
            .appendingPathComponent(String(canonicalRomID), isDirectory: true)
    }
}

// MARK: - Overriding a wrong merge

extension PS1Game {
    /// This game reduced to its representative disc alone.
    ///
    /// `PS1GameClassifier` cannot tell a genuine two-disc game from two
    /// separately numbered products that share a metadata group and both carry a
    /// disc token starting at 1 — a demo or sampler series is the known case, and
    /// no filename rule distinguishes it. When that happens the player is looking
    /// at a disc list that is wrong, and this is the way out: the representative
    /// becomes a one-disc game with its own save identity, which is what it
    /// actually is.
    ///
    /// The label is kept as the representative's own, so a player who overrides
    /// `Disc 2` still sees `Disc 2` rather than being told it is disc one of
    /// something.
    public var singleDiscOverride: PS1Game {
        let stem = PS1GameClassifier.fileStem(for: representative)
        let label = discs.first { $0.romID == representative.id }?.label ?? "Disc 1"
        return PS1Game(representative: representative,
                       canonicalRomID: representative.id,
                       discs: [PS1Disc(romID: representative.id, fileStem: stem,
                                       index: 1, label: label)],
                       excludedSiblings: representative.siblingRoms)
    }
}

// MARK: - The model

/// The state one launch screen can be in.
public enum LaunchPreparationState {
    case idle
    case preparing
    /// Two memory cards and a person who has not chosen yet. The failure is
    /// present when a previous choice could not be carried out and the same two
    /// cards are still on the table.
    case conflict(PS1SaveConflict, LaunchFailure?)
    case ready(PreparedLaunch)
    case failed(LaunchFailure)
    case cancelled
}

/// Owns one launch attempt: its generation, its task, its service and its
/// throttled progress.
///
/// Two rules carry everything else:
///
/// 1. **A completion may only publish while its generation is still current.**
///    Every attempt is stamped on the way in; `cancel`, `retry` and `resolve`
///    all bump the stamp before doing anything else. A `.ready` arriving from an
///    attempt the player already backed out of therefore cannot start a game,
///    and a failure from it cannot replace the screen the player is looking at.
/// 2. **A new attempt waits for the previous one to finish unwinding.** Not for
///    it to be cancelled — for it to have *returned*. `PS1PackageStore` removes
///    its staging directory and `StreamingFileDownloader` removes its `.part`
///    file on the way out of a cancelled transfer, and a fresh
///    `PS1PackageStore` deletes every staging directory it finds when it is
///    constructed. Starting attempt N+1 before attempt N has unwound would have
///    the new store delete the old one's staging directory underneath it, and
///    would put two writers on one `.part` path.
@MainActor
public final class LaunchPreparationModel: ObservableObject {

    /// How often byte progress may reach the main actor. A tenth of a second is
    /// below the threshold at which a bar looks stalled and four orders of
    /// magnitude below the rate a 480 MB transfer reports at.
    public static let defaultThrottleInterval: TimeInterval = 0.15

    /// A monotonic clock. Wall time is not: a clock correction mid-download must
    /// not stall a progress bar for hours or flood it.
    public static let monotonicSeconds: @Sendable () -> TimeInterval = {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    @Published public private(set) var state: LaunchPreparationState = .idle
    @Published public private(set) var progress: LaunchProgressSnapshot = .idle

    /// Monotonically increasing. Public so a view can key a `.task(id:)` on it.
    @Published public private(set) var attempt = 0

    /// The request this screen is for. Published because it is replaced by
    /// `override(with:)`, and the disc set on screen has to be the disc set that
    /// is actually about to be launched — a list that still showed two discs
    /// after the player refused the merge would be worse than no list at all.
    @Published public private(set) var request: LaunchRequest

    /// The discs this launch will produce, in playlist order. Empty for a legacy
    /// launch, which has none.
    public var discs: [PS1Disc] {
        guard case let .playStation(game, _) = request else { return [] }
        return game.discs
    }

    /// The request that plays the representative disc alone, when the classifier
    /// merged a set that could be wrong. `nil` when there is nothing to override.
    public var singleDiscOverride: LaunchRequest? {
        guard case let .playStation(game, platformID) = request, game.discs.count > 1 else {
            return nil
        }
        return .playStation(game: game.singleDiscOverride, platformID: platformID)
    }

    private let makeService: @Sendable (@escaping @Sendable (LaunchStage) -> Void)
        -> LaunchPreparationService
    private let throttleInterval: TimeInterval
    private let clock: @Sendable () -> TimeInterval

    private var task: Task<Void, Never>?
    private var service: LaunchPreparationService?

    /// - Parameters:
    ///   - makeService: builds the attempt-scoped service around the stage sink
    ///     the model supplies. A closure rather than a value because a service is
    ///     terminal once cancelled, so every attempt needs its own.
    ///   - throttleInterval: how often byte progress may reach the main actor.
    ///   - clock: monotonic seconds, injected so a test can drive the throttle.
    public init(request: LaunchRequest,
                makeService: @escaping @Sendable (@escaping @Sendable (LaunchStage) -> Void)
                    -> LaunchPreparationService,
                throttleInterval: TimeInterval = LaunchPreparationModel.defaultThrottleInterval,
                clock: @escaping @Sendable () -> TimeInterval
                    = LaunchPreparationModel.monotonicSeconds) {
        self.request = request
        self.makeService = makeService
        self.throttleInterval = throttleInterval
        self.clock = clock
    }

    public convenience init(request: LaunchRequest,
                            dependencies: LaunchPreparationDependencies,
                            throttleInterval: TimeInterval
                                = LaunchPreparationModel.defaultThrottleInterval,
                            clock: @escaping @Sendable () -> TimeInterval
                                = LaunchPreparationModel.monotonicSeconds) {
        self.init(request: request,
                  makeService: { stage in
                      LaunchPreparationService(dependencies: dependencies, stage: stage)
                  },
                  throttleInterval: throttleInterval,
                  clock: clock)
    }

    /// The initializer the app uses. The client and the cache layout stay inside
    /// the Kit; a view supplies a request and nothing else.
    public convenience init(request: LaunchRequest, client: RommClient) {
        self.init(request: request, dependencies: .live(client: client))
    }

    // MARK: Commands

    /// Starts the first attempt. Idempotent: a screen that reappears does not
    /// restart a preparation that is already running or already finished.
    public func run() {
        guard case .idle = state else { return }
        start()
    }

    /// Abandons whatever is in flight and starts over.
    public func retry() { start() }

    /// Replaces the request and starts over — the single-disc override for a
    /// disc set the classifier got wrong.
    public func override(with request: LaunchRequest) {
        self.request = request
        start()
    }

    /// Carries out one side of a conflict and continues the *same* attempt.
    ///
    /// The service instance is kept: it is holding the suspended request the
    /// conflict belongs to, and starting a fresh one would re-run reconciliation
    /// and mint a second token for the same two cards.
    public func resolve(choice: PS1ConflictChoice) {
        guard case let .conflict(conflict, _) = state, let service else { return }
        let previous = task
        attempt &+= 1
        let generation = attempt
        state = .preparing
        progress = .idle
        let throttle = makeThrottle(generation: generation)
        task = Task { @MainActor [weak self] in
            // The preparing task has already returned — that is how the conflict
            // reached the screen — but awaiting it costs nothing and keeps the
            // "one attempt at a time" rule true by construction rather than by
            // argument.
            await previous?.value
            guard let self, self.attempt == generation else { return }
            let outcome: Result<LaunchPreparationDecision, Error>
            do {
                outcome = .success(try await service.resolve(conflict, choice: choice,
                                                             progress: { throttle.report($0) }))
            } catch {
                outcome = .failure(error)
            }
            throttle.flush()
            // The one place this attempt's result is admitted. See `start()`.
            guard self.attempt == generation else { return }
            switch outcome {
            case let .success(decision): self.publish(decision)
            case let .failure(error): self.publishResolutionFailure(error, conflict: conflict)
            }
        }
    }

    /// Interrupts the attempt, waits for it to finish unwinding, and only then
    /// reports itself cancelled.
    ///
    /// The wait is the point. A caller dismisses the screen when this returns,
    /// and by then the staging directory and the `.part` file the attempt was
    /// writing are gone.
    public func cancel() async {
        // A prepared launch is running in the emulator; there is nothing in
        // flight to interrupt and nothing to clean up. Reporting `.cancelled`
        // here would tear the game down on an incidental disappearance.
        if case .ready = state { return }
        let previous = task
        let previousService = service
        attempt &+= 1
        task = nil
        service = nil
        previous?.cancel()
        await previousService?.cancel()
        await previous?.value
        state = .cancelled
        progress = .idle
    }

    // MARK: Attempt plumbing

    private func start() {
        let previous = task
        let previousService = service
        previous?.cancel()
        attempt &+= 1
        let generation = attempt
        state = .preparing
        progress = .idle
        service = nil
        let throttle = makeThrottle(generation: generation)
        let request = self.request
        task = Task { @MainActor [weak self] in
            // Cancel *and wait*. Until the previous attempt has returned, its
            // staging directory and part file still exist and its package store
            // is still alive.
            await previousService?.cancel()
            await previous?.value
            guard let self, self.attempt == generation, !Task.isCancelled else { return }
            let service = self.makeService(throttle.setStage)
            self.service = service
            let outcome: Result<LaunchPreparationDecision, Error>
            do {
                outcome = .success(try await service.prepare(request,
                                                             progress: { throttle.report($0) }))
            } catch {
                outcome = .failure(error)
            }
            throttle.flush()
            // **The stale-completion rule, in one statement covering both
            // outcomes.** Success and failure are collected first and admitted
            // second, so there is a single place where an attempt's result may
            // reach the screen and a single check in front of it — rather than
            // one guard per branch, where the branch that is hardest to reach is
            // also the one whose guard nothing would notice losing. There is no
            // suspension between this check and the assignment, so a generation
            // that is current here cannot go stale before the state is written.
            guard self.attempt == generation else { return }
            switch outcome {
            case let .success(decision):
                self.publish(decision)
            case let .failure(error) where error is CancellationError:
                self.state = .cancelled
            case let .failure(error):
                self.state = .failed(LaunchFailurePresenter.describe(error))
            }
        }
    }

    private func makeThrottle(generation: Int) -> LaunchProgressThrottle {
        LaunchProgressThrottle(interval: throttleInterval, now: clock) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.attempt == generation else { return }
                self.progress = LaunchProgressSnapshot.merged(snapshot, into: self.progress)
            }
        }
    }

    /// The only place `.ready` is ever assigned. Both callers have already
    /// established that the completing attempt is still the current one.
    private func publish(_ decision: LaunchPreparationDecision) {
        switch decision {
        case let .ready(launch):
            state = .ready(launch)
        case let .conflict(conflict):
            state = .conflict(conflict, nil)
        }
    }

    /// A resolution that did not go through. Three of the coordinator's refusals
    /// leave both cards exactly as they were and the token still good, so the
    /// chooser comes back with the reason attached instead of the screen turning
    /// into a dead end.
    private func publishResolutionFailure(_ error: Error, conflict: PS1SaveConflict) {
        if error is CancellationError { state = .cancelled; return }
        let failure = LaunchFailurePresenter.describe(error)
        if let sync = error as? PS1SaveSyncError, sync != .conflictExpired {
            state = .conflict(conflict, failure)
        } else {
            state = .failed(failure)
        }
    }
}

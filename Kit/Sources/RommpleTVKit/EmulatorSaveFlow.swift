import Combine
import Foundation

// MARK: - Vocabulary

/// Why a card is being written right now.
///
/// The distinction that matters is `periodic` against everything else: the tick
/// hands its bytes over and lets the uploader's own debounce decide when they go
/// out, while every other trigger is a moment the player is about to stop
/// playing — pausing, quitting, leaving the app, or asking in so many words — and
/// none of those is going to wait out a timer.
public enum EmulatorSaveTrigger: Sendable, Equatable, CaseIterable {
    /// The ~10-second flush during play.
    case periodic
    case pause
    case quit
    case background
    /// "Retry Save" on the pause overlay.
    case user

    /// The reason the uploader is asked to send **now**, bypassing its debounce,
    /// or `nil` for the tick.
    ///
    /// `RetryReason.launch` is deliberately unreachable from here: it belongs to
    /// preparation, which runs before an engine exists.
    public var retryReason: RetryReason? {
        switch self {
        case .periodic: return nil
        case .pause: return .pause
        case .quit: return .quit
        case .background: return .background
        case .user: return .user
        }
    }
}

/// The two sentences a failed local write puts on screen.
///
/// Constants, never a rendering of whatever the store threw: a store's error
/// carries the container path of the save file, and a `URLError` further down
/// would carry the player's server address. The failure the player sees says what
/// happened and what to do, and nothing about this device's filesystem.
public struct EmulatorSaveFailure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public let recovery: String

    public init(message: String, recovery: String) {
        self.message = message
        self.recovery = recovery
    }

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recovery }

    /// The only failure this layer raises. There is exactly one thing that can go
    /// wrong here — the local write did not land — and one thing to do about it.
    public static let localWriteFailed = EmulatorSaveFailure(
        message: "RommpleTV could not save this game on this Apple TV.",
        recovery: "Your progress is still in the game. Choose Retry Save to write it again — "
            + "quitting now would lose it.")

    /// What a previous session's `UnwrittenCardNote` becomes on screen. A
    /// different sentence because it is about a different session: the progress
    /// it names is already gone, and what the player can still do something
    /// about is this one.
    public static let lastSessionUnwritten = EmulatorSaveFailure(
        message: "The last time you played this game, RommpleTV could not save it on this "
            + "Apple TV.",
        recovery: "Choose Retry Save to write this game's save now. If it fails again, restart "
            + "RommpleTV before playing on.")
}

/// The note a session leaves behind when its last write did not land and there
/// was nobody left to tell.
///
/// The pause overlay is where a failed write is shown, and there is one way out
/// of a game that never reaches it: backing out with Menu, which dismisses the
/// view first and only then lets `EmulatorEngine.stop()` take its final flush.
/// A failure there has no surface at all — the view it would have been published
/// to is already gone — so it is written down instead, and the next session
/// says so.
///
/// A flag and nothing else. No card bytes: whatever did reach the local store is
/// still the local store's, and on a PlayStation launch the coordinator's own
/// pending flag is what gets it to the server.
///
/// **It is retired by being shown, not by time or by a later success.** A note
/// cleared by this session's first successful write would usually be cleared ten
/// seconds in, before the player had any reason to open the overlay — which is a
/// message that exists but is not delivered. So the host takes it the first time
/// an overlay opens, and it is shown exactly once. If the same failure is still
/// happening, the periodic path says so on its own and much louder.
public enum UnwrittenCardNote {
    static func key(_ romID: Int) -> String { "save.unwritten.\(romID)" }

    public static func record(romID: Int, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(romID))
    }

    /// Taken when it has been shown. The read first is not an optimization: it
    /// keeps this from writing to defaults for games that never left one.
    public static func clear(romID: Int, defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: key(romID)) else { return }
        defaults.removeObject(forKey: key(romID))
    }

    public static func exists(romID: Int, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(romID))
    }
}

/// What one flush concluded, in the terms its caller has to act on.
///
/// Not `@discardableResult` anywhere it is produced, and that is on purpose: the
/// Quit path's whole correctness is that it reads this before dismissing, and a
/// caller that means to ignore it has to say `_ =` and be seen doing it.
public enum EmulatorSaveOutcome: Sendable, Equatable {
    /// The card is on disk. Whatever was owed remotely has been scheduled.
    case saved
    /// Nothing reached the local card. Gameplay stays paused, the message is
    /// published, and any dismissal the caller was flushing for must not happen.
    case failed(EmulatorSaveFailure)
}

/// What the uploader is asked to do once a local write has landed.
///
/// One value rather than two calls so a test can assert on exactly what crossed
/// the boundary, in order, rather than on two closures that both happened to run.
public struct EmulatorRemoteSaveRequest: Sendable, Equatable {
    /// Bytes that are **already on the local card**. `nil` when the card had not
    /// changed and there is nothing new to hand over — which is not the same as
    /// nothing being owed, since an earlier upload may have failed while the
    /// bytes on disk stayed exactly as they are.
    public let bytes: Data?
    /// Non-nil when the upload must not wait out the debounce.
    public let retry: RetryReason?

    public init(bytes: Data?, retry: RetryReason?) {
        self.bytes = bytes
        self.retry = retry
    }
}

// MARK: - The flow

/// The order in which a game's save reaches disk and then the server, and the
/// state a player sees when the first half fails.
///
/// ## The rule this type exists to hold
///
/// **Local first, and nothing remote after a local failure.**
/// `PS1SaveCoordinator.scheduleUpload` documents its own half of this: it takes
/// the bytes it is handed at their word and prefers them over the stored card
/// until the upload settles. Bytes that never reached the local file would
/// therefore be uploaded, clear the pending flag, and record a baseline the local
/// card does not match — after which the next reconciliation reads "local
/// changed, remote did not" and uploads the *older* card over the newer remote
/// one. So the remote schedule lives after `try localFlush()` inside the same
/// `do`, and the `catch` returns without reaching it.
///
/// ## Why it is here rather than in the engine
///
/// `EmulatorEngine` is App code that every hardware-accepted system runs
/// through — NES, SNES, Game Boy, GBA, Genesis, Master System, Game Gear and
/// Virtual Boy all flush battery RAM through it — and it cannot be exercised
/// without a core, a display link and an audio engine. The ordering rule and the
/// message the overlay shows are therefore held here, where they are ordinary
/// synchronous code with two injected closures, and the engine supplies the two
/// effects: the write, and the two callbacks `PreparedLaunch` carries (both
/// no-ops on a legacy launch).
///
/// `@MainActor` and synchronous throughout. The local flush runs on the
/// emulator's main-thread tick and must have *finished* before anything remote is
/// scheduled; an actor hop in the middle would be exactly the window this rule
/// forbids.
@MainActor
public final class EmulatorSaveFlow: ObservableObject {

    /// Writes the card locally and answers the bytes it wrote — or `nil` when the
    /// card had not changed since the last successful write. Throwing means
    /// nothing reached the local card.
    public typealias LocalFlush = @MainActor () throws -> Data?

    /// Hands the uploader work whose bytes are already on disk. Fire-and-forget:
    /// it is called from a frame callback and must not wait on an actor, let
    /// alone on the network.
    public typealias RemoteSchedule = @MainActor (EmulatorRemoteSaveRequest) -> Void

    /// The failure on screen, or `nil`. Only ever `.localWriteFailed`, and only
    /// ever cleared by a later local success.
    @Published public private(set) var failure: EmulatorSaveFailure?

    private let localFlush: LocalFlush
    private let scheduleRemote: RemoteSchedule

    public init(localFlush: @escaping LocalFlush, scheduleRemote: @escaping RemoteSchedule) {
        self.localFlush = localFlush
        self.scheduleRemote = scheduleRemote
    }

    /// One flush, local half first.
    ///
    /// - Returns: `.saved` when the card is on disk — including when there was
    ///   nothing to write, which means the card on disk is already current — and
    ///   `.failed` when the write threw, in which case **nothing remote was
    ///   scheduled** and the caller must not go through with whatever it was
    ///   flushing for.
    public func flush(_ trigger: EmulatorSaveTrigger) -> EmulatorSaveOutcome {
        let written: Data?
        do {
            written = try localFlush()
        } catch {
            // Two things this must not do, and both are the point of the type. It
            // must not schedule anything remote — see the rule above — and it must
            // not clear a message that is still true. The underlying error is not
            // rendered: a store's error carries a filesystem path.
            failure = .localWriteFailed
            return .failed(.localWriteFailed)
        }

        // Reached only because the write above returned. A tick with nothing to
        // write asks for nothing at all; every other trigger still asks, because
        // an unchanged card can still be owed to the server from an earlier
        // upload that failed.
        let request = EmulatorRemoteSaveRequest(bytes: written, retry: trigger.retryReason)
        if request.bytes != nil || request.retry != nil {
            scheduleRemote(request)
        }
        // A local success is the only thing that clears the message, and every
        // local success clears it: the card on disk is now the card in the game.
        failure = nil
        return .saved
    }
}

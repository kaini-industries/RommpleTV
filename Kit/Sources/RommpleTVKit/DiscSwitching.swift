import Combine
import Foundation

// MARK: - Vocabulary

/// What a running session may offer a player about discs.
///
/// The four cases are exhaustive over the situations a prepared launch and a
/// loaded core can be in together, and three of them deliberately do **not**
/// offer a switch. Which one applies is decided once, by
/// ``resolve(labels:hasDiskControl:coreDiscCount:)``, from the two independent
/// counts and the core's registration — never from a count alone.
public enum DiscSwitchAvailability: Equatable, Sendable {
    /// Nothing to say. A legacy launch or a one-disc game: `discLabels` is `[]`
    /// or has a single entry, whatever the core's drive reports.
    case single
    /// A prepared multi-disc set on a core that registered no Disk Control
    /// interface. There is no action to offer, only an explanation.
    case unsupportedCore
    /// The core and the prepared package do not agree on how many discs there
    /// are. Switching is off: the label list cannot be indexed by a numbering
    /// the core does not share.
    case countMismatch(labels: Int, core: Int)
    /// Switching is offered, over exactly these labels, in playlist order.
    case available([String])

    /// The three conditions, in one place and in one order.
    ///
    /// - `labels.count > 1` — the **only** authority for "this session has more
    ///   than one disc". `coreDiscCount > 0` is not: Genesis Plus GX registers a
    ///   Disk Control interface too, so a Sega CD launch reports discs while its
    ///   `discLabels` is correctly empty. Gating on the core's count would put
    ///   disc UI on a game that never had a disc set prepared for it.
    /// - `hasDiskControl` — asked separately from the count because a count of
    ///   zero cannot tell "no interface" from "an interface with nothing in it",
    ///   and those two are a different sentence to a player.
    /// - `coreDiscCount > 1`, and then equal to `labels.count` — the mapping
    ///   between a label and the index handed to `retro`'s `set_image_index` is
    ///   positional, so two lists of different lengths cannot be indexed by one
    ///   number. Sending a player to a disc they did not choose is worse than
    ///   telling them switching is off.
    ///
    /// The third and fourth guards overlap: with `labels.count > 1` already
    /// established, "the counts are equal" implies "the core has more than one",
    /// so nothing observable changes if the `> 1` guard is weakened — mutating it
    /// to `>= 1` is an equivalent mutant and no test can kill it. It is kept
    /// anyway, and stated separately, because it is the condition that does not
    /// depend on the packaging: a core presenting one disc has no switch to
    /// offer whatever the package says, and that stays true if the equality below
    /// is ever relaxed.
    public static func resolve(labels: [String],
                               hasDiskControl: Bool,
                               coreDiscCount: Int) -> DiscSwitchAvailability {
        guard labels.count > 1 else { return .single }
        guard hasDiskControl else { return .unsupportedCore }
        guard coreDiscCount > 1 else {
            return .countMismatch(labels: labels.count, core: coreDiscCount)
        }
        guard coreDiscCount == labels.count else {
            return .countMismatch(labels: labels.count, core: coreDiscCount)
        }
        return .available(labels)
    }

    /// Whether a **Change Disc** button may be offered. False for every state
    /// but ``available(_:)``, and `DiscSwitchFlow.select` refuses independently
    /// of it — a hidden button is not the same as a disabled action.
    public var offersSwitching: Bool {
        if case .available = self { return true }
        return false
    }

    /// Whether the pause overlay shows a disc section at all. False only for
    /// ``single``, which covers every legacy launch by construction.
    public var isVisible: Bool { self != .single }

    /// What to say when there is no switch to offer, or `nil` when there is
    /// nothing to explain.
    ///
    /// Both sentences name the next action rather than stopping at a diagnosis,
    /// and the action is one this overlay already has: Quit to Library, then
    /// launch again. Neither carries a path, a file name or a server.
    public var note: String? {
        switch self {
        case .single, .available:
            return nil
        case .unsupportedCore:
            return "This game has more than one disc, but the emulator core running it can't "
                + "change discs. You can keep playing this disc."
        case let .countMismatch(labels, core):
            return "This game was prepared with \(labels) discs and the emulator core loaded "
                + "\(core), so RommpleTV can't be sure which disc is which. Changing discs is "
                + "off for this session. Quit to Library and launch this game again to "
                + "prepare it fresh."
        }
    }

    /// The labels a picker may show, which is the empty list unless switching is
    /// actually on. Reading the labels off the *state* rather than off the
    /// launch is what makes "a disabled state cannot be indexed" structural.
    public var labels: [String] {
        if case let .available(labels) = self { return labels }
        return []
    }
}

/// Why a disc switch was refused before the core was ever asked.
///
/// Errors the *core* raises travel as themselves (`CoreError`), whose sentences
/// are already written for a player. These are the refusals this layer makes on
/// its own behalf.
public enum DiscSwitchRefusal: Error, LocalizedError, Equatable, Sendable {
    /// The game is still running. `LibretroCore` is single-owner and its entry
    /// points are main-thread only: a switch that ran while the display link was
    /// still driving `runFrame()` would eject a disc from under `retro_run`,
    /// which is undefined behaviour in C rather than a bad frame.
    case framesRunning
    /// There is no loaded core to ask — it was unloaded while the picker was
    /// open.
    case noGameRunning
    /// This session is not one where discs may be switched. See
    /// ``DiscSwitchAvailability``.
    case switchingUnavailable
    /// The index is not one of the prepared discs.
    case noSuchDisc

    public var errorDescription: String? {
        switch self {
        case .framesRunning:
            return "Pause the game before changing discs."
        case .noGameRunning:
            return "This game is no longer running, so its disc can't be changed."
        case .switchingUnavailable:
            return "RommpleTV can't change discs for this game."
        case .noSuchDisc:
            return "That disc isn't part of this game."
        }
    }
}

/// What one selection did.
public enum DiscSwitchResult: Equatable, Sendable {
    /// The core took the new disc. The picker's work is done.
    case switched
    /// That disc was already in the drive, so the core was not asked. Ejecting
    /// and reinserting the disc a player is already on is a real transaction
    /// taken for no change at all.
    case alreadyInserted
    /// Refused or failed. The message is on ``DiscSwitchFlow/failure`` and the
    /// picker stays open.
    case failed
}

/// Everything this flow reaches into the engine for.
///
/// Five closures rather than a reference to `EmulatorEngine`, for the same
/// reason `EmulatorSaveFlow` takes two: the engine cannot be constructed without
/// a core dylib, a display link and an audio engine, so a rule held there is a
/// rule no test can run.
@MainActor
public struct DiscSwitchSeams {
    /// Whether the core registered a Disk Control interface at all.
    public var hasDiskControl: () -> Bool
    /// How many discs the core's drive reports.
    public var discCount: () -> Int
    /// The disc in the drive, or `nil` when the core cannot say — no interface,
    /// or nothing inserted.
    public var currentIndex: () -> Int?
    /// Whether frames have actually stopped.
    public var isPaused: () -> Bool
    /// Runs the switch on the same main-thread context as `runFrame()`.
    public var switchDisc: (Int) throws -> Void

    public init(hasDiskControl: @escaping () -> Bool,
                discCount: @escaping () -> Int,
                currentIndex: @escaping () -> Int?,
                isPaused: @escaping () -> Bool,
                switchDisc: @escaping (Int) throws -> Void) {
        self.hasDiskControl = hasDiskControl
        self.discCount = discCount
        self.currentIndex = currentIndex
        self.isPaused = isPaused
        self.switchDisc = switchDisc
    }
}

// MARK: - The flow

/// Paused disc switching, and the state the pause overlay shows for it.
///
/// ## The two rules this type exists to hold
///
/// **A label is never indexed against a count that disagrees with it.**
/// Availability is settled once, at construction — which is immediately after
/// `retro_load_game`, the first moment the core's Disk Control registration and
/// disc count are both real — and every other state disables switching. `select`
/// refuses on the state as well as on the index, so "the button is hidden" and
/// "the action is off" are not the same claim resting on one line of view code.
///
/// **What is displayed is what the drive answered.** The core's switch is a
/// three-step transaction (eject, set index, insert) with a best-effort restore
/// if a step fails, so a failure can leave the drive holding the old disc, the
/// new one, or nothing at all. The index is therefore re-read from the core
/// after **every** attempt, outside the `do`/`catch`, and the label shown is
/// derived from that — never from the index that was asked for. Showing "Disc 2"
/// while the drive holds disc 1 is worse than showing nothing.
///
/// `@MainActor` and synchronous throughout, like the core it drives.
@MainActor
public final class DiscSwitchFlow: ObservableObject {

    /// Every disc the package prepared, in playlist order. Kept for the mismatch
    /// message; the picker reads ``DiscSwitchAvailability/labels`` instead, so a
    /// disabled state has nothing to offer.
    public let labels: [String]

    /// Settled once, after the game is loaded. See the type's note.
    @Published public private(set) var availability: DiscSwitchAvailability

    /// The disc the core says is in the drive, or `nil` when it cannot say.
    /// Always the drive's own answer.
    @Published public private(set) var currentIndex: Int?

    /// What the last attempt failed with, or `nil`. Cleared at the start of the
    /// next attempt and by an attempt that lands.
    @Published public private(set) var failure: String?

    private let seams: DiscSwitchSeams

    public init(labels: [String], seams: DiscSwitchSeams) {
        self.labels = labels
        self.seams = seams
        self.availability = .resolve(labels: labels,
                                     hasDiskControl: seams.hasDiskControl(),
                                     coreDiscCount: seams.discCount())
        self.currentIndex = seams.currentIndex()
    }

    // MARK: What the overlay shows

    /// Whether the pause overlay shows anything about discs. False for every
    /// legacy launch and every one-disc game.
    public var showsDiscSection: Bool { availability.isVisible }

    /// Whether **Change Disc** is offered.
    public var canSwitch: Bool { availability.offersSwitching }

    /// The explanation for a state that offers no switch, or `nil`.
    public var note: String? { availability.note }

    /// The name of the disc in the drive, or `nil` when there is not one this
    /// session can honestly name.
    ///
    /// Only ``DiscSwitchAvailability/available(_:)`` names a disc: in the
    /// mismatch state the mapping from index to label is known to be untrustworthy,
    /// and in the unsupported state there is no drive to ask. The bounds check is
    /// not decoration either — libretro reports "no disc inserted" as an index at
    /// or past the count, and a core is free to answer anything.
    public var currentDiscLabel: String? {
        guard case let .available(labels) = availability,
              let currentIndex, labels.indices.contains(currentIndex) else { return nil }
        return labels[currentIndex]
    }

    /// The disc line for the overlay: the drive's disc, or that it cannot be
    /// named.
    public var currentDiscDescription: String { currentDiscLabel ?? "Unknown" }

    /// Whether `index` is the disc already in the drive.
    public func isCurrent(_ index: Int) -> Bool { currentIndex == index }

    // MARK: Switching

    /// Re-reads the drive. Called when the picker opens, so what it shows is
    /// current rather than whatever the last attempt left.
    public func refresh() { currentIndex = seams.currentIndex() }

    /// Puts `index` in the drive.
    ///
    /// Four refusals before the core is asked anything — the state, the index,
    /// the disc already being in the drive, and frames still running — and then
    /// one re-query afterwards that happens on **both** paths.
    ///
    /// - Returns: whether the picker may close. `.failed` keeps it open with
    ///   ``failure`` under it.
    @discardableResult
    public func select(_ index: Int) -> DiscSwitchResult {
        failure = nil
        guard case let .available(labels) = availability else {
            return refuse(.switchingUnavailable)
        }
        guard labels.indices.contains(index) else { return refuse(.noSuchDisc) }
        guard !isCurrent(index) else { return .alreadyInserted }
        // The engine refuses this too, and has to: it is the object that owns the
        // display link, so it is the only one that can promise a switch never
        // races a frame. This is the same rule where a test can reach it.
        guard seams.isPaused() else { return refuse(.framesRunning) }

        var thrown: Error?
        do {
            try seams.switchDisc(index)
        } catch {
            thrown = error
        }
        // Outside the catch, and that is the whole point: the transaction can
        // fail after the tray opened, and the restore that follows is best-effort.
        // The only honest answer to "which disc is in there" is the core's.
        currentIndex = seams.currentIndex()
        if let thrown {
            failure = message(for: thrown)
            return .failed
        }
        return .switched
    }

    private func refuse(_ refusal: DiscSwitchRefusal) -> DiscSwitchResult {
        failure = refusal.localizedDescription
        // Even a refusal re-reads: the picker is on screen and whatever it was
        // showing is now at least one event old.
        currentIndex = seams.currentIndex()
        return .failed
    }

    /// The sentence a player reads. `CoreError` and `DiscSwitchRefusal` are both
    /// `LocalizedError` with sentences written for a player and carrying nothing
    /// about this device; anything else falls back to a fixed sentence rather
    /// than rendering an error whose description could carry a path.
    private func message(for error: Error) -> String {
        switch error {
        case let core as CoreError: return core.localizedDescription
        case let refusal as DiscSwitchRefusal: return refusal.localizedDescription
        default: return CoreError.discSwitchFailed.localizedDescription
        }
    }
}

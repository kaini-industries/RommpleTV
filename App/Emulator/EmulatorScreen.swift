import SwiftUI
import MetalKit
import GameController
import RommpleTVKit

/// The running game.
///
/// Initialized from a `PreparedLaunch` and nothing else. It never infers a
/// sibling, refetches a platform, or knows where a package lives: which file to
/// load, which core to load it with, which directories the core may write to and
/// which ROM id owns the save were all decided by `LaunchPreparationService`
/// before this view existed.
struct EmulatorHostView: View {
    let launch: PreparedLaunch
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var startFailure: String?
    @State private var showOverlay = false
    @State private var engine: EmulatorEngine?
    /// The save failure the engine last published, or `nil`. Deliberately its
    /// own state and **not** `startFailure`: a game that is running must stay on
    /// screen when a write fails, and the player has to be able to keep playing,
    /// retry, or quit knowing what they are giving up.
    @State private var saveFailure: EmulatorSaveFailure?
    /// Which discs this session may switch between, published by the engine once
    /// the game is loaded. `nil` until then, and — by construction — a state that
    /// shows nothing at all for a legacy or single-disc launch.
    @State private var discFlow: DiscSwitchFlow?
    /// Whether the disc picker is on top of the pause overlay. Only ever true
    /// while `showOverlay` is, so the game is stopped for the whole of it.
    @State private var showDiscPicker = false
    /// Where the memory card's server half stands, or `.idle` on a legacy
    /// launch, which has no server-side save at all.
    @State private var syncStatus: PS1SaveSyncStatus = .idle

    var body: some View {
        Group {
            if let startFailure {
                startFailureView(startFailure)
            } else {
                ZStack {
                    MetalHostRepresentable(launch: launch,
                                           startFailure: $startFailure,
                                           showOverlay: showOverlay,
                                           onEngineReady: {
                                               engine = $0
                                               discFlow = $0.discFlow
                                           },
                                           onOverlayRequested: toggleOverlay,
                                           onPauseRequested: forceShowOverlay,
                                           onLocalSaveFailure: { saveFailure = $0 })
                        .ignoresSafeArea()
                    if showOverlay {
                        if showDiscPicker, let discFlow {
                            // Siri remote Menu and the Xbox pad's B both arrive
                            // as the exit command, and it is handled here rather
                            // than on the host: with the picker closed there is
                            // no handler, so Menu keeps backing out of the game
                            // exactly as it did before.
                            DiscPickerView(flow: discFlow, onDone: { showDiscPicker = false })
                                .onExitCommand { showDiscPicker = false }
                        } else {
                            PauseOverlayView(
                                saveFailure: saveFailure,
                                discs: discFlow,
                                syncStatus: syncStatus,
                                onResume: resumeAndHideOverlay,
                                onRestart: {
                                    engine?.restartGame()
                                    resumeAndHideOverlay()
                                },
                                onChangeDisc: {
                                    discFlow?.refresh()
                                    showDiscPicker = true
                                },
                                onRetrySave: { try? engine?.flushSaveNow(reason: .user) },
                                onRetrySync: { launch.retrySaveSync(.user) },
                                onQuit: quitIfSaved)
                        }
                    }
                }
                // The coordinator's sanitized status stream, consumed for as long
                // as the game is on screen. `AsyncStream` buffers what nobody has
                // read yet, so a status published while preparation was still
                // running is still delivered here. A legacy launch has no stream
                // and this does nothing.
                .task {
                    guard let statuses = launch.saveStatuses else { return }
                    for await status in statuses { syncStatus = status }
                }
                // Siri remote's play/pause button opens/closes the overlay.
                // The Xbox pad's left-stick click reaches the same toggle via
                // EmulatorEngine.onOverlayRequested (wired in
                // MetalHostRepresentable) — see ControllerInput.swift.
                .onPlayPauseCommand(perform: toggleOverlay)
                // Every way an overlay opens goes through this, which is why the
                // note is taken here rather than at each of the three call sites.
                .onChange(of: showOverlay) { _, isShowing in
                    if isShowing { deliverUnwrittenCardNote() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    // Leaving the app is a moment the card has to be on disk. The
                    // game stops where it is and the overlay comes up, so a
                    // failure that happened while nobody was looking is the first
                    // thing on screen when the player comes back — which means
                    // the picker, if it was open, is not on top of it.
                    showDiscPicker = false
                    engine?.handleBackground()
                    showOverlay = true
                }
            }
        }
    }

    /// The game never started. This one *does* replace the view, because there is
    /// no game behind it — and it now offers the way out rather than being a dead
    /// end whose only exit is the Siri remote's Menu button.
    ///
    /// The message is the error's own `localizedDescription`, unchanged: every
    /// error that can reach here is either a `LocalizedError` written for a
    /// player (`EngineError`, `CoreError` — including the M3U a core refuses) or
    /// a Cocoa filesystem error, whose localized description is a real sentence.
    /// Nothing that reaches this point carries a server address: `start` makes no
    /// network call.
    private func startFailureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text("Can't start emulation").font(.title3)
            Text(message)
                .font(.callout).multilineTextAlignment(.center)
                .accessibilityIdentifier("emulator.startFailure")
            Text("Nothing was changed on this Apple TV or on your RomM server. "
                 + "Try launching the game again.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Back to Library") { dismiss() }
                .accessibilityIdentifier("emulator.startBack")
        }
        .frame(maxWidth: 900)
        .padding(48)
    }

    private func toggleOverlay() {
        if showOverlay {
            resumeAndHideOverlay()
        } else {
            engine?.pause()
            showOverlay = true
        }
    }

    private func resumeAndHideOverlay() {
        // The picker may not outlive the pause it was opened under: it is the one
        // piece of this UI that can ask the core to do something, and the core may
        // only be asked while frames are stopped.
        showDiscPicker = false
        engine?.resume()
        showOverlay = false
    }

    /// Quit leaves only after the card is on disk.
    ///
    /// A dismissal on top of a write that did not land is the silent loss this
    /// whole path exists to prevent: the view is gone, the core is unloaded, and
    /// the bytes the player earned are nowhere. On a failure the message the
    /// flush published is already on screen and the overlay stays exactly where
    /// it is, with Retry Save under the player's thumb.
    private func quitIfSaved() {
        do {
            try engine?.flushSaveNow(reason: .quit)
            dismiss()
        } catch {
            // Deliberately empty. `onLocalSaveFailure` fired on the way out of
            // that flush, so the reason is on screen; there is nothing to add and
            // nothing to dismiss.
        }
    }

    /// Says what a previous session could not: that its last write did not land.
    ///
    /// There is one way out of a game that never reaches the overlay — backing
    /// out with the Siri remote's Menu button, which dismisses this view and
    /// only then lets `EmulatorEngine.stop()` take its final flush. A failure
    /// there has no screen to appear on, so it is written down
    /// (`UnwrittenCardNote`) and delivered here, the first time an overlay opens
    /// in a later session, exactly once.
    ///
    /// A failure this session already has outranks it and leaves the note
    /// standing: the live one is the one the player can still act on, and the
    /// note will keep until an overlay opens without one.
    private func deliverUnwrittenCardNote() {
        guard saveFailure == nil,
              UnwrittenCardNote.exists(romID: launch.canonicalRomID) else { return }
        UnwrittenCardNote.clear(romID: launch.canonicalRomID)
        saveFailure = .lastSessionUnwritten
    }

    /// Controller-disconnect safety: the engine has already paused and
    /// zeroed buttons by the time this fires — just make sure the overlay
    /// is actually on screen. Unlike `toggleOverlay`, this never hides it.
    /// The periodic save failure comes through here too, for the same reason:
    /// the game has already been stopped and the overlay is where the message
    /// and Retry Save live — so the picker, which would be on top of it, closes.
    private func forceShowOverlay() {
        showDiscPicker = false
        showOverlay = true
    }
}

// GCEventViewController with controllerUserInteractionEnabled = false keeps
// game-controller presses (Menu/B/…) out of tvOS focus/back navigation — so
// Start doesn't exit the game — while the Siri remote's Menu still backs out.
private final class EmulatorHostController: GCEventViewController {
    let mtkView = MTKView()
    override func loadView() { view = mtkView }
}

private struct MetalHostRepresentable: UIViewControllerRepresentable {
    let launch: PreparedLaunch
    @Binding var startFailure: String?
    // When true, the SwiftUI pause overlay is on screen. controllerUserInteractionEnabled
    // suppresses ALL pad-driven UIKit focus-engine translation while this
    // GCEventViewController is part of the active hierarchy — not just
    // within its own view subtree — so it also blocks the Xbox pad's d-pad
    // from reaching the overlay's SwiftUI buttons (which live as a sibling
    // layer above the representable, not inside it). Flip it on only while
    // the overlay is visible so the pad can navigate the overlay, then back
    // to false on resume so Start/B don't drive tvOS back-navigation during
    // gameplay again. The Siri remote's focus/select never goes through this
    // flag, so it works in both states.
    let showOverlay: Bool
    let onEngineReady: (EmulatorEngine) -> Void
    let onOverlayRequested: () -> Void
    let onPauseRequested: () -> Void
    let onLocalSaveFailure: (EmulatorSaveFailure?) -> Void

    final class Coordinator {
        var engine: EmulatorEngine?
        var renderer: MetalRenderer?
        var drawLink: CADisplayLink?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> EmulatorHostController {
        let controller = EmulatorHostController()
        controller.controllerUserInteractionEnabled = showOverlay
        let view = controller.mtkView
        let renderer = MetalRenderer(view: view)
        let engine = EmulatorEngine(renderer: renderer)
        context.coordinator.renderer = renderer
        context.coordinator.engine = engine
        engine.onOverlayRequested = onOverlayRequested
        engine.onPauseRequested = onPauseRequested
        engine.onLocalSaveFailure = onLocalSaveFailure
        do {
            try engine.start(launch)
            // Drive draws at 60 too — after the core ran, present its frame.
            let link = CADisplayLink(target: view, selector: #selector(MTKView.draw as (MTKView) -> () -> Void))
            link.add(to: .main, forMode: .common)
            context.coordinator.drawLink = link
            DispatchQueue.main.async { onEngineReady(engine) }
        } catch {
            // `EmulatorEngine.start` has already unloaded the core it constructed
            // — a constructed core owns the process-wide slot, and not releasing
            // it would mean no game could start until the app was relaunched —
            // and the prepared package on disk is untouched, which is what makes
            // launching again a real remedy rather than a hope.
            DispatchQueue.main.async { startFailure = error.localizedDescription }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: EmulatorHostController, context: Context) {
        uiViewController.controllerUserInteractionEnabled = showOverlay
    }
    static func dismantleUIViewController(_ uiViewController: EmulatorHostController,
                                          coordinator: Coordinator) {
        coordinator.drawLink?.invalidate()
        // The view is being torn down, so the final flush inside `stop()` has
        // nowhere to publish to: setting SwiftUI state from here is a mutation
        // during a view update on a view that is already gone. The Quit path has
        // blocked on its own flush before reaching this point.
        coordinator.engine?.onLocalSaveFailure = nil
        coordinator.engine?.stop()
    }
}

/// The pause overlay, and — when a write has failed — the only place a player
/// can see that it did and do something about it.
///
/// Internal rather than private so the argument-gated UI-test fixture can drive
/// this exact view over a real `EmulatorSaveFlow`. It has no engine, no core and
/// no state of its own: the message is handed to it, and the three save-relevant
/// decisions (retry, quit, and whether Quit may leave) belong to the caller that
/// owns the flow.
struct PauseOverlayView: View {
    /// Non-nil when the last flush did not reach the local card.
    let saveFailure: EmulatorSaveFailure?
    /// This session's discs, or `nil` when there is no disc state at all — which
    /// is every launch until the game has loaded. A flow whose availability is
    /// `.single` shows nothing either, which is every legacy and one-disc game.
    var discs: DiscSwitchFlow?
    /// Where the memory card's server half stands. `.idle` shows nothing, and is
    /// what a legacy launch always has.
    var syncStatus: PS1SaveSyncStatus = .idle
    let onResume: () -> Void
    let onRestart: () -> Void
    /// Opens the disc picker. Only reachable when `discs` offers switching.
    var onChangeDisc: () -> Void = {}
    /// Runs a `.user` flush. The message clears only if it lands, which is
    /// `EmulatorSaveFlow`'s rule and not this view's.
    let onRetrySave: () -> Void
    /// Asks the uploader to send what is owed now, under `.user`. Fire and
    /// forget: it hands work to an actor and returns, so gameplay is never
    /// waiting on a server.
    var onRetrySync: () -> Void = {}
    /// Called for a Quit. The caller flushes first and dismisses only on success,
    /// so pressing this with a failing card leaves the player exactly here.
    let onQuit: () -> Void

    private enum Focusable: Hashable { case resume, changeDisc, restart, retrySave, retrySync, quit }
    @FocusState private var focused: Focusable?

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Paused").font(.title2)
                if let saveFailure {
                    VStack(spacing: 8) {
                        Text(saveFailure.message)
                            .font(.callout).multilineTextAlignment(.center)
                            .accessibilityIdentifier("pause.saveFailure")
                        Text(saveFailure.recovery)
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("pause.saveRecovery")
                    }
                    .frame(maxWidth: 900)
                }
                if let discs, discs.showsDiscSection {
                    DiscStatusView(flow: discs)
                }
                if let message = syncStatus.overlayMessage {
                    Text(message)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .accessibilityIdentifier("pause.syncStatus")
                }
                Button("Resume", action: onResume)
                    .focused($focused, equals: .resume)
                    .accessibilityIdentifier("pause.resume")
                // Offered only when the labels, the interface and the counts all
                // agree — see `DiscSwitchAvailability.resolve`. `select` refuses
                // on the same state, so hiding the button is not what makes a
                // disabled session safe.
                if let discs, discs.canSwitch {
                    Button("Change Disc", action: onChangeDisc)
                        .focused($focused, equals: .changeDisc)
                        .accessibilityIdentifier("pause.changeDisc")
                }
                Button("Restart Game", action: onRestart)
                    .focused($focused, equals: .restart)
                    .accessibilityIdentifier("pause.restart")
                if saveFailure != nil {
                    Button("Retry Save", action: onRetrySave)
                        .focused($focused, equals: .retrySave)
                        .accessibilityIdentifier("pause.retrySave")
                }
                if syncStatus.offersSyncRetry {
                    Button("Retry Sync", action: onRetrySync)
                        .focused($focused, equals: .retrySync)
                        .accessibilityIdentifier("pause.retrySync")
                }
                Button("Quit to Library", action: onQuit)
                    .focused($focused, equals: .quit)
                    .accessibilityIdentifier("pause.quit")
            }
            .frame(maxWidth: 900)
        }
        // A failure opens on Retry Save: it is the remedy, and Quit — one press
        // away — is the thing that would lose the save. Deliberately unchanged by
        // the disc and sync additions: neither of them is a remedy for a card
        // that could not be written, and neither outranks one.
        .onAppear { focused = saveFailure == nil ? .resume : .retrySave }
    }
}

/// What the pause overlay says about discs: which one is in the drive when that
/// can be said honestly, and why switching is off when it is.
///
/// `@ObservedObject` rather than a snapshot: the flow re-reads the drive after
/// every attempt, and this line has to follow it rather than the index the
/// player asked for.
private struct DiscStatusView: View {
    @ObservedObject var flow: DiscSwitchFlow

    var body: some View {
        VStack(spacing: 8) {
            if flow.canSwitch {
                Text("Current disc: \(flow.currentDiscDescription)")
                    .font(.callout)
                    .accessibilityIdentifier("pause.currentDisc")
            }
            if let note = flow.note {
                Text(note)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pause.discNote")
            }
        }
        .frame(maxWidth: 900)
    }
}

/// The disc picker: the disc in the drive, every disc this game has, and a way
/// back.
///
/// It is only ever presented over a paused game, and every path out of it —
/// choosing a disc that lands, Cancel, Menu, the pad's B — returns to the pause
/// overlay rather than to the game, so nothing here can resume play behind a
/// choice that has not been made.
///
/// A failed switch keeps this on screen with the message under the list and the
/// drive's *actual* disc at the top, because trying the same disc again is the
/// first thing worth doing and the second is knowing what is in there now.
struct DiscPickerView: View {
    @ObservedObject var flow: DiscSwitchFlow
    let onDone: () -> Void

    private enum Focusable: Hashable { case disc(Int), cancel }
    @FocusState private var focused: Focusable?

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Change Disc").font(.title2)
                Text("Current disc: \(flow.currentDiscDescription)")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("disc.current")
                if let failure = flow.failure {
                    Text(failure)
                        .font(.callout).multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .accessibilityIdentifier("disc.failure")
                }
                ForEach(Array(flow.availability.labels.enumerated()), id: \.offset) { index, label in
                    Button(action: { choose(index) }) {
                        Text(flow.isCurrent(index) ? "\(label) (in the drive)" : label)
                    }
                    .focused($focused, equals: .disc(index))
                    .accessibilityIdentifier("disc.option.\(index)")
                }
                Button("Cancel", action: onDone)
                    .focused($focused, equals: .cancel)
                    .accessibilityIdentifier("disc.cancel")
            }
            .frame(maxWidth: 900)
        }
        // Opens on the disc in the drive when there is one to open on, and on
        // Cancel when the drive cannot say — a picker that opened on a row that
        // does not exist would open on nothing at all.
        .onAppear {
            let discs = flow.availability.labels.indices
            focused = flow.currentIndex.flatMap { discs.contains($0) ? Focusable.disc($0) : nil }
                ?? .cancel
        }
    }

    /// The picker closes only when the drive did what was asked. A failure keeps
    /// it open with `flow.failure` under the list — and with the index re-read,
    /// so "Current disc" above is the drive's answer rather than this view's
    /// hope.
    private func choose(_ index: Int) {
        switch flow.select(index) {
        case .switched, .alreadyInserted:
            onDone()
        case .failed:
            break
        }
    }
}

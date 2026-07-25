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

    var body: some View {
        Group {
            if let startFailure {
                startFailureView(startFailure)
            } else {
                ZStack {
                    MetalHostRepresentable(launch: launch,
                                           startFailure: $startFailure,
                                           showOverlay: showOverlay,
                                           onEngineReady: { engine = $0 },
                                           onOverlayRequested: toggleOverlay,
                                           onPauseRequested: forceShowOverlay,
                                           onLocalSaveFailure: { saveFailure = $0 })
                        .ignoresSafeArea()
                    if showOverlay {
                        PauseOverlayView(
                            saveFailure: saveFailure,
                            onResume: resumeAndHideOverlay,
                            onRestart: {
                                engine?.restartGame()
                                resumeAndHideOverlay()
                            },
                            onRetrySave: { try? engine?.flushSaveNow(reason: .user) },
                            onQuit: quitIfSaved)
                    }
                }
                // Siri remote's play/pause button opens/closes the overlay.
                // The Xbox pad's left-stick click reaches the same toggle via
                // EmulatorEngine.onOverlayRequested (wired in
                // MetalHostRepresentable) — see ControllerInput.swift.
                .onPlayPauseCommand(perform: toggleOverlay)
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    // Leaving the app is a moment the card has to be on disk. The
                    // game stops where it is and the overlay comes up, so a
                    // failure that happened while nobody was looking is the first
                    // thing on screen when the player comes back.
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

    /// Controller-disconnect safety: the engine has already paused and
    /// zeroed buttons by the time this fires — just make sure the overlay
    /// is actually on screen. Unlike `toggleOverlay`, this never hides it.
    /// The periodic save failure comes through here too, for the same reason:
    /// the game has already been stopped and the overlay is where the message
    /// and Retry Save live.
    private func forceShowOverlay() {
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
    let onResume: () -> Void
    let onRestart: () -> Void
    /// Runs a `.user` flush. The message clears only if it lands, which is
    /// `EmulatorSaveFlow`'s rule and not this view's.
    let onRetrySave: () -> Void
    /// Called for a Quit. The caller flushes first and dismisses only on success,
    /// so pressing this with a failing card leaves the player exactly here.
    let onQuit: () -> Void

    private enum Focusable: Hashable { case resume, restart, retrySave, quit }
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
                Button("Resume", action: onResume)
                    .focused($focused, equals: .resume)
                    .accessibilityIdentifier("pause.resume")
                Button("Restart Game", action: onRestart)
                    .focused($focused, equals: .restart)
                    .accessibilityIdentifier("pause.restart")
                if saveFailure != nil {
                    Button("Retry Save", action: onRetrySave)
                        .focused($focused, equals: .retrySave)
                        .accessibilityIdentifier("pause.retrySave")
                }
                Button("Quit to Library", action: onQuit)
                    .focused($focused, equals: .quit)
                    .accessibilityIdentifier("pause.quit")
            }
            .frame(maxWidth: 900)
        }
        // A failure opens on Retry Save: it is the remedy, and Quit — one press
        // away — is the thing that would lose the save.
        .onAppear { focused = saveFailure == nil ? .resume : .retrySave }
    }
}

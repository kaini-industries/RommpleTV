import SwiftUI
import MetalKit
import GameController

struct EmulatorHostView: View {
    let romURL: URL
    let coreName: String
    let romID: Int
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?
    @State private var showOverlay = false
    @State private var engine: EmulatorEngine?

    var body: some View {
        Group {
            if let errorText {
                VStack(spacing: 16) {
                    Text("Can't start emulation").font(.title3)
                    Text(errorText).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    MetalHostRepresentable(romURL: romURL, coreName: coreName, romID: romID,
                                           errorText: $errorText,
                                           showOverlay: showOverlay,
                                           onEngineReady: { engine = $0 },
                                           onOverlayRequested: toggleOverlay,
                                           onPauseRequested: forceShowOverlay)
                        .ignoresSafeArea()
                    if showOverlay {
                        PauseOverlayView(
                            onResume: resumeAndHideOverlay,
                            onRestart: {
                                engine?.restartGame()
                                resumeAndHideOverlay()
                            },
                            onQuit: { dismiss() })
                    }
                }
                // Siri remote's play/pause button opens/closes the overlay.
                // The Xbox pad's left-stick click reaches the same toggle via
                // EmulatorEngine.onOverlayRequested (wired in
                // MetalHostRepresentable) — see ControllerInput.swift.
                .onPlayPauseCommand(perform: toggleOverlay)
            }
        }
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

    /// Controller-disconnect safety: the engine has already paused and
    /// zeroed buttons by the time this fires — just make sure the overlay
    /// is actually on screen. Unlike `toggleOverlay`, this never hides it.
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
    let romURL: URL
    let coreName: String
    let romID: Int
    @Binding var errorText: String?
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
        do {
            try engine.start(romURL: romURL, coreName: coreName, romID: romID)
            // Drive draws at 60 too — after the core ran, present its frame.
            let link = CADisplayLink(target: view, selector: #selector(MTKView.draw as (MTKView) -> () -> Void))
            link.add(to: .main, forMode: .common)
            context.coordinator.drawLink = link
            DispatchQueue.main.async { onEngineReady(engine) }
        } catch {
            DispatchQueue.main.async { errorText = error.localizedDescription }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: EmulatorHostController, context: Context) {
        uiViewController.controllerUserInteractionEnabled = showOverlay
    }
    static func dismantleUIViewController(_ uiViewController: EmulatorHostController,
                                          coordinator: Coordinator) {
        coordinator.drawLink?.invalidate()
        coordinator.engine?.stop()
    }
}

private struct PauseOverlayView: View {
    let onResume: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void

    private enum Focusable: Hashable { case resume, restart, quit }
    @FocusState private var focused: Focusable?

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Paused").font(.title2)
                Button("Resume", action: onResume)
                    .focused($focused, equals: .resume)
                Button("Restart Game", action: onRestart)
                    .focused($focused, equals: .restart)
                Button("Quit to Library", action: onQuit)
                    .focused($focused, equals: .quit)
            }
            .frame(maxWidth: 600)
        }
        .onAppear { focused = .resume }
    }
}

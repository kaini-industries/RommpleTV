import GameController
import RommpleTVKit

final class ControllerInput {
    private var handler: ((RetroButton, Bool) -> Void)?
    private var overlayHandler: (() -> Void)?
    private var disconnectHandler: (() -> Void)?
    /// The block-based observers this instance registered.
    ///
    /// Kept because `addObserver(forName:object:queue:using:)` returns a token
    /// that is the *only* way to deregister — the observer it creates is an
    /// opaque object, not `self`, so `removeObserver(self)` would not touch it.
    /// Without this, one pair of registrations accumulated on the default center
    /// per game launched. They captured `[weak self]`, so nothing misbehaved,
    /// but every pad connect/disconnect walked a list that only ever grew.
    private var observers: [NSObjectProtocol] = []

    func attach(_ handler: @escaping (RetroButton, Bool) -> Void) {
        self.handler = handler
        // Idempotent: a second attach replaces the first rather than doubling it.
        removeObservers()
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in self?.mapAll() })
        // A dead battery or an out-of-range pad should not leave the game
        // holding whatever direction/button was pressed at the moment of
        // disconnect — the engine zeroes all buttons in response to this.
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in self?.disconnectHandler?() })
        mapAll()
    }

    /// Hands the registrations back. Called from `deinit`, which runs when
    /// `EmulatorEngine` is released — after `dismantleUIViewController` has torn
    /// the game down — so a session's observers do not outlive it.
    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    deinit { removeObservers() }

    /// Registers the pause-overlay trigger for the Xbox pad's left-stick
    /// click (`leftThumbstickButton`) — the Siri remote's play/pause
    /// command is handled separately, directly in SwiftUI.
    func onOverlayRequested(_ handler: @escaping () -> Void) {
        overlayHandler = handler
    }

    /// Registers the controller-disconnect safety trigger (see attach()).
    func onDisconnect(_ handler: @escaping () -> Void) {
        disconnectHandler = handler
    }

    /// How far a trigger travels before the core is told the button is down, and
    /// how far back before it is told it is up.
    ///
    /// A PlayStation Controller's L2/R2 are digital microswitches — there is no
    /// half-press to forward — while every pad tvOS supports reports its triggers
    /// as an analogue axis, so the conversion has to happen somewhere and where
    /// it happens is felt rather than incidental. 0.25 registers early in the
    /// travel, which is what a player cycling weapons or paging a menu expects,
    /// and sits well clear of the small non-zero value a slack trigger can rest
    /// at on a third-party pad.
    ///
    /// The two numbers are deliberately different. On a single threshold, a
    /// trigger held right at it flips the button on and off with the noise and
    /// the core reads a burst of taps; nothing can cross a 0.10 deadband by
    /// jitter. `pressedChangedHandler` is not used here for the same reason —
    /// what it calls "pressed" is the framework's own analogue-travel decision,
    /// which this layer has no say over and cannot give a deadband to.
    private static let triggerPress: Float = 0.25
    private static let triggerRelease: Float = 0.15

    private func mapAll() {
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            // The default, pinned rather than assumed. Every handler below ends
            // in `EmulatorEngine`, and the overlay one reaches `pause()`, which
            // flushes the save through `MainActor.assumeIsolated` — that traps
            // rather than misbehaving quietly if it is ever called from anywhere
            // but the main thread, so which queue GameController delivers on is
            // load-bearing and is stated here.
            controller.handlerQueue = .main
            let send = { [weak self] (b: RetroButton, pressed: Bool) in
                self?.handler?(b, pressed)
            }
            // Positional mapping: Xbox A (bottom) = SNES B, Xbox B (right) = SNES A,
            // Xbox X (left) = SNES Y, Xbox Y (top) = SNES X.
            pad.buttonA.pressedChangedHandler = { _, _, p in send(.b, p) }
            pad.buttonB.pressedChangedHandler = { _, _, p in send(.a, p) }
            pad.buttonX.pressedChangedHandler = { _, _, p in send(.y, p) }
            pad.buttonY.pressedChangedHandler = { _, _, p in send(.x, p) }
            pad.leftShoulder.pressedChangedHandler = { _, _, p in send(.l, p) }
            pad.rightShoulder.pressedChangedHandler = { _, _, p in send(.r, p) }
            pad.buttonMenu.pressedChangedHandler = { _, _, p in send(.start, p) }
            pad.buttonOptions?.pressedChangedHandler = { _, _, p in send(.select, p) }
            // L2/R2. Analogue on the pad, digital to the core — see
            // `triggerPress` for where the line is drawn and why there are two of
            // them. `isDown` is per-binding state and is the deadband: without a
            // memory of which side the trigger was last on, there is nothing to
            // be hysteretic about.
            func bindTrigger(_ input: GCControllerButtonInput, to button: RetroButton) {
                // Seeded from where the trigger actually is, not from `false`.
                // `mapAll` runs again whenever any pad connects, so a rebind can
                // land mid-hold — and a binding that assumed "up" would answer
                // the release with "no change" and leave the core holding a
                // button nothing will ever lift.
                var isDown = input.value >= Self.triggerPress
                input.valueChangedHandler = { _, value, _ in
                    let down = isDown ? value > Self.triggerRelease
                                      : value >= Self.triggerPress
                    guard down != isDown else { return }
                    isDown = down
                    send(button, down)
                }
            }
            bindTrigger(pad.leftTrigger, to: .l2)
            bindTrigger(pad.rightTrigger, to: .r2)
            // R3 (right stick click). L3 is not sent to the core — see the
            // overlay binding at the end of this function.
            pad.rightThumbstickButton?.pressedChangedHandler = { _, _, p in send(.r3, p) }
            pad.dpad.valueChangedHandler = { _, x, y in
                send(.left, x < -0.5); send(.right, x > 0.5)
                send(.down, y < -0.5); send(.up, y > 0.5)
            }
            pad.leftThumbstick.valueChangedHandler = { _, x, y in
                send(.left, x < -0.5); send(.right, x > 0.5)
                send(.down, y < -0.5); send(.up, y > 0.5)
            }
            // Left-stick click opens/closes the pause overlay, so L3 is the one
            // libretro id this pad never sends. With L2/R2/R3 now mapped there
            // is no spare input left: every other control is a game button, and
            // the pad needs *some* way to reach the overlay, which is where the
            // save failure, Retry Save, Change Disc and Quit all live — a game
            // that cannot be paused is a game whose card cannot be written on
            // purpose. Keeping the overlay on L3 rather than moving it to R3
            // also leaves the seven hardware-accepted systems' pause gesture
            // exactly where players already have it; either way one stick click
            // is spent, and this is the one PlayStation asks for least.
            // buttonOptions stays mapped to Select above.
            pad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.overlayHandler?() }
            }
        }
    }
}

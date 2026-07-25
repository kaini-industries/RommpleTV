import GameController
import RommpleTVKit

final class ControllerInput {
    private var handler: ((RetroButton, Bool) -> Void)?
    private var overlayHandler: (() -> Void)?
    private var disconnectHandler: (() -> Void)?

    func attach(_ handler: @escaping (RetroButton, Bool) -> Void) {
        self.handler = handler
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in self?.mapAll() }
        // A dead battery or an out-of-range pad should not leave the game
        // holding whatever direction/button was pressed at the moment of
        // disconnect — the engine zeroes all buttons in response to this.
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in self?.disconnectHandler?() }
        mapAll()
    }

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
            pad.dpad.valueChangedHandler = { _, x, y in
                send(.left, x < -0.5); send(.right, x > 0.5)
                send(.down, y < -0.5); send(.up, y > 0.5)
            }
            pad.leftThumbstick.valueChangedHandler = { _, x, y in
                send(.left, x < -0.5); send(.right, x > 0.5)
                send(.down, y < -0.5); send(.up, y > 0.5)
            }
            // Left-stick click opens/closes the pause overlay. buttonOptions
            // stays mapped to SNES Select above — this is the pad's only
            // spare input for the overlay trigger.
            pad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.overlayHandler?() }
            }
        }
    }
}

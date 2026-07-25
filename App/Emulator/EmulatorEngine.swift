import Foundation
import QuartzCore
import AVFoundation
import RommpleTVKit

final class EmulatorEngine: NSObject, CoreAVSink {
    private var core: LibretroCore?
    private let renderer: MetalRenderer
    private let audioRing = AudioRing()
    private let controller = ControllerInput()
    private var audioEngine: AVAudioEngine?
    private var displayLink: CADisplayLink?
    private(set) var isPaused = false

    // Audio-ring-driven pacing. Seeded with a reasonable default so `tick()`
    // never needs an optional-unwrap on the hot path; `start()` replaces it
    // with the real core's fps/sampleRate once `loadGame` reports `avInfo`.
    private var pacer = AudioPacer.standard(sampleRate: 44100, fps: 60)

    // Battery-save (SRAM) lifecycle. The store and the ROM id that owns the save
    // both arrive on `PreparedLaunch`; the engine chooses neither.
    private var launch: PreparedLaunch?
    private var lastFlushedSRAM: Data?
    private var ticksSinceFlush = 0
    private static let flushIntervalTicks = 600   // ~10s at 60Hz

    /// The order in which a save reaches disk and then the server, and the state
    /// a player sees when the first half fails. Built in `start` from the two
    /// callbacks `PreparedLaunch` carries — both no-ops on a legacy launch, which
    /// has no server-side save at all.
    ///
    /// The rule lives there rather than here because `EmulatorEngine` cannot be
    /// exercised without a core, a display link and an audio engine, and "the
    /// upload is never scheduled after a failed local write" is exactly the kind
    /// of invariant that has to be provable.
    private var saveFlow: EmulatorSaveFlow?

    /// Which discs this session may switch between and which one is in the
    /// drive, or `nil` before a game is loaded.
    ///
    /// Built once, in `start`, immediately after `loadGame` — the first moment
    /// the core's Disk Control registration and disc count are both real — and
    /// handed to the pause overlay. The engine keeps no disc state of its own:
    /// the flow re-reads the core after every attempt, which is the only way the
    /// index on screen is the index in the drive.
    private(set) var discFlow: DiscSwitchFlow?

    /// Fired when the controller layer wants the pause overlay toggled
    /// (Xbox pad's left-stick click). The Siri remote's play/pause command
    /// is wired directly from SwiftUI instead, since it isn't a
    /// GameController-framework input.
    var onOverlayRequested: (() -> Void)?

    /// Fired when a controller disconnects mid-game: the engine has already
    /// zeroed all buttons and called `pause()` by the time this fires — the
    /// view only needs to make sure the pause overlay is actually on screen.
    /// Deliberately separate from `onOverlayRequested`, which is wired to a
    /// *toggle*: reusing it here would resume the game instead of pausing it
    /// if the overlay was already showing when the disconnect happened.
    var onPauseRequested: (() -> Void)?

    /// Fired after **every** flush with whatever the save flow now has to say —
    /// a failure, or `nil` once a later write has landed and the message is no
    /// longer true.
    ///
    /// Deliberately not the startup `errorText`, which replaces the game view: a
    /// save that could not be written must not throw away the running game, and
    /// the player has to be able to keep playing, retry, or quit knowingly.
    var onLocalSaveFailure: ((EmulatorSaveFailure?) -> Void)?

    enum EngineError: LocalizedError {
        case coreNotBundled(String)
        var errorDescription: String? {
            switch self {
            case .coreNotBundled(let name):
                return "Core \(name).dylib is not in this build "
                     + "(simulator builds have no cores — run on the Apple TV)."
            }
        }
    }

    init(renderer: MetalRenderer) { self.renderer = renderer }

    /// Starts the game a `LaunchPreparationService` prepared.
    ///
    /// Every path this used to compute now arrives on the value. That matters
    /// for more than tidiness: the system directory used to be a fixed
    /// `Caches/system` regardless of platform, which is the wrong directory for
    /// PlayStation — Beetle PSX reads its BIOS from the one
    /// `PS1FirmwareManager` owns and installs into, and a core pointed at an
    /// empty system directory boots to a black screen with no error.
    func start(_ launch: PreparedLaunch) throws {
        let coreName = launch.core.coreName
        guard let fwPath = Bundle.main.privateFrameworksPath,
              FileManager.default.fileExists(atPath: "\(fwPath)/\(coreName).dylib")
        else { throw EngineError.coreNotBundled(coreName) }

        // Both are inside Caches, which with tmp is all a tvOS app may write to.
        // Creating them here is idempotent: the firmware manager has already
        // created its own, and a legacy launch has nothing to create them.
        try FileManager.default.createDirectory(at: launch.systemDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launch.saveDirectory,
                                                withIntermediateDirectories: true)

        let core = try LibretroCore(dylibPath: "\(fwPath)/\(coreName).dylib",
                                    systemDirectory: launch.systemDirectory,
                                    saveDirectory: launch.saveDirectory)
        core.sink = self

        let restored: Data?
        do {
            try core.loadGame(at: launch.entryURL)
            // A read failure is propagated rather than swallowed: treating an
            // unreadable save as a missing one starts the game on a blank
            // battery and the next flush writes that blank over the real one.
            // It reaches the player as the "Can't start emulation" screen, which
            // offers a way back to the library and leaves the card untouched.
            restored = try launch.saveStore.load(romID: launch.canonicalRomID)
        } catch {
            // A constructed core owns the process-wide gCore slot; failing to
            // start must release it or no game can ever start until relaunch.
            core.unload()
            throw error
        }
        self.core = core
        self.launch = launch
        if let restored {
            core.restoreRAM(restored)
            // Freshly restored data already matches disk — don't re-flush it
            // on the very first 600-tick boundary.
            lastFlushedSRAM = restored
        }
        // The whole remote half of the save session, in four lines and in one
        // place. `onLocalSave` hands the uploader bytes that are already on disk
        // and lets its debounce decide when they go out; `retrySaveSync` is the
        // "do it now" every reason except the tick asks for. Both are no-ops on a
        // legacy launch, and neither can be reached from a failed local write —
        // `EmulatorSaveFlow` is what makes that structural rather than careful.
        //
        // `assumeIsolated` and not a hop: this is `makeUIViewController`, and a
        // hop would leave the engine running frames before the flow exists.
        MainActor.assumeIsolated {
            self.saveFlow = EmulatorSaveFlow(
                localFlush: { [weak self] in try self?.flushSRAMIfNeeded() },
                scheduleRemote: { request in
                    if let bytes = request.bytes { launch.onLocalSave(bytes) }
                    if let reason = request.retry { launch.retrySaveSync(reason) }
                })
            // Settled here rather than when the overlay opens: `discCount` and
            // the Disk Control registration are answers about the *loaded game*,
            // and `loadGame` above is what produced them. Every seam goes through
            // `self` so that a core unloaded from under an open picker answers
            // "no game" instead of calling into an unmapped image.
            self.discFlow = DiscSwitchFlow(
                labels: launch.discLabels,
                seams: DiscSwitchSeams(
                    hasDiskControl: { [weak self] in self?.core?.hasDiskControl ?? false },
                    discCount: { [weak self] in self?.core?.discCount ?? 0 },
                    currentIndex: { [weak self] in self?.core?.currentDiscIndex },
                    isPaused: { [weak self] in self?.isPaused ?? false },
                    switchDisc: { [weak self] index in
                        guard let self else { throw DiscSwitchRefusal.noGameRunning }
                        try self.switchDisc(to: index)
                    }))
        }

        if let av = core.avInfo {
            renderer.setAspect(av.aspectRatio)
            startAudio(sampleRate: av.sampleRate)
            pacer = AudioPacer.standard(sampleRate: av.sampleRate, fps: av.fps)
        }
        controller.attach { [weak core] button, pressed in
            core?.setButton(button, pressed: pressed)
        }
        controller.onOverlayRequested { [weak self] in
            self?.onOverlayRequested?()
        }
        controller.onDisconnect { [weak self] in
            self?.handleControllerDisconnect()
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 59, maximum: 61,
                                                        preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate(); displayLink = nil
        audioEngine?.stop(); audioEngine = nil
        // Must flush while the core is still loaded — saveRAM() needs it. The
        // Quit button has already blocked on its own flush by the time this
        // runs; this is the last chance for every other way a game ends.
        //
        // And it is the one flush with nowhere to publish a failure: the view
        // that shows it is already being torn down, which is exactly what the
        // Siri remote's Menu button does. So a failure here is written down
        // instead, and the next session says so. See `UnwrittenCardNote`.
        if case .failed = runFlush(.quit), let launch {
            UnwrittenCardNote.record(romID: launch.canonicalRomID)
        }
        core?.unload(); core = nil
    }

    /// Stops game progression for the pause overlay. Idempotent. The audio
    /// engine is left running — with no new frames arriving, the ring
    /// empties and AudioRing.read() zero-fills the rest, so playback goes
    /// silent instead of glitching.
    func pause() {
        guard !isPaused else { return }
        suspendFrames()
        // A failed pause flush keeps the game paused — it already is — and puts
        // the reason on screen. Nothing here resumes on a failure.
        _ = runFlush(.pause)
    }

    /// Frames stop, nothing is written. `pause()` is this plus the flush, and the
    /// two are separated because the periodic-failure path arrives here having
    /// *just* had a write fail: reaching it through `pause()` would attempt the
    /// same write twice on one tick.
    private func suspendFrames() {
        guard !isPaused else { return }
        isPaused = true
        displayLink?.remove(from: .main, forMode: .common)
    }

    /// The app is leaving the foreground. Frames stop and the card is written
    /// under its own reason, so a failure that happens while nobody is looking is
    /// still on screen when the player comes back — `EmulatorSaveFlow` clears the
    /// message only on a later local success, and there is none while the app is
    /// away.
    func handleBackground() {
        suspendFrames()
        _ = runFlush(.background)
    }

    /// Writes the card now, for a reason that cannot wait out the ~10-second
    /// tick: pause, quit, backgrounding, or the player pressing Retry Save.
    ///
    /// Returns only once the local write has finished. Throws when it did not
    /// land — in which case **nothing was scheduled remotely** and the caller
    /// must not go through with whatever it was flushing for. That is what makes
    /// Quit a decision the player can still take back.
    func flushSaveNow(reason: EmulatorSaveTrigger) throws {
        if case let .failed(failure) = runFlush(reason) { throw failure }
    }

    /// The one funnel every flush in this file goes through, so there is a single
    /// place the overlay's message is produced.
    ///
    /// `assumeIsolated` rather than a hop, and the reason is the rule itself:
    /// every caller is already on the main thread — the display link is
    /// registered on `.main`, and pause, quit, background and Retry Save all
    /// arrive from SwiftUI — while a hop would let `flushSaveNow` return before
    /// the write it promises had happened.
    private func runFlush(_ trigger: EmulatorSaveTrigger) -> EmulatorSaveOutcome {
        MainActor.assumeIsolated {
            guard let saveFlow else { return EmulatorSaveOutcome.saved }
            let outcome = saveFlow.flush(trigger)
            onLocalSaveFailure?(saveFlow.failure)
            return outcome
        }
    }

    /// Re-admits the display link so `tick()` resumes driving `runFrame()`.
    /// Idempotent.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Restarts the running game in place (libretro retro_reset). Leaves
    /// pause state untouched — callers resume separately.
    func restartGame() {
        core?.resetGame()
    }

    /// Puts another disc in the drive.
    ///
    /// Two requirements, and they are the same requirement wearing two hats.
    /// `LibretroCore` is single-owner and every entry point on it is main-thread
    /// only, and `runFrame()` is driven by a display link registered on `.main`
    /// — so a switch that ran while frames were still arriving would eject a
    /// disc from under `retro_run`. That is undefined behaviour in C, not a
    /// dropped frame.
    ///
    /// `assumeIsolated` rather than a hop, for the same reason `runFlush` uses
    /// it: every caller is already on the main thread (this arrives from
    /// SwiftUI), and a hop would return before the switch had happened, leaving
    /// the picker to re-read a drive nothing had touched yet.
    ///
    /// Refused rather than made to wait when frames are still running.
    /// `DiscSwitchFlow` refuses this too, and this is not redundant with it: the
    /// flow's guard is what a player's press meets and what the tests pin, while
    /// this one is the promise the object holding the display link makes to the
    /// core, and it holds for any caller — including one added later that does
    /// not go through the flow.
    ///
    /// Throws without leaving the drive empty: the transaction and its
    /// best-effort restore both live in `LibretroCore.switchDisc`.
    func switchDisc(to index: Int) throws {
        try MainActor.assumeIsolated {
            guard let core else { throw DiscSwitchRefusal.noGameRunning }
            guard isPaused else { throw DiscSwitchRefusal.framesRunning }
            try core.switchDisc(to: index)
        }
    }

    /// A dead battery or an out-of-range pad shouldn't leave the game
    /// holding whatever was pressed at the moment of disconnect — zero every
    /// button, then pause exactly like the overlay would, and tell the view
    /// to make sure the overlay is actually visible (see `onPauseRequested`).
    private func handleControllerDisconnect() {
        RetroButton.allCases.forEach { core?.setButton($0, pressed: false) }
        pause()
        onPauseRequested?()
    }

    /// Audio-paced tick: the ring's buffered depth decides whether to run 0,
    /// 1, or 2 core frames this display-link callback (never more), then
    /// periodically flushes battery RAM if it changed. Runs on the main
    /// thread (CADisplayLink's .main/.common registration).
    @objc private func tick() {
        guard let core else { return }
        for _ in 0..<pacer.framesToRun(ringDepth: audioRing.depthFrames) { core.runFrame() }
        ticksSinceFlush += 1
        if ticksSinceFlush >= Self.flushIntervalTicks {
            ticksSinceFlush = 0
            if case .failed = runFlush(.periodic) {
                // A card that could not be written is not something to play
                // through: every frame after this one is progress that is not
                // being saved. Stop where the game is and put the overlay up, so
                // the reason is on screen and Retry Save is reachable.
                suspendFrames()
                onPauseRequested?()
            }
        }
    }

    /// Writes battery RAM to the store only if it changed since the last
    /// flush (avoids redundant Caches writes every ~10s for games with no
    /// battery-backed save, or one whose save hasn't changed).
    ///
    /// The local half of a flush and nothing else — same store, same ROM id,
    /// same "only if it changed" test as before the PlayStation work. The
    /// asynchronous upload that follows it on a PlayStation launch is scheduled
    /// by `EmulatorSaveFlow`, from the statement after the one that calls this,
    /// and only when this one returned.
    ///
    /// `lastFlushedSRAM` moves only after the write returns. Advancing it on a
    /// failed write would mark the dirty bytes as already saved, and the next
    /// flush would see "nothing changed" and skip the retry — one failed write
    /// would silently become a lost save. A throw leaves it exactly where it was,
    /// so the next flush tries the same bytes again.
    ///
    /// - Returns: the bytes written, or `nil` when the card had not changed.
    private func flushSRAMIfNeeded() throws -> Data? {
        guard let core, let launch, let sram = core.saveRAM() else { return nil }
        if let last = lastFlushedSRAM, last == sram { return nil }
        try launch.saveStore.save(sram, romID: launch.canonicalRomID)
        lastFlushedSRAM = sram
        return sram
    }

    private func startAudio(sampleRate: Double) {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: sampleRate, channels: 2,
                                   interleaved: true)!
        let ring = audioRing
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let ptr = abl[0].mData?.assumingMemoryBound(to: Int16.self) {
                ring.read(into: ptr, frameCount: Int(frameCount))
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? engine.start()
        audioEngine = engine
    }

    // MARK: CoreAVSink (called during retro_run on the main thread)
    func videoFrame(_ data: UnsafeRawPointer, width: Int, height: Int,
                    pitchBytes: Int, format: CorePixelFormat) {
        renderer.submitFrame(data, width: width, height: height,
                             pitchBytes: pitchBytes, format: format)
    }
    func audioFrames(_ samples: UnsafePointer<Int16>, frameCount: Int) {
        audioRing.write(samples, frameCount: frameCount)
    }
}

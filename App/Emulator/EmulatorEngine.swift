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

    // Battery-save (SRAM) lifecycle.
    private var saveStore: BatterySaveStore?
    private var romID: Int?
    private var lastFlushedSRAM: Data?
    private var ticksSinceFlush = 0
    private static let flushIntervalTicks = 600   // ~10s at 60Hz

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

    func start(romURL: URL, coreName: String, romID: Int) throws {
        guard let fwPath = Bundle.main.privateFrameworksPath,
              FileManager.default.fileExists(atPath: "\(fwPath)/\(coreName).dylib")
        else { throw EngineError.coreNotBundled(coreName) }

        // tvOS sandbox: only Caches and tmp are writable. snes9x needs no BIOS,
        // and battery saves are persisted separately, so cache volatility is fine.
        let support = FileManager.default.urls(for: .cachesDirectory,
                                               in: .userDomainMask)[0]
        let systemDir = support.appendingPathComponent("system", isDirectory: true)
        let saveDir = support.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: systemDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

        let core = try LibretroCore(dylibPath: "\(fwPath)/\(coreName).dylib",
                                    systemDirectory: systemDir, saveDirectory: saveDir)
        core.sink = self

        // Same Caches root the core's own system/save dirs live under.
        let saveStore = BatterySaveStore(cachesRoot: support)
        let restored: Data?
        do {
            try core.loadGame(at: romURL)
            // A read failure is propagated rather than swallowed: treating an
            // unreadable save as a missing one starts the game on a blank
            // battery and the next flush writes that blank over the real one.
            // Task 11 turns this into a message a player can act on.
            restored = try saveStore.load(romID: romID)
        } catch {
            // A constructed core owns the process-wide gCore slot; failing to
            // start must release it or no game can ever start until relaunch.
            core.unload()
            throw error
        }
        self.core = core
        self.romID = romID
        self.saveStore = saveStore
        if let restored {
            core.restoreRAM(restored)
            // Freshly restored data already matches disk — don't re-flush it
            // on the very first 600-tick boundary.
            lastFlushedSRAM = restored
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
        // Must flush while the core is still loaded — saveRAM() needs it.
        flushSRAMIfNeeded()
        core?.unload(); core = nil
    }

    /// Stops game progression for the pause overlay. Idempotent. The audio
    /// engine is left running — with no new frames arriving, the ring
    /// empties and AudioRing.read() zero-fills the rest, so playback goes
    /// silent instead of glitching.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        displayLink?.remove(from: .main, forMode: .common)
        flushSRAMIfNeeded()
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
            flushSRAMIfNeeded()
        }
    }

    /// Writes battery RAM to the store only if it changed since the last
    /// flush (avoids redundant Caches writes every ~10s for games with no
    /// battery-backed save, or one whose save hasn't changed).
    ///
    /// `lastFlushedSRAM` moves only after the write returns. Advancing it on a
    /// failed write would mark the dirty bytes as already saved, and the next
    /// flush would see "nothing changed" and skip the retry — one failed write
    /// would silently become a lost save.
    private func flushSRAMIfNeeded() {
        guard let core, let saveStore, let romID, let sram = core.saveRAM() else { return }
        if let last = lastFlushedSRAM, last == sram { return }
        do {
            try saveStore.save(sram, romID: romID)
            lastFlushedSRAM = sram
        } catch {
            // Keep the dirty value so the next flush tries again. Task 11 adds
            // the user-visible failure.
        }
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

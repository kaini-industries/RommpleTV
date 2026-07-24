import XCTest
@testable import RommpleTVKit

final class FrameCollector: CoreAVSink {
    var frames = 0
    var lastWidth = 0, lastHeight = 0, lastPitch = 0
    var audioFrameCount = 0
    var format: CorePixelFormat?
    func videoFrame(_ data: UnsafeRawPointer, width: Int, height: Int,
                    pitchBytes: Int, format: CorePixelFormat) {
        frames += 1; lastWidth = width; lastHeight = height
        lastPitch = pitchBytes; self.format = format
    }
    func audioFrames(_ samples: UnsafePointer<Int16>, frameCount: Int) {
        audioFrameCount += frameCount
    }
}

final class LibretroCoreTests: XCTestCase {
    static let corePath = FileManager.default.currentDirectoryPath
        + "/../Cores/macos/snes9x_libretro.dylib"

    func makeCore() throws -> LibretroCore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rommple-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return try LibretroCore(dylibPath: Self.corePath,
                                systemDirectory: tmp, saveDirectory: tmp)
    }
    func romURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "test", withExtension: "sfc",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("no optional test.sfc fixture")
        }
        return url
    }

    func testCoreLoadsAndReportsAVInfo() throws {
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        try core.loadGame(at: rom)
        let av = try XCTUnwrap(core.avInfo)
        XCTAssertGreaterThanOrEqual(av.baseWidth, 256)
        XCTAssertGreaterThanOrEqual(av.baseHeight, 224)
        XCTAssertEqual(av.fps, 60.0, accuracy: 1.0)
        XCTAssertGreaterThan(av.sampleRate, 30000)
    }

    func testRunProducesVideoAndAudio() throws {
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        let sink = FrameCollector()
        core.sink = sink
        try core.loadGame(at: rom)
        for _ in 0..<120 { core.runFrame() }   // 2 seconds
        XCTAssertGreaterThan(sink.frames, 30, "core should deliver non-dupe frames")
        XCTAssertEqual(sink.lastWidth, 256)
        XCTAssertGreaterThanOrEqual(sink.lastHeight, 224)
        XCTAssertEqual(sink.format, .rgb565)
        XCTAssertGreaterThan(sink.audioFrameCount, 32000, "≈1s+ of audio in 2s of frames")
    }

    func testInputAndSecondLoadDoNotCrash() throws {
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        let sink = FrameCollector()
        core.sink = sink
        try core.loadGame(at: rom)
        core.setButton(.start, pressed: true)
        for _ in 0..<30 { core.runFrame() }
        core.setButton(.start, pressed: false)
        core.unload()
        // singleton contract: a fresh instance after unload must work
        let core2 = try makeCore()
        defer { core2.unload() }
        try core2.loadGame(at: rom)
        core2.runFrame()
    }

    func testFCEUmmLoadsHeaderedNESROM() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rommple-fceumm-test", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var rom = Data([
            0x4E, 0x45, 0x53, 0x1A, // iNES magic
            0x01,                   // one 16 KiB PRG bank
            0x01,                   // one 8 KiB CHR bank
            0x00, 0x00,             // mapper 0, horizontal mirroring
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        var prg = Data(repeating: 0xEA, count: 16 * 1024)
        let program: [UInt8] = [
            0x78,             // SEI
            0xD8,             // CLD
            0xA2, 0xFF,       // LDX #$FF
            0x9A,             // TXS
            0x4C, 0x05, 0x80, // JMP $8005
        ]
        prg.replaceSubrange(0..<program.count, with: program)
        for vectorOffset in [0x3FFA, 0x3FFC, 0x3FFE] {
            prg[vectorOffset] = 0x00
            prg[vectorOffset + 1] = 0x80
        }
        rom.append(prg)
        rom.append(Data(repeating: 0, count: 8 * 1024))
        XCTAssertEqual(Array(rom.prefix(4)), [0x4E, 0x45, 0x53, 0x1A])

        let romURL = tmp.appendingPathComponent("minimal-nrom.nes")
        try rom.write(to: romURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: romURL) }

        let corePath = FileManager.default.currentDirectoryPath
            + "/../Cores/macos/fceumm_libretro.dylib"
        let core = try LibretroCore(dylibPath: corePath,
                                    systemDirectory: tmp, saveDirectory: tmp)
        defer { core.unload() }
        let sink = FrameCollector()
        core.sink = sink

        try core.loadGame(at: romURL)
        for _ in 0..<120 { core.runFrame() }

        XCTAssertGreaterThan(sink.frames, 30)
        XCTAssertGreaterThan(sink.audioFrameCount, 30_000)
    }

    func testMissingDylibThrows() {
        XCTAssertThrowsError(try LibretroCore(
            dylibPath: "/nonexistent.dylib",
            systemDirectory: FileManager.default.temporaryDirectory,
            saveDirectory: FileManager.default.temporaryDirectory))
    }

    func testBadDylibDoesNotBrickFutureCores() throws {
        // A real, dlopen-able dylib with none of the retro_* symbols: the
        // first symbol lookup inside init throws before any core state is
        // published. This must not leave the process unable to construct a
        // subsequent, correctly-configured core.
        XCTAssertThrowsError(try LibretroCore(
            dylibPath: "/usr/lib/libSystem.B.dylib",
            systemDirectory: FileManager.default.temporaryDirectory,
            saveDirectory: FileManager.default.temporaryDirectory))

        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        try core.loadGame(at: rom)
        core.runFrame()
    }

    func testDoubleUnloadIsSafe() throws {
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        try core.loadGame(at: rom)
        core.runFrame()
        core.unload()
        core.unload()   // must be a no-op, not a crash
    }

    func testSaveRAMRoundtrip() throws {
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        core.sink = FrameCollector()
        try core.loadGame(at: rom)
        for _ in 0..<30 { core.runFrame() }
        guard let sram = core.saveRAM(), !sram.isEmpty else {
            throw XCTSkip("fixture ROM exposes no battery RAM — use a battery-backed .sfc")
        }
        // Mutate a copy, restore it, and read it back.
        var mutated = sram
        mutated[0] = mutated[0] &+ 1
        XCTAssertTrue(core.restoreRAM(mutated))
        XCTAssertEqual(core.saveRAM()?[0], mutated[0])
        // Wrong-size restore must be rejected, not crash.
        XCTAssertFalse(core.restoreRAM(Data([1, 2, 3])))
    }

    func testResetGameContinuesRunning() throws {
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        let sink = FrameCollector()
        core.sink = sink
        try core.loadGame(at: rom)
        for _ in 0..<30 { core.runFrame() }
        let framesBeforeReset = sink.frames
        core.resetGame()   // must not crash
        for _ in 0..<30 { core.runFrame() }
        XCTAssertGreaterThan(sink.frames, framesBeforeReset,
                             "frames should keep arriving after resetGame()")
    }

    func testCoreErrorsAreReadable() {
        let e = CoreError.dlopenFailed("boom")
        XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        XCTAssertFalse(CoreError.alreadyLoaded.errorDescription!.contains("error 3"))
    }
}

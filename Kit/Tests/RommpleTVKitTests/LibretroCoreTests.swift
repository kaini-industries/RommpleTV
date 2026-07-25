import XCTest
import CLibretro
@testable import RommpleTVKit

// MARK: - Disk Control spies
//
// libretro's disk-control entry points are C function pointers, which cannot
// capture context — the production code routes its own callbacks through a
// file-scope `gCore` for exactly that reason. These spies do the same: two
// independent recorders so a test can tell which of the two registered
// interfaces a call actually reached.

/// Records every disk-control call in order and models just enough of a
/// drive (a disc index and a tray) that a rollback is observable.
final class DiskControlSpy {
    private(set) var log: [String] = []
    var imageCount: UInt32 = 2
    var imageIndex: UInt32 = 0
    var isEjected = false
    /// `set_eject_state(true)` refuses — a real core does this while the
    /// disc is still spinning.
    var refusesToOpen = false
    /// `set_image_index` refuses.
    var refusesNewDisc = false
    /// `set_eject_state(false)` refuses: the insertion failure.
    var refusesToClose = false

    func reset(imageCount: UInt32 = 2, imageIndex: UInt32 = 0) {
        log = []
        self.imageCount = imageCount
        self.imageIndex = imageIndex
        isEjected = false
        refusesToOpen = false
        refusesNewDisc = false
        refusesToClose = false
    }

    func setEjectState(_ ejected: Bool) -> Bool {
        log.append("setEject(\(ejected))")
        if ejected && refusesToOpen { return false }
        if !ejected && refusesToClose { return false }
        isEjected = ejected
        return true
    }
    func getEjectState() -> Bool { log.append("getEject"); return isEjected }
    func getImageIndex() -> UInt32 { log.append("getIndex"); return imageIndex }
    func setImageIndex(_ index: UInt32) -> Bool {
        log.append("setIndex(\(index))")
        if refusesNewDisc { return false }
        imageIndex = index
        return true
    }
    func getNumImages() -> UInt32 { log.append("numImages"); return imageCount }
}

nonisolated(unsafe) let legacySpy = DiskControlSpy()
nonisolated(unsafe) let extendedSpy = DiskControlSpy()

enum LegacySpyCallbacks {
    static let setEject: @convention(c) (Bool) -> Bool = { legacySpy.setEjectState($0) }
    static let getEject: @convention(c) () -> Bool = { legacySpy.getEjectState() }
    static let getIndex: @convention(c) () -> UInt32 = { legacySpy.getImageIndex() }
    static let setIndex: @convention(c) (UInt32) -> Bool = { legacySpy.setImageIndex($0) }
    static let numImages: @convention(c) () -> UInt32 = { legacySpy.getNumImages() }
    static let replace: @convention(c) (UInt32, UnsafePointer<retro_game_info>?) -> Bool
        = { _, _ in false }
    static let add: @convention(c) () -> Bool = { false }

    static var callback: retro_disk_control_callback {
        retro_disk_control_callback(
            set_eject_state: setEject, get_eject_state: getEject,
            get_image_index: getIndex, set_image_index: setIndex,
            get_num_images: numImages, replace_image_index: replace, add_image_index: add)
    }
}

enum ExtendedSpyCallbacks {
    static let setEject: @convention(c) (Bool) -> Bool = { extendedSpy.setEjectState($0) }
    static let getEject: @convention(c) () -> Bool = { extendedSpy.getEjectState() }
    static let getIndex: @convention(c) () -> UInt32 = { extendedSpy.getImageIndex() }
    static let setIndex: @convention(c) (UInt32) -> Bool = { extendedSpy.setImageIndex($0) }
    static let numImages: @convention(c) () -> UInt32 = { extendedSpy.getNumImages() }
    static let replace: @convention(c) (UInt32, UnsafePointer<retro_game_info>?) -> Bool
        = { _, _ in false }
    static let add: @convention(c) () -> Bool = { false }

    /// The three trailing entry points are documented as optional, so leaving
    /// them nil is what a real minimal core looks like.
    static var callback: retro_disk_control_ext_callback {
        retro_disk_control_ext_callback(
            set_eject_state: setEject, get_eject_state: getEject,
            get_image_index: getIndex, set_image_index: setIndex,
            get_num_images: numImages, replace_image_index: replace, add_image_index: add,
            set_initial_image: nil, get_image_path: nil, get_image_label: nil)
    }
}

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
        for error: CoreError in [.discControlUnavailable, .discSwitchFailed,
                                 .discIndexOutOfRange(index: 4, count: 2),
                                 // Rendering the message for an absurd index
                                 // must not trap on the 1-based conversion.
                                 .discIndexOutOfRange(index: .max, count: 2)] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty,
                           "\(error) needs a sentence a player can read")
        }
        XCTAssertTrue(CoreError.discIndexOutOfRange(index: 4, count: 2)
            .errorDescription!.contains("disc 5"), "discs read 1-based to a player")
    }

    // MARK: - Path-only loading

    static let psxCorePath = FileManager.default.currentDirectoryPath
        + "/../Cores/macos/mednafen_psx_libretro.dylib"

    /// The macOS cores are gitignored buildbot artifacts, so every test that
    /// dlopens one has to skip rather than fail on a clean checkout.
    func skipUnlessCorePresent(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("core dylib absent (gitignored): "
                          + URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    func scratchDirectory(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBeetlePSXReportsFullPathLoading() throws {
        try skipUnlessCorePresent(Self.psxCorePath)
        let dir = try scratchDirectory("rommple-psx-fullpath")
        let core = try LibretroCore(dylibPath: Self.psxCorePath,
                                    systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }
        XCTAssertTrue(core.needsFullPath,
                      "Beetle PSX opens the disc itself — it must not be handed bytes")
    }

    /// Which branch a core takes is the core's decision, not this app's — and
    /// two of the 2D cores answer differently from what the shape of the
    /// library suggests. Pinning every shipped answer means a core update
    /// that flips one shows up here rather than on the couch.
    func testShippedCoresReportTheirLoadingMode() throws {
        let expected: [(name: String, needsFullPath: Bool)] = [
            ("fceumm_libretro.dylib", true),           // NES: opens the file itself
            ("genesis_plus_gx_libretro.dylib", true),  // Genesis: likewise
            ("mednafen_psx_libretro.dylib", true),     // the core this task is for
            ("mednafen_vb_libretro.dylib", false),
            ("mgba_libretro.dylib", false),
            ("snes9x_libretro.dylib", false),
        ]
        let dir = try scratchDirectory("rommple-loading-mode")
        var checked = 0
        for core in expected {
            let path = FileManager.default.currentDirectoryPath
                + "/../Cores/macos/" + core.name
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let loaded = try LibretroCore(dylibPath: path,
                                          systemDirectory: dir, saveDirectory: dir)
            XCTAssertEqual(loaded.needsFullPath, core.needsFullPath, core.name)
            loaded.unload()
            checked += 1
        }
        try XCTSkipIf(checked == 0, "no core dylibs present (gitignored)")
    }

    static let gpgxCorePath = FileManager.default.currentDirectoryPath
        + "/../Cores/macos/genesis_plus_gx_libretro.dylib"

    /// Loads one synthetic cartridge through Genesis Plus GX's file route and
    /// asserts it really ran.
    ///
    /// GPGX's memory route (`memcpy` from `info->data`) returns early; the
    /// file route it takes now opens the file itself and derives the system
    /// from the *filename*. That hint is why each extension is worth its own
    /// cartridge rather than one standing in for the rest.
    private func runSegaCartridge(_ fileName: String, bytes: Data, in dir: URL) throws {
        let rom = dir.appendingPathComponent(fileName)
        try bytes.write(to: rom, options: .atomic)
        let core = try LibretroCore(dylibPath: Self.gpgxCorePath,
                                    systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }
        let sink = FrameCollector()
        core.sink = sink

        XCTAssertTrue(core.needsFullPath, fileName)
        try core.loadGame(at: rom)
        XCTAssertNil(core.romData, "\(fileName): nothing was read into memory")
        XCTAssertNotNil(core.gamePath.pointer, fileName)

        // GPGX implements Disk Control for Sega CD, so a *cartridge* has to
        // report no discs. Task 10 must not read `discCount > 0` as "this is
        // a PlayStation game" — this is the assertion that says so.
        XCTAssertEqual(core.discCount, 0, "\(fileName): a cartridge has no discs")
        XCTAssertNil(core.currentDiscIndex, fileName)

        let av = try XCTUnwrap(core.avInfo, fileName)
        XCTAssertGreaterThanOrEqual(av.baseWidth, 160, fileName)
        XCTAssertGreaterThan(av.sampleRate, 20_000, fileName)
        for _ in 0..<60 { core.runFrame() }
        XCTAssertGreaterThan(sink.frames, 0, "\(fileName): no video frame ever arrived")
        XCTAssertGreaterThan(sink.audioFrameCount, 20_000,
                             "\(fileName): ≈1s of audio in 60 frames")
    }

    func testGenesisPlusGXLoadsFromPathWithNoBytes() throws {
        try skipUnlessCorePresent(Self.gpgxCorePath)
        let dir = try scratchDirectory("rommple-genesis-fullpath")
        try runSegaCartridge("minimal-cartridge.gen", bytes: Self.minimalGenesisROM(), in: dir)
    }

    /// `genesis`, `segacd`, `sms` and `gamegear` all map to this one core
    /// (`PlatformSupport.map`), so honouring `need_fullpath` moved four
    /// accepted platforms onto the file route at once. Master System and Game
    /// Gear are the ones whose format is decided by the filename.
    func testGenesisPlusGXLoadsSegaEightBitCartridgesFromPath() throws {
        try skipUnlessCorePresent(Self.gpgxCorePath)
        let dir = try scratchDirectory("rommple-sega8-fullpath")
        try runSegaCartridge("minimal-cartridge.sms",
                             bytes: Self.minimalSegaEightBitROM(regionAndSize: 0x4C), in: dir)
        try runSegaCartridge("minimal-cartridge.gg",
                             bytes: Self.minimalSegaEightBitROM(regionAndSize: 0x6C), in: dir)
    }

    /// A synthetic, copyright-free Master System / Game Gear cartridge: a Z80
    /// jump-to-self at the reset vector and a "TMR SEGA" header. `regionAndSize`
    /// is the 0x7FFF byte — 0x4C for SMS export, 0x6C for Game Gear export.
    static func minimalSegaEightBitROM(regionAndSize: UInt8,
                                       byteCount: Int = 32 * 1024) -> Data {
        var rom = Data(repeating: 0xFF, count: byteCount)
        rom[0] = 0x18
        rom[1] = 0xFE                                  // JR $-2 — halt in place
        let header = 0x7FF0
        rom.replaceSubrange(header..<(header + 8), with: Array("TMR SEGA".utf8))
        for offset in (header + 8)..<(header + 15) { rom[offset] = 0 }  // reserved, checksum, code
        rom[0x7FFF] = regionAndSize
        return rom
    }

    /// A synthetic, copyright-free Mega Drive cartridge: vector table, header,
    /// and a two-byte program that branches to itself.
    static func minimalGenesisROM(byteCount: Int = 128 * 1024) -> Data {
        var rom = Data(repeating: 0xFF, count: byteCount)
        func write32(_ value: UInt32, at offset: Int) {
            rom[offset] = UInt8(truncatingIfNeeded: value >> 24)
            rom[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
            rom[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
            rom[offset + 3] = UInt8(truncatingIfNeeded: value)
        }
        func writeText(_ text: String, at offset: Int, length: Int) {
            var bytes = Array(text.utf8.prefix(length))
            bytes += Array(repeating: 0x20, count: length - bytes.count)
            rom.replaceSubrange(offset..<(offset + length), with: bytes)
        }
        write32(0x00FF_FFFE, at: 0)                   // initial stack pointer
        for vector in stride(from: 4, to: 0x100, by: 4) { write32(0x0000_0200, at: vector) }
        writeText("SEGA GENESIS", at: 0x100, length: 16)
        writeText("(C)RTV 2026.JUL", at: 0x110, length: 16)
        writeText("ROMMPLETV SYNTHETIC CARTRIDGE", at: 0x120, length: 48)
        writeText("ROMMPLETV SYNTHETIC CARTRIDGE", at: 0x150, length: 48)
        writeText("GM 00000000-00", at: 0x180, length: 14)
        rom[0x18E] = 0
        rom[0x18F] = 0                                 // checksum
        writeText("J", at: 0x190, length: 16)          // 3-button pad
        write32(0, at: 0x1A0)                          // ROM start
        write32(UInt32(byteCount - 1), at: 0x1A4)      // ROM end
        write32(0x00FF_0000, at: 0x1A8)                // RAM start
        write32(0x00FF_FFFF, at: 0x1AC)                // RAM end
        writeText("", at: 0x1B0, length: 0x40)         // no SRAM, no notes
        writeText("U", at: 0x1F0, length: 16)          // region
        rom[0x200] = 0x60
        rom[0x201] = 0xFE                              // BRA.S * — halt in place
        return rom
    }

    // MARK: - What the core actually receives
    //
    // Nothing above can see the `retro_game_info` a real core is handed, so
    // these tests build a throwaway libretro core that records it. It is also
    // the only way to observe disk-control negotiation the way a core sees
    // it: version query first, then registrations.

    static let fakeCoreSource = """
    #include <stdbool.h>
    #include <stddef.h>
    #include <string.h>

    #ifndef FAKE_NEED_FULLPATH
    #define FAKE_NEED_FULLPATH 0
    #endif

    #define ENV_GET_DISK_CONTROL_INTERFACE_VERSION 57
    #define ENV_SET_DISK_CONTROL_INTERFACE 13
    #define ENV_SET_DISK_CONTROL_EXT_INTERFACE 58

    struct retro_game_info { const char *path; const void *data; size_t size; const char *meta; };
    struct retro_system_info { const char *library_name; const char *library_version;
                               const char *valid_extensions; bool need_fullpath; bool block_extract; };
    struct retro_game_geometry { unsigned base_width, base_height, max_width, max_height; float aspect_ratio; };
    struct retro_system_timing { double fps; double sample_rate; };
    struct retro_system_av_info { struct retro_game_geometry geometry; struct retro_system_timing timing; };

    struct disk_cb {
      bool (*set_eject_state)(bool); bool (*get_eject_state)(void);
      unsigned (*get_image_index)(void); bool (*set_image_index)(unsigned);
      unsigned (*get_num_images)(void);
      bool (*replace_image_index)(unsigned, const struct retro_game_info *);
      bool (*add_image_index)(void);
    };
    struct disk_ext_cb {
      bool (*set_eject_state)(bool); bool (*get_eject_state)(void);
      unsigned (*get_image_index)(void); bool (*set_image_index)(unsigned);
      unsigned (*get_num_images)(void);
      bool (*replace_image_index)(unsigned, const struct retro_game_info *);
      bool (*add_image_index)(void);
      bool (*set_initial_image)(unsigned, const char *);
      bool (*get_image_path)(unsigned, char *, size_t);
      bool (*get_image_label)(unsigned, char *, size_t);
    };

    typedef bool (*environment_t)(unsigned, void *);
    static environment_t g_environ;

    static int g_had_data, g_had_path;
    static unsigned long g_size, g_data_sum;
    static char g_path[4096];
    static int g_version_answered = -1;
    static unsigned g_version_seen = 4294967295u;
    static int g_registrations, g_registrations_before_version_query = -1;

    /* Two drives, so the frontend's choice between the interfaces is visible. */
    static unsigned g_legacy_index; static bool g_legacy_ejected;
    static bool legacy_set_eject(bool e) { g_legacy_ejected = e; return true; }
    static bool legacy_get_eject(void) { return g_legacy_ejected; }
    static unsigned legacy_get_index(void) { return g_legacy_index; }
    static bool legacy_set_index(unsigned i) {
      if (!g_legacy_ejected) return false; g_legacy_index = i; return true; }
    static unsigned legacy_num(void) { return 2; }
    static bool legacy_replace(unsigned i, const struct retro_game_info *g) { (void)i; (void)g; return false; }
    static bool legacy_add(void) { return false; }

    static unsigned g_ext_index; static bool g_ext_ejected;
    static bool ext_set_eject(bool e) { g_ext_ejected = e; return true; }
    static bool ext_get_eject(void) { return g_ext_ejected; }
    static unsigned ext_get_index(void) { return g_ext_index; }
    /* Refuses while the tray is shut, exactly as libretro specifies. */
    static bool ext_set_index(unsigned i) {
      if (!g_ext_ejected) return false; g_ext_index = i; return true; }
    static unsigned ext_num(void) { return 3; }
    static bool ext_replace(unsigned i, const struct retro_game_info *g) { (void)i; (void)g; return false; }
    static bool ext_add(void) { return false; }

    int fake_had_data(void) { return g_had_data; }
    int fake_had_path(void) { return g_had_path; }
    unsigned long fake_size(void) { return g_size; }
    unsigned long fake_data_sum(void) { return g_data_sum; }
    const char *fake_path(void) { return g_path; }
    int fake_version_answered(void) { return g_version_answered; }
    unsigned fake_version_seen(void) { return g_version_seen; }
    int fake_registrations_before_version_query(void) { return g_registrations_before_version_query; }
    unsigned fake_ext_index(void) { return g_ext_index; }
    int fake_ext_ejected(void) { return g_ext_ejected ? 1 : 0; }
    unsigned fake_legacy_index(void) { return g_legacy_index; }

    void retro_set_environment(environment_t cb) { g_environ = cb; }
    void retro_set_video_refresh(void *cb) { (void)cb; }
    void retro_set_audio_sample(void *cb) { (void)cb; }
    void retro_set_audio_sample_batch(void *cb) { (void)cb; }
    void retro_set_input_poll(void *cb) { (void)cb; }
    void retro_set_input_state(void *cb) { (void)cb; }

    void retro_get_system_info(struct retro_system_info *info) {
      memset(info, 0, sizeof *info);
      info->library_name = "RommpleTV Fake Core";
      info->library_version = "1";
      info->valid_extensions = "fake";
      info->need_fullpath = FAKE_NEED_FULLPATH ? true : false;
    }

    void retro_init(void) {
      unsigned version = 4294967295u;
      g_registrations_before_version_query = g_registrations;
      g_version_answered = g_environ
        ? (g_environ(ENV_GET_DISK_CONTROL_INTERFACE_VERSION, &version) ? 1 : 0) : -1;
      g_version_seen = version;
      static struct disk_cb legacy;
      legacy.set_eject_state = legacy_set_eject; legacy.get_eject_state = legacy_get_eject;
      legacy.get_image_index = legacy_get_index; legacy.set_image_index = legacy_set_index;
      legacy.get_num_images = legacy_num; legacy.replace_image_index = legacy_replace;
      legacy.add_image_index = legacy_add;
      if (g_environ && g_environ(ENV_SET_DISK_CONTROL_INTERFACE, &legacy)) g_registrations++;
    }

    bool retro_load_game(const struct retro_game_info *info) {
      if (!info) return false;
    #ifdef FAKE_REJECT_LOAD
      /* Records what it was given, then refuses -- the frontend's failure
         path has to clear both retained things either way. */
      g_had_data = info->data != NULL;
      g_had_path = info->path != NULL;
      g_size = (unsigned long)info->size;
      return false;
    #endif
      g_had_data = info->data != NULL;
      g_had_path = info->path != NULL;
      g_size = (unsigned long)info->size;
      g_data_sum = 0;
      if (info->data) {
        const unsigned char *b = (const unsigned char *)info->data;
        for (unsigned long i = 0; i < g_size; i++) g_data_sum += b[i];
      }
      g_path[0] = 0;
      if (info->path) { strncpy(g_path, info->path, sizeof g_path - 1); g_path[sizeof g_path - 1] = 0; }
      static struct disk_ext_cb ext;
      ext.set_eject_state = ext_set_eject; ext.get_eject_state = ext_get_eject;
      ext.get_image_index = ext_get_index; ext.set_image_index = ext_set_index;
      ext.get_num_images = ext_num; ext.replace_image_index = ext_replace;
      ext.add_image_index = ext_add;
      ext.set_initial_image = 0; ext.get_image_path = 0; ext.get_image_label = 0;
      if (g_environ && g_environ(ENV_SET_DISK_CONTROL_EXT_INTERFACE, &ext)) g_registrations++;
      return true;
    }

    void retro_get_system_av_info(struct retro_system_av_info *info) {
      memset(info, 0, sizeof *info);
      info->geometry.base_width = 320; info->geometry.base_height = 240;
      info->geometry.max_width = 320; info->geometry.max_height = 240;
      info->geometry.aspect_ratio = 4.0f / 3.0f;
      info->timing.fps = 60.0; info->timing.sample_rate = 44100.0;
    }

    void retro_deinit(void) { }
    void retro_run(void) { }
    void retro_reset(void) { }
    void retro_unload_game(void) { }
    void retro_set_controller_port_device(unsigned p, unsigned d) { (void)p; (void)d; }
    void *retro_get_memory_data(unsigned id) { (void)id; return 0; }
    size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
    """

    struct FakeCoreBuildFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Compiles the recorder above into a dylib.
    ///
    /// These are the only tests that can see the `retro_game_info` a core
    /// receives, so a missing toolchain **fails** rather than quietly greening
    /// the suite with that contract unguarded. An image that genuinely has no
    /// C compiler opts out explicitly with `ROMMPLETV_NO_C_TOOLCHAIN`, the
    /// same shape as the M3U fixture's gate.
    func buildFakeCore(needsFullPath: Bool, rejectLoad: Bool = false,
                       in dir: URL) throws -> String {
        let optedOut = ProcessInfo.processInfo.environment["ROMMPLETV_NO_C_TOOLCHAIN"] != nil
        func giveUp(_ reason: String) -> Error {
            optedOut ? XCTSkip("ROMMPLETV_NO_C_TOOLCHAIN is set: \(reason)")
                     : FakeCoreBuildFailure(description:
                        "\(reason) — these tests are the only cover for what "
                        + "reaches retro_load_game. Set ROMMPLETV_NO_C_TOOLCHAIN "
                        + "to skip them deliberately.")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw giveUp("no /usr/bin/xcrun to build the recording core with")
        }
        let source = dir.appendingPathComponent("fake_core.c")
        try Self.fakeCoreSource.write(to: source, atomically: true, encoding: .utf8)
        let dylib = dir.appendingPathComponent("fake_core.dylib")
        var arguments = ["clang", "-dynamiclib", "-O0",
                         "-DFAKE_NEED_FULLPATH=\(needsFullPath ? 1 : 0)"]
        if rejectLoad { arguments.append("-DFAKE_REJECT_LOAD=1") }
        arguments += ["-o", dylib.path, source.path]
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = arguments
        let errors = Pipe()
        clang.standardError = errors
        try clang.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        clang.waitUntilExit()
        guard clang.terminationStatus == 0 else {
            throw giveUp("couldn't build the recording core: \(message)")
        }
        return dylib.path
    }

    private func fakeInt(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> Int {
        let symbol = try XCTUnwrap(dlsym(handle, name), name)
        return Int(unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)())
    }
    private func fakeUInt(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> UInt32 {
        let symbol = try XCTUnwrap(dlsym(handle, name), name)
        return unsafeBitCast(symbol, to: (@convention(c) () -> UInt32).self)()
    }
    private func fakeULong(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> UInt {
        let symbol = try XCTUnwrap(dlsym(handle, name), name)
        return unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
    }
    private func fakeString(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> String {
        let symbol = try XCTUnwrap(dlsym(handle, name), name)
        return String(cString: unsafeBitCast(
            symbol, to: (@convention(c) () -> UnsafePointer<CChar>).self)())
    }

    func testFullPathBranchHandsTheCoreAPathAndNoBytes() throws {
        let dir = try scratchDirectory("rommple-fake-fullpath")
        let dylib = try buildFakeCore(needsFullPath: true, in: dir)
        let file = dir.appendingPathComponent("disc.fake")
        try Data(repeating: 0x5A, count: 4096).write(to: file, options: .atomic)

        // A second handle keeps the image mapped after the core dlcloses it.
        let probe = try XCTUnwrap(dlopen(dylib, RTLD_NOW))
        defer { dlclose(probe) }

        let core = try LibretroCore(dylibPath: dylib, systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }
        XCTAssertTrue(core.needsFullPath)
        try core.loadGame(at: file)

        XCTAssertEqual(try fakeInt(probe, "fake_had_data"), 0,
                       "a need_fullpath core must be handed no bytes at all")
        XCTAssertEqual(try fakeULong(probe, "fake_size"), 0)
        XCTAssertEqual(try fakeInt(probe, "fake_had_path"), 1)
        XCTAssertEqual(try fakeString(probe, "fake_path"), file.path)
        XCTAssertNil(core.romData)
        XCTAssertNotNil(core.gamePath.pointer)

        core.unload()
        XCTAssertNil(core.gamePath.pointer, "unload releases the retained path")
    }

    func testInMemoryBranchHandsTheCoreItsBytes() throws {
        let dir = try scratchDirectory("rommple-fake-inmemory")
        let dylib = try buildFakeCore(needsFullPath: false, in: dir)
        let file = dir.appendingPathComponent("cartridge.fake")
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        try content.write(to: file, options: .atomic)
        let expectedSum = content.reduce(UInt(0)) { $0 + UInt($1) }

        let probe = try XCTUnwrap(dlopen(dylib, RTLD_NOW))
        defer { dlclose(probe) }

        let core = try LibretroCore(dylibPath: dylib, systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }
        XCTAssertFalse(core.needsFullPath)
        try core.loadGame(at: file)

        // Everything the pre-PlayStation implementation guaranteed: a path, a
        // live data pointer, the exact byte count, and the exact bytes.
        XCTAssertEqual(try fakeInt(probe, "fake_had_path"), 1)
        XCTAssertEqual(try fakeString(probe, "fake_path"), file.path)
        XCTAssertEqual(try fakeInt(probe, "fake_had_data"), 1)
        XCTAssertEqual(try fakeULong(probe, "fake_size"), UInt(content.count))
        XCTAssertEqual(try fakeULong(probe, "fake_data_sum"), expectedSum,
                       "the pointer must address the ROM's own bytes")
        XCTAssertEqual(core.romData, content)
        XCTAssertNil(core.gamePath.pointer)

        core.unload()
        XCTAssertNil(core.romData, "unload releases the retained ROM")
    }

    func testDiskControlNegotiationAndSwitchThroughARealCore() throws {
        let dir = try scratchDirectory("rommple-fake-discs")
        let dylib = try buildFakeCore(needsFullPath: true, in: dir)
        let file = dir.appendingPathComponent("discs.fake")
        try Data("m3u".utf8).write(to: file, options: .atomic)

        let probe = try XCTUnwrap(dlopen(dylib, RTLD_NOW))
        defer { dlclose(probe) }

        let core = try LibretroCore(dylibPath: dylib, systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }

        // The core asks for the version inside retro_init, before it has
        // registered anything — and it has to get an answer there.
        XCTAssertEqual(try fakeInt(probe, "fake_version_answered"), 1)
        XCTAssertEqual(try fakeUInt(probe, "fake_version_seen"), 1)
        XCTAssertEqual(try fakeInt(probe, "fake_registrations_before_version_query"), 0)

        // Legacy registered in retro_init (2 images), extended in
        // retro_load_game (3). The extended one has to win.
        XCTAssertEqual(core.discCount, 2, "only the legacy interface exists so far")
        try core.loadGame(at: file)
        XCTAssertEqual(core.discCount, 3, "the extended interface supersedes the legacy one")
        XCTAssertEqual(core.currentDiscIndex, 0)

        // The fake refuses set_image_index while its tray is shut, so this
        // only passes if the eject really happened first.
        try core.switchDisc(to: 2)
        XCTAssertEqual(core.currentDiscIndex, 2)
        XCTAssertEqual(try fakeUInt(probe, "fake_ext_index"), 2)
        XCTAssertEqual(try fakeInt(probe, "fake_ext_ejected"), 0, "the tray ends up shut")
        XCTAssertEqual(try fakeUInt(probe, "fake_legacy_index"), 0,
                       "the superseded interface was never driven")

        XCTAssertThrowsError(try core.switchDisc(to: 3))
        XCTAssertEqual(core.currentDiscIndex, 2, "a rejected index changes nothing")

        core.unload()
        XCTAssertEqual(core.discCount, 0, "both interfaces are dropped on unload")
        XCTAssertNil(core.currentDiscIndex)
        XCTAssertThrowsError(try core.switchDisc(to: 0))
    }

    /// The failure-clearing rule for both branches, with no gitignored core
    /// involved: a build of the recorder that records and then refuses.
    func testRejectedLoadClearsBothRetainedThingsInEitherBranch() throws {
        for needsFullPath in [false, true] {
            let dir = try scratchDirectory("rommple-fake-reject-\(needsFullPath)")
            let dylib = try buildFakeCore(needsFullPath: needsFullPath,
                                          rejectLoad: true, in: dir)
            let file = dir.appendingPathComponent("content.fake")
            try Data(repeating: 0x11, count: 2048).write(to: file, options: .atomic)

            let core = try LibretroCore(dylibPath: dylib,
                                        systemDirectory: dir, saveDirectory: dir)
            defer { core.unload() }
            XCTAssertEqual(core.needsFullPath, needsFullPath)
            XCTAssertThrowsError(try core.loadGame(at: file)) { error in
                guard case CoreError.loadGameFailed = error else {
                    return XCTFail("expected loadGameFailed, got \(error)")
                }
            }
            XCTAssertNil(core.romData,
                         "rejected load kept bytes (needsFullPath: \(needsFullPath))")
            XCTAssertNil(core.gamePath.pointer,
                         "rejected load kept a path (needsFullPath: \(needsFullPath))")

            // A refusal is not a loaded game, so the core is still retryable.
            XCTAssertThrowsError(try core.loadGame(at: file)) { error in
                guard case CoreError.loadGameFailed = error else {
                    return XCTFail("a retry must reach the core again, got \(error)")
                }
            }
        }
    }

    func testSecondLoadIsRefusedWhileAGameIsLoaded() throws {
        let dir = try scratchDirectory("rommple-fake-second-load")
        let dylib = try buildFakeCore(needsFullPath: true, in: dir)
        let file = dir.appendingPathComponent("disc.fake")
        try Data("m3u".utf8).write(to: file, options: .atomic)

        let core = try LibretroCore(dylibPath: dylib, systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }
        try core.loadGame(at: file)
        let retained = try XCTUnwrap(core.gamePath.pointer)

        XCTAssertThrowsError(try core.loadGame(at: file)) { error in
            guard case CoreError.alreadyLoaded = error else {
                return XCTFail("expected alreadyLoaded, got \(error)")
            }
        }
        // The point of refusing: replacing the retained path would free a
        // string a need_fullpath core is still reading through.
        XCTAssertEqual(core.gamePath.pointer, retained)
        XCTAssertEqual(String(cString: retained), file.path)
    }

    func testFullPathPayloadDoesNotReadContentIntoData() throws {
        var reads = 0
        let factory = LoadPayloadFactory(needsFullPath: true) { url in
            reads += 1
            XCTFail("a need_fullpath core must never have \(url.lastPathComponent) read")
            return Data()
        }
        let payload = try factory.makePayload(for: URL(fileURLWithPath: "/discs/game.m3u"))
        XCTAssertEqual(payload, .fullPath)
        XCTAssertEqual(reads, 0)

        // …and what reaches the core carries no bytes either.
        "/discs/game.m3u".withCString { pathC in
            let info = LibretroCore.fullPathGameInfo(path: pathC)
            XCTAssertNil(info.data, "data must be nil for a need_fullpath core")
            XCTAssertEqual(info.size, 0)
            XCTAssertEqual(String(cString: info.path), "/discs/game.m3u")
        }
    }

    func testInMemoryPayloadRemainsUsedForExistingCores() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var reads = 0
        let factory = LoadPayloadFactory(needsFullPath: false) { _ in
            reads += 1
            return bytes
        }
        let payload = try factory.makePayload(for: URL(fileURLWithPath: "/roms/game.sfc"))
        XCTAssertEqual(payload, .inMemory(bytes))
        XCTAssertEqual(reads, 1, "the ROM is read exactly once, not per-access")

        // The 2D cores this app already ships must keep taking bytes — and
        // keep them: a core may read out of that buffer for the whole
        // session, so the frontend has to be the thing holding it alive.
        try skipUnlessCorePresent(Self.corePath)
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        XCTAssertFalse(core.needsFullPath)
        try core.loadGame(at: rom)
        XCTAssertEqual(core.romData, try Data(contentsOf: rom),
                       "the ROM stays resident for as long as the game is loaded")
        XCTAssertNil(core.gamePath.pointer,
                     "the in-memory branch retains no path of its own")
    }

    func testDefaultPayloadLoaderReadsTheFileItself() throws {
        let dir = try scratchDirectory("rommple-payload-default")
        let file = dir.appendingPathComponent("content.bin")
        let bytes = Data([1, 2, 3, 4, 5])
        try bytes.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }

        // No injected loader: this is the production configuration.
        let payload = try LoadPayloadFactory(needsFullPath: false).makePayload(for: file)
        XCTAssertEqual(payload, .inMemory(bytes))

        XCTAssertThrowsError(
            try LoadPayloadFactory(needsFullPath: false)
                .makePayload(for: dir.appendingPathComponent("absent.bin")),
            "an unreadable ROM must surface as a thrown error, not empty bytes")

        // The same missing file is not an error for a need_fullpath core: it
        // never opens the file, so the core decides.
        XCTAssertEqual(
            try LoadPayloadFactory(needsFullPath: true)
                .makePayload(for: dir.appendingPathComponent("absent.bin")), .fullPath)
    }

    // MARK: - Disk Control negotiation

    func testExtendedDiskInterfaceVersionNegotiatesBeforeRegistration() throws {
        var controller = DiskController()

        // 1. The core asks for the version first, with nothing registered yet.
        //    A handler that consulted registration state would fail here.
        var version = UInt32.max
        let answered = withUnsafeMutableBytes(of: &version) {
            controller.handleEnvironment(
                RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION, $0.baseAddress)
        }
        XCTAssertEqual(answered, true)
        XCTAssertEqual(version, 1, "version 1 is what tells a core to use the ext interface")
        XCTAssertEqual(controller.discCount, 0)
        XCTAssertNil(controller.currentIndex)

        // 2. Only then does the core register — and the frontend now has discs.
        extendedSpy.reset(imageCount: 2)
        var ext = ExtendedSpyCallbacks.callback
        let registered = withUnsafeMutableBytes(of: &ext) {
            controller.handleEnvironment(
                RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, $0.baseAddress)
        }
        XCTAssertEqual(registered, true)
        XCTAssertEqual(controller.discCount, 2)

        // 3. The query is not one-shot: a core may re-ask at any point.
        version = UInt32.max
        _ = withUnsafeMutableBytes(of: &version) {
            controller.handleEnvironment(
                RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION, $0.baseAddress)
        }
        XCTAssertEqual(version, 1)
    }

    func testDiskEnvironmentIgnoresUnrelatedCommandsAndNullVersionPointer() throws {
        var controller = DiskController()
        XCTAssertNil(controller.handleEnvironment(RETRO_ENVIRONMENT_GET_CAN_DUPE, nil),
                     "non-disk commands must fall through to the rest of the handler")
        XCTAssertEqual(
            controller.handleEnvironment(
                RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION, nil), false,
            "there is nowhere to write the version, so the call is not answered")
    }

    func testExtendedDiskInterfaceSupersedesLegacyInterface() throws {
        for extendedFirst in [false, true] {
            var controller = DiskController()
            var legacy = LegacySpyCallbacks.callback
            var ext = ExtendedSpyCallbacks.callback
            if extendedFirst {
                withUnsafeMutableBytes(of: &ext) {
                    _ = controller.handleEnvironment(
                        RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, $0.baseAddress)
                }
                withUnsafeMutableBytes(of: &legacy) {
                    _ = controller.handleEnvironment(
                        RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE, $0.baseAddress)
                }
            } else {
                withUnsafeMutableBytes(of: &legacy) {
                    _ = controller.handleEnvironment(
                        RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE, $0.baseAddress)
                }
                withUnsafeMutableBytes(of: &ext) {
                    _ = controller.handleEnvironment(
                        RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, $0.baseAddress)
                }
            }

            legacySpy.reset(imageCount: 7)
            extendedSpy.reset(imageCount: 3)
            XCTAssertEqual(controller.discCount, 3,
                           "extended must win with extendedFirst = \(extendedFirst)")
            try controller.switchDisc(to: 2)
            XCTAssertEqual(extendedSpy.imageIndex, 2)
            XCTAssertTrue(legacySpy.log.isEmpty,
                          "the superseded interface must not be called at all")
        }
    }

    func testLegacyDiskInterfaceDrivesTheSwitchWhenItIsTheOnlyOne() throws {
        var controller = DiskController()
        var legacy = LegacySpyCallbacks.callback
        withUnsafeMutableBytes(of: &legacy) {
            _ = controller.handleEnvironment(
                RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE, $0.baseAddress)
        }
        legacySpy.reset(imageCount: 2)
        try controller.switchDisc(to: 1)
        XCTAssertEqual(legacySpy.imageIndex, 1)
    }

    func testNullInterfacePointerDeregistersAndMissingCallbacksAreRejected() throws {
        var controller = DiskController()
        var ext = ExtendedSpyCallbacks.callback
        withUnsafeMutableBytes(of: &ext) {
            _ = controller.handleEnvironment(
                RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, $0.baseAddress)
        }
        extendedSpy.reset(imageCount: 4)
        XCTAssertEqual(controller.discCount, 4)

        // libretro: "May be NULL, in which case the existing disk callback is
        // deregistered" — and the call is still answered.
        XCTAssertEqual(
            controller.handleEnvironment(
                RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, nil), true)
        XCTAssertEqual(controller.discCount, 0)

        // A struct missing one of the five entry points this frontend drives
        // is not usable — storing it would be a null call at switch time.
        var holed = ExtendedSpyCallbacks.callback
        holed.set_image_index = nil
        withUnsafeMutableBytes(of: &holed) {
            _ = controller.handleEnvironment(
                RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, $0.baseAddress)
        }
        XCTAssertEqual(controller.discCount, 0)
        XCTAssertThrowsError(try controller.switchDisc(to: 0))
    }

    // MARK: - Disc switching

    private func registeredController(imageCount: UInt32 = 3,
                                      imageIndex: UInt32 = 0) -> DiskController {
        var controller = DiskController()
        var ext = ExtendedSpyCallbacks.callback
        withUnsafeMutableBytes(of: &ext) {
            _ = controller.handleEnvironment(
                RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, $0.baseAddress)
        }
        extendedSpy.reset(imageCount: imageCount, imageIndex: imageIndex)
        return controller
    }

    func testDiscSwitchUsesEjectIndexInsertOrder() throws {
        let controller = registeredController()
        try controller.switchDisc(to: 2)
        XCTAssertEqual(extendedSpy.log,
                       ["numImages", "getIndex", "getEject",
                        "setEject(true)", "setIndex(2)", "setEject(false)"])
        XCTAssertEqual(extendedSpy.imageIndex, 2)
        XCTAssertFalse(extendedSpy.isEjected, "the tray must be closed when the switch returns")
        XCTAssertEqual(controller.currentIndex, 2)
    }

    func testDiscSwitchRestoresPriorDiscAfterInsertionFailure() throws {
        let controller = registeredController(imageIndex: 0)
        extendedSpy.refusesToClose = true      // the disc goes in, the tray won't shut
        XCTAssertThrowsError(try controller.switchDisc(to: 1)) { error in
            guard case CoreError.discSwitchFailed = error else {
                return XCTFail("expected discSwitchFailed, got \(error)")
            }
        }
        XCTAssertEqual(extendedSpy.log,
                       ["numImages", "getIndex", "getEject",
                        "setEject(true)", "setIndex(1)", "setEject(false)",
                        "setIndex(0)", "setEject(false)"],
                       "a failed insert must put the prior disc back and try to close")
        XCTAssertEqual(extendedSpy.imageIndex, 0, "the prior disc is back in the drive")
    }

    func testDiscSwitchRestoresPriorDiscWhenTheCoreRefusesTheNewIndex() throws {
        let controller = registeredController(imageIndex: 2)
        extendedSpy.refusesNewDisc = true
        XCTAssertThrowsError(try controller.switchDisc(to: 0))
        XCTAssertEqual(extendedSpy.log,
                       ["numImages", "getIndex", "getEject",
                        "setEject(true)", "setIndex(0)", "setIndex(2)", "setEject(false)"])
        XCTAssertEqual(extendedSpy.imageIndex, 2)
        XCTAssertFalse(extendedSpy.isEjected, "the drive is closed again on the way out")
    }

    func testDiscSwitchLeavesTheDriveAloneWhenTheTrayWillNotOpen() throws {
        let controller = registeredController(imageIndex: 1)
        extendedSpy.refusesToOpen = true
        XCTAssertThrowsError(try controller.switchDisc(to: 0))
        XCTAssertEqual(extendedSpy.log,
                       ["numImages", "getIndex", "getEject", "setEject(true)"],
                       "nothing changed, so there is nothing to roll back")
        XCTAssertEqual(extendedSpy.imageIndex, 1)
    }

    func testDiscSwitchRejectsOutOfRangeIndex() throws {
        for index in [-1, 3, 4, Int(Int32.max)] {
            let controller = registeredController(imageCount: 3, imageIndex: 1)
            XCTAssertThrowsError(try controller.switchDisc(to: index)) { error in
                guard case CoreError.discIndexOutOfRange(let got, let count) = error else {
                    return XCTFail("expected discIndexOutOfRange for \(index), got \(error)")
                }
                XCTAssertEqual(got, index)
                XCTAssertEqual(count, 3)
            }
            XCTAssertEqual(extendedSpy.log, ["numImages"],
                           "a bad index must be rejected before the tray is touched")
            XCTAssertEqual(extendedSpy.imageIndex, 1)
        }
    }

    func testUnregisteredDiskControlRefusesEveryDiscOperation() throws {
        let controller = DiskController()
        XCTAssertEqual(controller.discCount, 0)
        XCTAssertNil(controller.currentIndex)
        XCTAssertThrowsError(try controller.switchDisc(to: 0)) { error in
            guard case CoreError.discControlUnavailable = error else {
                return XCTFail("expected discControlUnavailable, got \(error)")
            }
        }
    }

    func testCurrentDiscIndexIsNilWhenNoDiscIsInserted() throws {
        let controller = registeredController(imageCount: 2, imageIndex: 0)
        XCTAssertEqual(controller.currentIndex, 0)
        // libretro reports "no disc in the drive" as an index at or past the
        // image count — that is not a disc anything can name.
        extendedSpy.imageIndex = 2
        XCTAssertNil(controller.currentIndex)
    }

    // MARK: - Core lifecycle

    func testDiskCallbacksClearOnUnload() throws {
        try skipUnlessCorePresent(Self.corePath)
        let core = try makeCore()
        defer { core.unload() }

        var ext = ExtendedSpyCallbacks.callback
        let registered = withUnsafeMutableBytes(of: &ext) {
            core.environment(UInt32(RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE),
                             $0.baseAddress)
        }
        XCTAssertTrue(registered)
        extendedSpy.reset(imageCount: 2)
        XCTAssertEqual(core.discCount, 2)
        XCTAssertEqual(core.currentDiscIndex, 0)

        core.unload()

        // After unload the core's code may be unmapped: every one of these
        // must answer from the frontend without touching a function pointer.
        extendedSpy.reset(imageCount: 2)
        XCTAssertEqual(core.discCount, 0)
        XCTAssertNil(core.currentDiscIndex)
        XCTAssertThrowsError(try core.switchDisc(to: 1)) { error in
            guard case CoreError.discControlUnavailable = error else {
                return XCTFail("expected discControlUnavailable, got \(error)")
            }
        }
        XCTAssertTrue(extendedSpy.log.isEmpty,
                      "no core callback may run after unload: \(extendedSpy.log)")
    }

    func testCoreWithoutDiskControlReportsNoDiscs() throws {
        try skipUnlessCorePresent(Self.corePath)
        let rom = try romURL()
        let core = try makeCore()
        defer { core.unload() }
        try core.loadGame(at: rom)
        XCTAssertEqual(core.discCount, 0)
        XCTAssertNil(core.currentDiscIndex)
        XCTAssertThrowsError(try core.switchDisc(to: 0))
    }

    func testFailedInMemoryLoadClearsRetainedBytes() throws {
        let corePath = FileManager.default.currentDirectoryPath
            + "/../Cores/macos/mednafen_vb_libretro.dylib"
        try skipUnlessCorePresent(corePath)
        let dir = try scratchDirectory("rommple-bad-rom")
        let junk = dir.appendingPathComponent("not-a-rom.vb")
        try Data(repeating: 0x00, count: 1000).write(to: junk, options: .atomic)
        defer { try? FileManager.default.removeItem(at: junk) }

        let core = try LibretroCore(dylibPath: corePath,
                                    systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }
        XCTAssertFalse(core.needsFullPath)
        XCTAssertThrowsError(try core.loadGame(at: junk))
        XCTAssertNil(core.romData, "a rejected ROM must not stay resident")
        XCTAssertNil(core.gamePath.pointer)
    }

    func testFailedFullPathLoadReleasesRetainedPath() throws {
        try skipUnlessCorePresent(Self.psxCorePath)
        let dir = try scratchDirectory("rommple-bad-disc")
        let junk = dir.appendingPathComponent("not-a-disc.cue")
        try Data("FILE \"nothing.bin\" BINARY\n".utf8).write(to: junk, options: .atomic)
        defer { try? FileManager.default.removeItem(at: junk) }

        let core = try LibretroCore(dylibPath: Self.psxCorePath,
                                    systemDirectory: dir, saveDirectory: dir)
        defer { core.unload() }
        XCTAssertThrowsError(try core.loadGame(at: junk))
        XCTAssertNil(core.romData, "the full-path branch retains no bytes to begin with")
        XCTAssertNil(core.gamePath.pointer, "a failed load must release the retained path")
    }

    func testFullPathLoadKeepsThePathAliveWhileTheGameIsLoaded() throws {
        // Provable without a disc: the retained C string has to be a copy the
        // core can keep reading, not a pointer into a temporary Swift String.
        let path = "/discs/multi/game.m3u"
        var retained = RetainedPath()
        retained.retain(path)
        let first = try XCTUnwrap(retained.pointer)
        XCTAssertEqual(String(cString: first), path)

        retained.retain("/discs/other/game.m3u")
        XCTAssertEqual(String(cString: try XCTUnwrap(retained.pointer)),
                       "/discs/other/game.m3u")
        retained.release()
        XCTAssertNil(retained.pointer)
        retained.release()   // idempotent: unload() and deinit both run it
    }

    func testBeetlePSXLoadsM3UWhenLegalFixtureProvided() throws {
        let env = ProcessInfo.processInfo.environment
        guard let m3uPath = env["ROMMPLETV_PS1_M3U"],
              let biosPath = env["ROMMPLETV_PS1_BIOS_DIR"] else {
            throw XCTSkip("set ROMMPLETV_PS1_M3U and ROMMPLETV_PS1_BIOS_DIR to run "
                          + "this against a legally-owned disc set")
        }
        try skipUnlessCorePresent(Self.psxCorePath)
        let core = try LibretroCore(dylibPath: Self.psxCorePath,
                                    systemDirectory: URL(fileURLWithPath: biosPath),
                                    saveDirectory: try scratchDirectory("rommple-psx-saves"))
        defer { core.unload() }
        XCTAssertTrue(core.needsFullPath)
        try core.loadGame(at: URL(fileURLWithPath: m3uPath))
        XCTAssertNil(core.romData,
                     "the M3U and its discs must never be read into memory")
        XCTAssertNotNil(core.gamePath.pointer,
                        "the path stays alive for as long as the game is loaded")
        XCTAssertGreaterThanOrEqual(core.discCount, 1)
        XCTAssertEqual(core.currentDiscIndex, 0)
        if core.discCount > 1 {
            try core.switchDisc(to: 1)
            XCTAssertEqual(core.currentDiscIndex, 1)
            try core.switchDisc(to: 0)
            XCTAssertEqual(core.currentDiscIndex, 0)
        }
        for _ in 0..<60 { core.runFrame() }
    }
}

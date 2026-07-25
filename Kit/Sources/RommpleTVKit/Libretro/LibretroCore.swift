import Foundation
import CLibretro

// One live core at a time: libretro cores are process-singletons and the
// C callbacks below cannot capture context, so they route through this.
private nonisolated(unsafe) var gCore: LibretroCore?

public enum CorePixelFormat: Sendable { case rgb1555, xrgb8888, rgb565 }

public struct CoreAVInfo: Sendable {
    public let baseWidth: Int, baseHeight: Int, maxWidth: Int, maxHeight: Int
    public let fps: Double, sampleRate: Double, aspectRatio: Double
}

public protocol CoreAVSink: AnyObject {
    func videoFrame(_ data: UnsafeRawPointer, width: Int, height: Int,
                    pitchBytes: Int, format: CorePixelFormat)
    func audioFrames(_ samples: UnsafePointer<Int16>, frameCount: Int)
}

/// libretro's `RETRO_DEVICE_ID_JOYPAD_*` ids.
///
/// The raw values are the wire format `retro_input_state_t` is called with, not
/// an ordering choice: `id` arrives from the core and indexes `buttons`
/// directly, so renumbering a case silently remaps a button.
///
/// All sixteen ids, including the four no cartridge system this app ships has
/// any use for. `retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD)` tells
/// Beetle PSX it is talking to a PlayStation Controller, so it polls ids 12-15
/// every frame whatever the frontend does about them — and an id with no case
/// is a button that reads 0 for the life of the install, with no error anywhere
/// and no test that can press it. A large part of the PlayStation library puts
/// camera control, weapon cycling and menu paging on L2/R2.
public enum RetroButton: Int32, CaseIterable, Sendable {
    case b = 0, y = 1, select = 2, start = 3, up = 4, down = 5, left = 6,
         right = 7, a = 8, x = 9, l = 10, r = 11, l2 = 12, r2 = 13,
         l3 = 14, r3 = 15
}

public enum CoreError: Error {
    case dlopenFailed(String), missingSymbol(String), loadGameFailed, alreadyLoaded
    /// A disc switch was asked for but no Disk Control interface is
    /// registered: a single-disc game, a core that has none, or an unloaded
    /// core whose callbacks have already been dropped.
    case discControlUnavailable
    /// The requested disc is outside `0..<count` for the loaded game.
    case discIndexOutOfRange(index: Int, count: Int)
    /// The core refused one of the eject/insert steps. The disc that was in
    /// the drive has been put back on a best-effort basis.
    case discSwitchFailed
}

extension CoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .dlopenFailed(let msg): return "Couldn't load the emulator core (\(msg))."
        case .missingSymbol(let name): return "The emulator core is incomplete (missing \(name))."
        case .loadGameFailed: return "The core rejected this ROM file."
        case .alreadyLoaded: return "Another game is still running — back out and try again."
        case .discControlUnavailable: return "This game doesn't have discs to switch between."
        case .discIndexOutOfRange(let index, let count):
            // Discs are 1-based to a player. `index` is whatever was asked
            // for, including `Int.max`, so the +1 has to not trap while
            // rendering an error about a bad number.
            let humanIndex = index < Int.max ? index + 1 : index
            return "There's no disc \(humanIndex) in this game (it has \(count))."
        case .discSwitchFailed:
            return "The game wouldn't change discs just now — try again in a moment."
        }
    }
}

/// What `retro_load_game` is handed for one game.
///
/// Which case applies is decided once, when the core is constructed, by the
/// core's own `retro_system_info.need_fullpath`. `.fullPath` exists because a
/// `need_fullpath` core opens the file itself: an M3U only names other files,
/// and a PlayStation disc image runs to hundreds of megabytes, so reading
/// either into memory is wrong in principle and fatal on an Apple TV.
enum LoadPayload: Equatable {
    /// The core reads the game out of `retro_game_info.data`.
    case inMemory(Data)
    /// The core opens `retro_game_info.path` itself; no bytes are read here.
    case fullPath
}

/// Decides what a game is handed to the core as, knowing nothing about the
/// core beyond `need_fullpath`.
///
/// The data loader is a parameter so that "the full-path branch never reads
/// content" is an observable property of this type rather than a claim about
/// a branch buried in `loadGame(at:)`.
struct LoadPayloadFactory {
    typealias DataLoader = (URL) throws -> Data

    let needsFullPath: Bool
    private let loadData: DataLoader

    init(needsFullPath: Bool,
         loadData: @escaping DataLoader = { try Data(contentsOf: $0) }) {
        self.needsFullPath = needsFullPath
        self.loadData = loadData
    }

    func makePayload(for url: URL) throws -> LoadPayload {
        guard !needsFullPath else { return .fullPath }
        return .inMemory(try loadData(url))
    }
}

/// Owns a C-string copy of the loaded game's path.
///
/// A `need_fullpath` core keeps the path: an M3U core re-opens it to reach
/// the other discs, so the string has to outlive `retro_load_game`, which a
/// `withCString` pointer would not. Exactly one owner is assumed — this is
/// held privately by `LibretroCore` and never copied out.
struct RetainedPath {
    /// nil until a path is retained, and again after `release()`.
    private(set) var pointer: UnsafeMutablePointer<CChar>?

    /// Copies `path`, releasing whatever was retained before it. The pointer
    /// is nil afterwards only if the allocation failed.
    mutating func retain(_ path: String) {
        let copy = strdup(path)
        release()
        pointer = copy
    }

    /// Idempotent, so `unload()` and `deinit` can both run it.
    mutating func release() {
        guard let pointer else { return }
        free(pointer)
        self.pointer = nil
    }
}

/// The frontend half of libretro's Disk Control interface.
///
/// A core registers its callbacks through `retro_set_environment`; this value
/// keeps whichever it registered and runs disc switches against them. The two
/// interface versions are stored separately and the winner is picked at use
/// time, which is what makes the extended interface win whenever both are
/// registered — in either order.
struct DiskController {
    /// Answer to `GET_DISK_CONTROL_INTERFACE_VERSION`. Version 1 is what
    /// tells a core to register the extended interface instead of the
    /// deprecated one, so this has to be answered before it registers
    /// anything.
    static let interfaceVersion: UInt32 = 1

    /// The five entry points this frontend drives. Both interface versions
    /// declare them identically, which is what lets everything below stay
    /// unaware of which one registered.
    struct Callbacks {
        let setEjectState: @convention(c) (Bool) -> Bool
        let getEjectState: @convention(c) () -> Bool
        let getImageIndex: @convention(c) () -> UInt32
        let setImageIndex: @convention(c) (UInt32) -> Bool
        let getNumImages: @convention(c) () -> UInt32

        init?(_ callback: retro_disk_control_callback) {
            self.init(setEjectState: callback.set_eject_state,
                      getEjectState: callback.get_eject_state,
                      getImageIndex: callback.get_image_index,
                      setImageIndex: callback.set_image_index,
                      getNumImages: callback.get_num_images)
        }

        init?(_ callback: retro_disk_control_ext_callback) {
            self.init(setEjectState: callback.set_eject_state,
                      getEjectState: callback.get_eject_state,
                      getImageIndex: callback.get_image_index,
                      setImageIndex: callback.set_image_index,
                      getNumImages: callback.get_num_images)
        }

        /// Fails when any entry point this frontend calls is missing, so an
        /// unusable registration is dropped instead of becoming a null call
        /// at switch time. libretro calls every pointer in the struct
        /// mandatory, but the ones never called here are not checked:
        /// refusing a core over a missing `add_image_index` would turn a
        /// working disc into an unswitchable one for no benefit.
        private init?(setEjectState: (@convention(c) (Bool) -> Bool)?,
                      getEjectState: (@convention(c) () -> Bool)?,
                      getImageIndex: (@convention(c) () -> UInt32)?,
                      setImageIndex: (@convention(c) (UInt32) -> Bool)?,
                      getNumImages: (@convention(c) () -> UInt32)?) {
            guard let setEjectState, let getEjectState, let getImageIndex,
                  let setImageIndex, let getNumImages else { return nil }
            self.setEjectState = setEjectState
            self.getEjectState = getEjectState
            self.getImageIndex = getImageIndex
            self.setImageIndex = setImageIndex
            self.getNumImages = getNumImages
        }
    }

    private var legacy: Callbacks?
    private var extended: Callbacks?

    /// The interface a switch runs against: extended whenever it exists.
    private var active: Callbacks? { extended ?? legacy }

    /// Handles the three Disk Control environment commands, or returns nil if
    /// `command` is not one of them so the caller can fall through to the
    /// rest of its handling.
    ///
    /// The version query deliberately depends on nothing this type has
    /// stored: the core asks it *before* it registers anything, and a handler
    /// that consulted registration state would answer "no disk control" to
    /// the one core that has some.
    mutating func handleEnvironment(_ command: Int32,
                                    _ data: UnsafeMutableRawPointer?) -> Bool? {
        switch command {
        case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
            guard let data else { return false }   // nowhere to put the answer
            data.assumingMemoryBound(to: UInt32.self).pointee = Self.interfaceVersion
            return true
        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
            // NULL deregisters, and the call is answered either way.
            legacy = data.flatMap {
                Callbacks($0.assumingMemoryBound(to: retro_disk_control_callback.self).pointee)
            }
            return true
        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
            extended = data.flatMap {
                Callbacks($0.assumingMemoryBound(to: retro_disk_control_ext_callback.self).pointee)
            }
            return true
        default:
            return nil
        }
    }

    /// Drops both interfaces. Called from `unload()`: once the core's image is
    /// unmapped these are pointers into nothing, so "never call a core
    /// callback after unload" has to be structural rather than a rule.
    mutating func clear() {
        legacy = nil
        extended = nil
    }

    /// Whether a usable Disk Control interface is registered at all.
    ///
    /// Deliberately not inferred from `discCount == 0`: a core that registered
    /// an interface reporting no images and a core that registered nothing are
    /// two different sentences to a player — "this game's discs aren't ready"
    /// against "this core can't change discs" — and the disc UI asks both
    /// questions on its way to deciding whether to offer a switch.
    var hasDiskControl: Bool { active != nil }

    /// Discs the loaded game exposes; 0 when no interface is registered,
    /// which is every core in this app except Beetle PSX.
    var discCount: Int {
        guard let active else { return 0 }
        return Int(active.getNumImages())
    }

    /// The disc in the drive, or nil when no interface is registered, the tray
    /// is open, or no disc is inserted — libretro reports the last as an index
    /// at or past `get_num_images()`, which is not a disc anything can name.
    ///
    /// The tray is part of the question. `switchDisc` opens it, and its restore
    /// closing it again is best-effort: a double failure — the insert refused
    /// *and* the restore's close refused — leaves the tray standing open with
    /// `get_image_index()` still answering in range. Reporting that index would
    /// put "Disc 1" on screen over an open drive, which is the same lie as
    /// naming the disc a failed switch was reaching for.
    var currentIndex: Int? {
        guard let active, !active.getEjectState() else { return nil }
        let count = Int(active.getNumImages())
        let index = Int(active.getImageIndex())
        return index < count ? index : nil
    }

    /// Eject, set the index, insert — the order libretro documents, and the
    /// only order in which `set_image_index` is allowed to be called.
    ///
    /// Any step failing after the tray opens leaves the drive in a state
    /// nobody asked for, so the prior disc goes back and the tray is closed
    /// again before the error is thrown. That restore is best-effort: if the
    /// core refuses that too there is nothing further to try.
    func switchDisc(to index: Int) throws {
        guard let active else { throw CoreError.discControlUnavailable }
        let count = Int(active.getNumImages())
        guard index >= 0, index < count else {
            throw CoreError.discIndexOutOfRange(index: index, count: count)
        }
        let priorIndex = active.getImageIndex()
        let priorEjected = active.getEjectState()

        // Nothing has changed yet if the tray refuses to open, so there is
        // nothing to undo.
        guard active.setEjectState(true) else { throw CoreError.discSwitchFailed }
        guard active.setImageIndex(UInt32(index)) else {
            Self.restore(active, index: priorIndex, ejected: priorEjected)
            throw CoreError.discSwitchFailed
        }
        guard active.setEjectState(false) else {
            Self.restore(active, index: priorIndex, ejected: priorEjected)
            throw CoreError.discSwitchFailed
        }
    }

    private static func restore(_ callbacks: Callbacks, index: UInt32, ejected: Bool) {
        _ = callbacks.setImageIndex(index)
        _ = callbacks.setEjectState(ejected)
    }
}

public final class LibretroCore {
    public weak var sink: CoreAVSink?
    public private(set) var avInfo: CoreAVInfo?
    public private(set) var pixelFormat: CorePixelFormat = .rgb1555  // libretro default

    private let handle: UnsafeMutableRawPointer
    // The two things a loaded game may need kept alive. Which one is in use
    // is decided by the core's `need_fullpath`; both are cleared when a load
    // fails and when the core unloads. Readable in-module (not private) so
    // that the retention rules can be observed rather than asserted.
    private(set) var romData: Data?            // kept alive: cores may reference it
    private(set) var gamePath = RetainedPath()
    private let systemDirC: UnsafeMutablePointer<CChar>
    private let saveDirC: UnsafeMutablePointer<CChar>
    private let payloadFactory: LoadPayloadFactory
    private var diskController = DiskController()
    fileprivate var buttons = [Int16](repeating: 0, count: 16)
    private var gameLoaded = false
    private var isUnloaded = false

    /// What this core answered for `retro_system_info.need_fullpath`: whether
    /// it wants to be handed a path (Beetle PSX) or bytes (every other core
    /// this app ships).
    var needsFullPath: Bool { payloadFactory.needsFullPath }

    // dlsym'd entry points
    private typealias VoidFn = @convention(c) () -> Void
    private let fnInit: VoidFn, fnDeinit: VoidFn, fnRun: VoidFn
    private let fnUnloadGame: VoidFn, fnReset: VoidFn
    private let fnLoadGame: @convention(c) (UnsafePointer<retro_game_info>?) -> Bool
    private let fnGetAVInfo: @convention(c) (UnsafeMutablePointer<retro_system_av_info>?) -> Void
    private let fnSetControllerPortDevice: @convention(c) (UInt32, UInt32) -> Void
    private let fnGetMemoryData: @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    private let fnGetMemorySize: @convention(c) (UInt32) -> Int

    public init(dylibPath: String, systemDirectory: URL, saveDirectory: URL) throws {
        guard gCore == nil else { throw CoreError.alreadyLoaded }
        guard let h = dlopen(dylibPath, RTLD_NOW) else {
            throw CoreError.dlopenFailed(String(cString: dlerror()))
        }
        handle = h
        func sym<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let p = dlsym(h, name) else { throw CoreError.missingSymbol(name) }
            return unsafeBitCast(p, to: T.self)
        }
        fnInit = try sym("retro_init", VoidFn.self)
        fnDeinit = try sym("retro_deinit", VoidFn.self)
        fnRun = try sym("retro_run", VoidFn.self)
        fnUnloadGame = try sym("retro_unload_game", VoidFn.self)
        fnReset = try sym("retro_reset", VoidFn.self)
        fnLoadGame = try sym("retro_load_game",
            (@convention(c) (UnsafePointer<retro_game_info>?) -> Bool).self)
        fnGetAVInfo = try sym("retro_get_system_av_info",
            (@convention(c) (UnsafeMutablePointer<retro_system_av_info>?) -> Void).self)
        fnSetControllerPortDevice = try sym("retro_set_controller_port_device",
            (@convention(c) (UInt32, UInt32) -> Void).self)
        fnGetMemoryData = try sym("retro_get_memory_data",
            (@convention(c) (UInt32) -> UnsafeMutableRawPointer?).self)
        fnGetMemorySize = try sym("retro_get_memory_size",
            (@convention(c) (UInt32) -> Int).self)

        // `retro_get_system_info` is documented as callable at any time, even
        // before `retro_init`, and its answer is static — so ask once, here,
        // and let it decide how every game is handed over.
        let getSystemInfo = try sym("retro_get_system_info",
            (@convention(c) (UnsafeMutablePointer<retro_system_info>?) -> Void).self)
        var systemInfo = retro_system_info()
        getSystemInfo(&systemInfo)
        payloadFactory = LoadPayloadFactory(needsFullPath: systemInfo.need_fullpath)

        systemDirC = strdup(systemDirectory.path)
        saveDirC = strdup(saveDirectory.path)

        // Resolve the remaining symbols BEFORE publishing gCore: if any of
        // these throw, the process must still be able to construct a fresh
        // core afterward, so gCore may not be set until every lookup below
        // has already succeeded.
        let setEnvironment = try sym("retro_set_environment",
            (@convention(c) (retro_environment_t?) -> Void).self)
        let setVideoRefresh = try sym("retro_set_video_refresh",
            (@convention(c) (retro_video_refresh_t?) -> Void).self)
        let setAudioSample = try sym("retro_set_audio_sample",
            (@convention(c) (retro_audio_sample_t?) -> Void).self)
        let setAudioSampleBatch = try sym("retro_set_audio_sample_batch",
            (@convention(c) (retro_audio_sample_batch_t?) -> Void).self)
        let setInputPoll = try sym("retro_set_input_poll",
            (@convention(c) (retro_input_poll_t?) -> Void).self)
        let setInputState = try sym("retro_set_input_state",
            (@convention(c) (retro_input_state_t?) -> Void).self)

        // All symbol lookups succeeded: only now is it safe to publish the
        // singleton and let the static C callbacks route through it.
        gCore = self

        // Wire the static C callbacks BEFORE retro_init (libretro contract).
        setEnvironment(environmentCB)
        setVideoRefresh(videoCB)
        setAudioSample(audioSampleCB)
        setAudioSampleBatch(audioBatchCB)
        setInputPoll(inputPollCB)
        setInputState(inputStateCB)
        fnInit()
    }

    /// The `retro_game_info` a `need_fullpath` core must receive: the path and
    /// nothing else. libretro documents `data`/`size` as invalid in that case,
    /// and filling them in is exactly the several-hundred-megabyte read this
    /// branch exists to avoid.
    static func fullPathGameInfo(path: UnsafePointer<CChar>) -> retro_game_info {
        retro_game_info(path: path, data: nil, size: 0, meta: nil)
    }

    /// Hands the game to the core the way the core asked to receive it.
    ///
    /// One game per core: a second load would replace the retained path while
    /// a `need_fullpath` core is still reading through it, so it is refused
    /// rather than left to the caller to avoid.
    public func loadGame(at romURL: URL) throws {
        guard !gameLoaded else { throw CoreError.alreadyLoaded }
        let payload = try payloadFactory.makePayload(for: romURL)
        var loaded = false
        switch payload {
        case .inMemory(let data):
            // Unchanged from the pre-PlayStation implementation, deliberately:
            // every 2D core in this app loads through these lines, and the
            // pointer the core receives is only valid inside both closures.
            romData = data
            romURL.path.withCString { pathC in
                data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    var info = retro_game_info(path: pathC, data: buf.baseAddress,
                                               size: buf.count, meta: nil)
                    loaded = fnLoadGame(&info)
                }
            }
        case .fullPath:
            // The core opens this path itself and keeps re-opening it — an
            // M3U names the other discs — so it must outlive this call.
            gamePath.retain(romURL.path)
            guard let pathC = gamePath.pointer else { throw CoreError.loadGameFailed }
            var info = Self.fullPathGameInfo(path: pathC)
            loaded = fnLoadGame(&info)
        }
        guard loaded else {
            // Nothing is loaded, so nothing may still be held on its behalf.
            romData = nil
            gamePath.release()
            throw CoreError.loadGameFailed
        }
        gameLoaded = true
        var av = retro_system_av_info()
        fnGetAVInfo(&av)
        let g = av.geometry, t = av.timing
        avInfo = CoreAVInfo(
            baseWidth: Int(g.base_width), baseHeight: Int(g.base_height),
            maxWidth: Int(g.max_width), maxHeight: Int(g.max_height),
            fps: t.fps, sampleRate: t.sample_rate,
            aspectRatio: g.aspect_ratio > 0 ? Double(g.aspect_ratio)
                : Double(g.base_width) / Double(g.base_height))
        fnSetControllerPortDevice(0, UInt32(RETRO_DEVICE_JOYPAD))
    }

    public func runFrame() { fnRun() }

    /// Resets the running game to its power-on state (libretro `retro_reset`).
    /// Call only while a game is loaded; frames keep arriving afterward.
    public func resetGame() { fnReset() }

    private static let memorySaveRAM: UInt32 = 0   // RETRO_MEMORY_SAVE_RAM

    /// Copy of the core's battery-backed SAVE_RAM, nil if the core exposes none
    /// or the loaded game has no battery. Safe only while a game is loaded.
    public func saveRAM() -> Data? {
        let size = fnGetMemorySize(Self.memorySaveRAM)
        guard size > 0, let ptr = fnGetMemoryData(Self.memorySaveRAM) else { return nil }
        return Data(bytes: ptr, count: size)
    }

    /// Restores battery RAM. Call AFTER loadGame.
    ///
    /// - Returns: `false` when the core did **not** take the bytes — either its
    ///   SAVE_RAM is a different size from `data`, or it exposes none at all. In
    ///   neither case has anything been written.
    ///
    /// Deliberately not `@discardableResult`. A refused restore is not a state to
    /// play through: the core is left holding whatever it powered on with, and a
    /// caller that ignores the answer will flush *that* over the card it just
    /// failed to load. Size disagreement used to be impossible — the only source
    /// of `.srm` bytes was this device's own core — and is not any more, now that
    /// a card can arrive from RomM having been written by another Apple TV or by
    /// a core built with a different memory-card configuration.
    public func restoreRAM(_ data: Data) -> Bool {
        let size = fnGetMemorySize(Self.memorySaveRAM)
        guard size == data.count, size > 0,
              let ptr = fnGetMemoryData(Self.memorySaveRAM) else { return false }
        data.withUnsafeBytes { ptr.copyMemory(from: $0.baseAddress!, byteCount: size) }
        return true
    }

    public func setButton(_ button: RetroButton, pressed: Bool) {
        buttons[Int(button.rawValue)] = pressed ? 1 : 0
    }

    // MARK: disc switching

    /// Whether this core registered a Disk Control interface for the loaded
    /// game. Answers a different question from `discCount > 0`, which cannot
    /// distinguish a core with no interface from an interface reporting no
    /// images — and the disc UI needs both answers.
    ///
    /// Not a test for "this is PlayStation": Genesis Plus GX registers one too.
    /// `PreparedLaunch.discLabels` is the only authority for that.
    public var hasDiskControl: Bool { diskController.hasDiskControl }

    /// Discs the loaded game exposes. 0 for everything that isn't a
    /// multi-disc game running on a core with Disk Control.
    public var discCount: Int { diskController.discCount }

    /// The disc currently in the drive, or nil when there is no disc control
    /// or nothing is inserted.
    public var currentDiscIndex: Int? { diskController.currentIndex }

    /// Swaps the disc in the drive, throwing without leaving the drive empty
    /// if the core refuses.
    ///
    /// Main thread only, like every other entry point here: `EmulatorEngine`
    /// owns this object and must never run a switch alongside `runFrame()`.
    public func switchDisc(to index: Int) throws {
        try diskController.switchDisc(to: index)
    }

    public func unload() {
        guard !isUnloaded else { return }
        isUnloaded = true
        if gameLoaded { fnUnloadGame(); gameLoaded = false }
        // Drop the core's disk-control callbacks before its image goes away:
        // past this point they address unmapped code.
        diskController.clear()
        fnDeinit()
        dlclose(handle)
        romData = nil
        gamePath.release()
        if gCore === self { gCore = nil }
    }

    deinit { free(systemDirC); free(saveDirC); gamePath.release() }

    // MARK: environment handling (called from C)
    // Internal rather than fileprivate because this is the only way a core's
    // disk-control callbacks are ever registered: tests drive registration
    // through the real handler instead of through a hook added for them.
    func environment(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        let command = Int32(cmd & 0xFFFF)   // mask experimental flag
        // Disk Control first, and unconditionally: the version query arrives
        // before the core registers anything.
        if let answer = diskController.handleEnvironment(command, data) { return answer }
        switch command {
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            data?.assumingMemoryBound(to: Bool.self).pointee = true; return true
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            guard let raw = data?.assumingMemoryBound(to: Int32.self).pointee else { return false }
            switch raw {
            case 0: pixelFormat = .rgb1555
            case 1: pixelFormat = .xrgb8888
            case 2: pixelFormat = .rgb565
            default: return false
            }
            return true
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                .pointee = UnsafePointer(systemDirC)
            return true
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                .pointee = UnsafePointer(saveDirC)
            return true
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            data?.assumingMemoryBound(to: Bool.self).pointee = false; return true
        default:
            return false   // unknown/unsupported: the documented safe answer
        }
    }
}

// MARK: - static C callbacks (cannot capture context)
private let environmentCB: retro_environment_t = { cmd, data in
    gCore?.environment(cmd, data) ?? false
}
private let videoCB: retro_video_refresh_t = { data, width, height, pitch in
    guard let data, let core = gCore, let sink = core.sink else { return }
    sink.videoFrame(data, width: Int(width), height: Int(height),
                    pitchBytes: pitch, format: core.pixelFormat)
}
private let audioSampleCB: retro_audio_sample_t = { left, right in
    guard let sink = gCore?.sink else { return }
    var pair = [left, right]
    pair.withUnsafeBufferPointer { sink.audioFrames($0.baseAddress!, frameCount: 1) }
}
private let audioBatchCB: retro_audio_sample_batch_t = { samples, frames in
    guard let samples, let sink = gCore?.sink else { return frames }
    sink.audioFrames(samples, frameCount: frames)
    return frames
}
private let inputPollCB: retro_input_poll_t = { }
private let inputStateCB: retro_input_state_t = { port, device, _, id in
    guard port == 0, device == UInt32(RETRO_DEVICE_JOYPAD),
          let core = gCore, id < 16 else { return 0 }
    return core.buttons[Int(id)]
}

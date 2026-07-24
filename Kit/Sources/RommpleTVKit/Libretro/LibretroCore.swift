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

public enum RetroButton: Int32, CaseIterable, Sendable {
    case b = 0, y = 1, select = 2, start = 3, up = 4, down = 5, left = 6,
         right = 7, a = 8, x = 9, l = 10, r = 11
}

public enum CoreError: Error {
    case dlopenFailed(String), missingSymbol(String), loadGameFailed, alreadyLoaded
}

extension CoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .dlopenFailed(let msg): return "Couldn't load the emulator core (\(msg))."
        case .missingSymbol(let name): return "The emulator core is incomplete (missing \(name))."
        case .loadGameFailed: return "The core rejected this ROM file."
        case .alreadyLoaded: return "Another game is still running — back out and try again."
        }
    }
}

public final class LibretroCore {
    public weak var sink: CoreAVSink?
    public private(set) var avInfo: CoreAVInfo?
    public private(set) var pixelFormat: CorePixelFormat = .rgb1555  // libretro default

    private let handle: UnsafeMutableRawPointer
    private var romData: Data?                 // kept alive: cores may reference it
    private let systemDirC: UnsafeMutablePointer<CChar>
    private let saveDirC: UnsafeMutablePointer<CChar>
    fileprivate var buttons = [Int16](repeating: 0, count: 16)
    private var gameLoaded = false
    private var isUnloaded = false

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

    public func loadGame(at romURL: URL) throws {
        let data = try Data(contentsOf: romURL)
        romData = data
        var loaded = false
        romURL.path.withCString { pathC in
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var info = retro_game_info(path: pathC, data: buf.baseAddress,
                                           size: buf.count, meta: nil)
                loaded = fnLoadGame(&info)
            }
        }
        guard loaded else { throw CoreError.loadGameFailed }
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

    /// Restores battery RAM. Call AFTER loadGame. Returns false on size mismatch.
    @discardableResult
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

    public func unload() {
        guard !isUnloaded else { return }
        isUnloaded = true
        if gameLoaded { fnUnloadGame(); gameLoaded = false }
        fnDeinit()
        dlclose(handle)
        romData = nil
        if gCore === self { gCore = nil }
    }

    deinit { free(systemDirC); free(saveDirC) }

    // MARK: environment handling (called from C)
    fileprivate func environment(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch Int32(cmd & 0xFFFF) {   // mask experimental flag
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

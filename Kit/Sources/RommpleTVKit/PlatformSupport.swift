import Foundation

public struct CoreDescriptor: Equatable, Sendable {
    public let coreName: String
    public let displayName: String
}

public enum PlatformSupport {
    // RomM slugs (docs.romm.app platform list) → embedded cores.
    // segacd needs BIOS; mapping kept so the engine's error view explains the
    // gap instead of the platform looking unplayable.
    //
    // psx/ps1 map to a core but are intentionally excluded from
    // launchReadySlugs: Beetle PSX needs the multi-file cue/bin package
    // download, BIOS retrieval, and M3U preparation stack (Phase 2B tasks
    // 2-9) before a disc can actually launch. Task 10 adds psx/ps1 to
    // launchReadySlugs once that stack lands.
    private static let map: [String: CoreDescriptor] = {
        let snes = CoreDescriptor(coreName: "snes9x_libretro_tvos", displayName: "snes9x")
        let nes = CoreDescriptor(coreName: "fceumm_libretro_tvos", displayName: "FCEUmm")
        let mgba = CoreDescriptor(coreName: "mgba_libretro_tvos", displayName: "mGBA")
        let gen = CoreDescriptor(coreName: "genesis_plus_gx_libretro_tvos", displayName: "Genesis Plus GX")
        let vb = CoreDescriptor(coreName: "mednafen_vb_libretro_tvos", displayName: "Beetle VB")
        let psx = CoreDescriptor(coreName: "mednafen_psx_libretro_tvos", displayName: "Beetle PSX")
        return ["snes": snes, "nes": nes,
                "gba": mgba, "gb": mgba, "gbc": mgba,
                "genesis": gen, "segacd": gen, "sms": gen, "gamegear": gen,
                "virtualboy": vb,
                "psx": psx, "ps1": psx]
    }()
    // Slugs that map to a core AND are ready to launch today. psx/ps1 are
    // deliberately absent here even though they're in `map` above — see the
    // comment on `map`.
    private static let launchReadySlugs: Set<String> = [
        "snes", "nes", "gba", "gb", "gbc",
        "genesis", "segacd", "sms", "gamegear",
        "virtualboy",
    ]
    public static func core(forSlug slug: String) -> CoreDescriptor? { map[slug.lowercased()] }
    public static func isPlayable(slug: String) -> Bool {
        let key = slug.lowercased()
        return map[key] != nil && launchReadySlugs.contains(key)
    }
}

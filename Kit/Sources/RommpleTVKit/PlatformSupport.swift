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
    // psx/ps1 are launch-ready as of Task 10: every launch — legacy and
    // PlayStation — now goes through `LaunchPreparationService`, which routes a
    // PlayStation request to the package store, the firmware manager and the
    // save coordinator built in Phase 2B tasks 2-9. Before that route existed
    // these two slugs were deliberately absent, because the legacy path
    // downloads one file and a PlayStation game is a directory of up to nine
    // plus a playlist and a BIOS.
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
    // Slugs that map to a core AND are ready to launch today. The PlayStation
    // pair is folded in from `playStationSlugs` rather than spelled again, so
    // the set that decides "this card can be pressed" and the set that decides
    // "this card takes the PlayStation route" cannot drift apart — a slug in one
    // and not the other is either an unlaunchable card or a PlayStation disc on
    // the single-file legacy path.
    private static let launchReadySlugs: Set<String> = Set([
        "snes", "nes", "gba", "gb", "gbc",
        "genesis", "segacd", "sms", "gamegear",
        "virtualboy",
    ]).union(playStationSlugs)
    /// The slugs the PlayStation preparation route serves.
    ///
    /// `psx` is the real platform on the live server; `ps1` is a stray empty
    /// platform kept as a harmless alias so a differently-configured server
    /// still routes correctly. A caller asks this rather than comparing a
    /// string, so the two spellings cannot drift apart between the launch route
    /// and the launch-ready set.
    public static let playStationSlugs: Set<String> = ["psx", "ps1"]

    /// Whether this platform launches through `LaunchPreparationService`'s
    /// PlayStation route — a package of discs, a BIOS and a memory card — rather
    /// than the single-file legacy route.
    public static func isPlayStation(slug: String) -> Bool {
        playStationSlugs.contains(slug.lowercased())
    }

    public static func core(forSlug slug: String) -> CoreDescriptor? { map[slug.lowercased()] }
    public static func isPlayable(slug: String) -> Bool {
        let key = slug.lowercased()
        return map[key] != nil && launchReadySlugs.contains(key)
    }
}

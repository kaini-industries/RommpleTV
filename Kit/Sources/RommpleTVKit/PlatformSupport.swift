import Foundation

public struct CoreDescriptor: Equatable, Sendable {
    public let coreName: String
    public let displayName: String
}

public enum PlatformSupport {
    // RomM slugs (docs.romm.app platform list) → embedded cores.
    // segacd needs BIOS; mapping kept so the engine's error view explains the
    // gap instead of the platform looking unplayable.
    private static let map: [String: CoreDescriptor] = {
        let snes = CoreDescriptor(coreName: "snes9x_libretro_tvos", displayName: "snes9x")
        let nes = CoreDescriptor(coreName: "fceumm_libretro_tvos", displayName: "FCEUmm")
        let mgba = CoreDescriptor(coreName: "mgba_libretro_tvos", displayName: "mGBA")
        let gen = CoreDescriptor(coreName: "genesis_plus_gx_libretro_tvos", displayName: "Genesis Plus GX")
        let vb = CoreDescriptor(coreName: "mednafen_vb_libretro_tvos", displayName: "Beetle VB")
        return ["snes": snes, "nes": nes,
                "gba": mgba, "gb": mgba, "gbc": mgba,
                "genesis": gen, "segacd": gen, "sms": gen, "gamegear": gen,
                "virtualboy": vb]
    }()
    public static func core(forSlug slug: String) -> CoreDescriptor? { map[slug.lowercased()] }
    public static func isPlayable(slug: String) -> Bool { core(forSlug: slug) != nil }
}

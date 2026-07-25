import XCTest
@testable import RommpleTVKit

final class PlatformSupportTests: XCTestCase {
    func testPlayableSlugsMapToCores() {
        let expected: [String: String] = [
            "snes": "snes9x_libretro_tvos",
            "nes": "fceumm_libretro_tvos",
            "gba": "mgba_libretro_tvos",
            "gb": "mgba_libretro_tvos",
            "gbc": "mgba_libretro_tvos",
            "genesis": "genesis_plus_gx_libretro_tvos",
            "segacd": "genesis_plus_gx_libretro_tvos",
            "sms": "genesis_plus_gx_libretro_tvos",
            "gamegear": "genesis_plus_gx_libretro_tvos",
            "virtualboy": "mednafen_vb_libretro_tvos",
        ]
        for (slug, core) in expected {
            XCTAssertEqual(PlatformSupport.core(forSlug: slug)?.coreName, core, slug)
            XCTAssertTrue(PlatformSupport.isPlayable(slug: slug), slug)
        }
    }
    func testUnplayableSlugs() {
        for slug in ["gamecube", "wii", "ps2", "switch", "n64"] {
            XCTAssertNil(PlatformSupport.core(forSlug: slug), slug)
            XCTAssertFalse(PlatformSupport.isPlayable(slug: slug), slug)
        }
    }
    func testCaseInsensitive() {
        XCTAssertNotNil(PlatformSupport.core(forSlug: "SNES"))
        XCTAssertTrue(PlatformSupport.isPlayable(slug: "SNES"))
    }
    func testPlayStationUsesSoftwareBeetlePSX() {
        let core = PlatformSupport.core(forSlug: "psx")
        XCTAssertEqual(core?.coreName, "mednafen_psx_libretro_tvos")
        XCTAssertEqual(core?.displayName, "Beetle PSX")
        XCTAssertFalse(PlatformSupport.isPlayable(slug: "PSX"))
        XCTAssertEqual(PlatformSupport.core(forSlug: "ps1")?.coreName, "mednafen_psx_libretro_tvos")
        XCTAssertFalse(PlatformSupport.isPlayable(slug: "ps1"))
    }
}

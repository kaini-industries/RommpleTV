import XCTest
import CLibretro
@testable import RommpleTVKit

final class SmokeTests: XCTestCase {
    func testLibretroTypesImport() {
        var info = retro_system_info()
        info.need_fullpath = false
        XCTAssertFalse(info.need_fullpath)
        XCTAssertEqual(RETRO_API_VERSION, 1)
    }
}

import XCTest
@testable import RommpleTVKit

final class BatterySaveStoreTests: XCTestCase {
    var tmp: URL!; var defaults: UserDefaults!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "BatterySaveStoreTests")!
        defaults.removePersistentDomain(forName: "BatterySaveStoreTests")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: "BatterySaveStoreTests") }

    func store() -> BatterySaveStore { BatterySaveStore(cachesRoot: tmp, defaults: defaults) }

    func testRoundtripSmallSave() {
        let sram = Data((0..<2048).map { UInt8($0 % 251) })
        store().save(sram, romID: 42)
        XCTAssertEqual(store().load(romID: 42), sram)
        XCTAssertNotNil(defaults.data(forKey: "srm.42"), "small save must mirror to defaults")
    }
    func testLargeSaveSkipsDefaultsMirror() {
        let big = Data(repeating: 7, count: 128 * 1024)
        store().save(big, romID: 9)
        XCTAssertEqual(store().load(romID: 9), big)
        XCTAssertNil(defaults.data(forKey: "srm.9"), "128KB must not enter the ~500KB defaults budget")
    }
    func testDefaultsFallbackWhenCachesPurged() {
        let sram = Data([1, 2, 3, 4])
        store().save(sram, romID: 7)
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent("saves"))
        XCTAssertEqual(store().load(romID: 7), sram, "purged Caches must fall back to defaults mirror")
    }
    func testDelete() {
        store().save(Data([9]), romID: 5)
        store().delete(romID: 5)
        XCTAssertNil(store().load(romID: 5))
        XCTAssertNil(defaults.data(forKey: "srm.5"))
    }
    func testMissingIsNil() { XCTAssertNil(store().load(romID: 404)) }
    func testSaveResizeAboveLimitClearsStaleMirror() {
        let small = Data(repeating: 1, count: 2048)
        store().save(small, romID: 3)
        XCTAssertNotNil(defaults.data(forKey: "srm.3"), "small save must mirror to defaults")
        let big = Data(repeating: 7, count: 100 * 1024)
        store().save(big, romID: 3)
        XCTAssertNil(defaults.data(forKey: "srm.3"), "resized save must clear stale defaults mirror")
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent("saves"))
        XCTAssertNil(store().load(romID: 3), "purged Caches must not resurrect stale mirror")
    }
}

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
    override func tearDown() {
        // A test that chmods a path to 000 would otherwise leave a directory the
        // harness cannot remove.
        restorePermissions(under: tmp)
        try? FileManager.default.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: "BatterySaveStoreTests")
    }

    private func restorePermissions(under root: URL) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: root.path) else { return }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        for case let relative as String in walker {
            try? manager.setAttributes([.posixPermissions: 0o644],
                                       ofItemAtPath: root.appendingPathComponent(relative).path)
        }
    }

    func store() -> BatterySaveStore { BatterySaveStore(cachesRoot: tmp, defaults: defaults) }

    func testRoundtripSmallSave() throws {
        let sram = Data((0..<2048).map { UInt8($0 % 251) })
        try store().save(sram, romID: 42)
        XCTAssertEqual(try store().load(romID: 42), sram)
        XCTAssertNotNil(defaults.data(forKey: "srm.42"), "small save must mirror to defaults")
    }
    func testLargeSaveSkipsDefaultsMirror() throws {
        let big = Data(repeating: 7, count: 128 * 1024)
        try store().save(big, romID: 9)
        XCTAssertEqual(try store().load(romID: 9), big)
        XCTAssertNil(defaults.data(forKey: "srm.9"), "128KB must not enter the ~500KB defaults budget")
    }
    func testDefaultsFallbackWhenCachesPurged() throws {
        let sram = Data([1, 2, 3, 4])
        try store().save(sram, romID: 7)
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent("saves"))
        XCTAssertEqual(try store().load(romID: 7), sram,
                       "purged Caches must fall back to defaults mirror")
    }
    func testDelete() throws {
        try store().save(Data([9]), romID: 5)
        store().delete(romID: 5)
        XCTAssertNil(try store().load(romID: 5))
        XCTAssertNil(defaults.data(forKey: "srm.5"))
    }
    func testMissingIsNil() throws { XCTAssertNil(try store().load(romID: 404)) }
    func testSaveResizeAboveLimitClearsStaleMirror() throws {
        let small = Data(repeating: 1, count: 2048)
        try store().save(small, romID: 3)
        XCTAssertNotNil(defaults.data(forKey: "srm.3"), "small save must mirror to defaults")
        let big = Data(repeating: 7, count: 100 * 1024)
        try store().save(big, romID: 3)
        XCTAssertNil(defaults.data(forKey: "srm.3"), "resized save must clear stale defaults mirror")
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent("saves"))
        XCTAssertNil(try store().load(romID: 3), "purged Caches must not resurrect stale mirror")
    }

    // MARK: - Absence is not a read failure

    /// The invariant `PS1SaveCoordinator` is built on: a card that cannot be read
    /// is not a card that is not there. Returning `nil` here would let the
    /// coordinator's "baselined card missing locally" branch fire on a permission
    /// error and replace a known-good card with a blank one.
    func testUnreadableFileThrowsRatherThanReportingAbsence() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000-mode file, so the error cannot be provoked")
        let sram = Data(repeating: 3, count: 4096)
        try store().save(sram, romID: 11)
        let file = tmp.appendingPathComponent("saves/11.srm")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        XCTAssertThrowsError(try store().load(romID: 11)) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, NSCocoaErrorDomain)
            XCTAssertEqual(ns.code, NSFileReadNoPermissionError)
        }
    }

    /// And it throws *even though* an eligible small-save mirror exists. Silently
    /// answering from the mirror would hide a cache file that is present and
    /// possibly newer behind a stale copy.
    func testUnreadableFileThrowsEvenWhenMirrorCouldAnswer() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000-mode file, so the error cannot be provoked")
        let sram = Data(repeating: 3, count: 4096)
        try store().save(sram, romID: 12)
        XCTAssertNotNil(defaults.data(forKey: "srm.12"), "precondition: the mirror is populated")
        let file = tmp.appendingPathComponent("saves/12.srm")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        XCTAssertThrowsError(try store().load(romID: 12),
                             "a readable mirror must not mask an unreadable cache file")
    }

    /// A directory sitting where the card should be is `NSFileReadUnknownError`
    /// (256), not "no such file". Also not absence.
    func testNonFileAtCardPathThrows() throws {
        let dir = tmp.appendingPathComponent("saves/13.srm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store().load(romID: 13))
    }

    /// A missing `saves` directory is still absence, not failure — Caches is
    /// purgeable and the whole directory going away is the ordinary case.
    func testMissingDirectoryIsAbsenceNotFailure() throws {
        XCTAssertNil(try store().load(romID: 14))
    }

    // MARK: - Failed writes

    func testSaveThrowsWhenCacheWriteFails() throws {
        // A regular file where the `saves` directory must go: `createDirectory`
        // fails, and so does every write beneath it.
        try Data([0]).write(to: tmp.appendingPathComponent("saves"))
        XCTAssertThrowsError(try store().save(Data(repeating: 1, count: 32), romID: 21))
    }

    /// The file is written before the mirror, so a failed write leaves the pair
    /// consistent: neither side moved. A mirror updated ahead of a failed write
    /// would make `load` answer with bytes that are not what is on disk.
    func testFailedWriteLeavesMirrorUntouched() throws {
        try Data([0]).write(to: tmp.appendingPathComponent("saves"))
        XCTAssertThrowsError(try store().save(Data(repeating: 1, count: 32), romID: 22))
        XCTAssertNil(defaults.data(forKey: "srm.22"),
                     "a failed cache write must not publish the new bytes to the mirror")
    }

    func testFailedWritePreservesPreviousMirror() throws {
        let original = Data(repeating: 5, count: 1024)
        try store().save(original, romID: 23)
        // Replace the whole saves directory with a file so the next write fails.
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("saves"))
        try Data([0]).write(to: tmp.appendingPathComponent("saves"))

        XCTAssertThrowsError(try store().save(Data(repeating: 6, count: 1024), romID: 23))
        XCTAssertEqual(defaults.data(forKey: "srm.23"), original,
                       "a failed write must not disturb the bytes already mirrored")
    }

    /// A resize past the mirror limit must not clear the mirror unless the cache
    /// write that justifies clearing it actually landed.
    func testFailedOversizeWriteDoesNotClearMirror() throws {
        let small = Data(repeating: 5, count: 1024)
        try store().save(small, romID: 24)
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("saves"))
        try Data([0]).write(to: tmp.appendingPathComponent("saves"))

        XCTAssertThrowsError(try store().save(Data(repeating: 6, count: 100 * 1024), romID: 24))
        XCTAssertEqual(defaults.data(forKey: "srm.24"), small,
                       "a failed write must not clear the mirror it did not replace")
    }

    // MARK: - The protocol seam

    func testConformsToSaveRAMStoring() throws {
        let seam: any SaveRAMStoring = store()
        let card = Data(repeating: 9, count: 256)
        try seam.save(card, romID: 31)
        XCTAssertEqual(try seam.load(romID: 31), card)
        XCTAssertNil(try seam.load(romID: 32))
    }

    func testReportsModificationDateForAnExistingCard() throws {
        let before = Date().addingTimeInterval(-2)
        try store().save(Data(repeating: 1, count: 64), romID: 33)
        let stamp = try XCTUnwrap(store().modificationDate(romID: 33))
        XCTAssertGreaterThanOrEqual(stamp, before)
        XCTAssertNil(store().modificationDate(romID: 34), "no card, no date")
    }

    // MARK: - Concurrency

    /// The cache file and the defaults mirror are written as one critical section.
    /// Without that, two concurrent saves interleave as write(A) / write(B) /
    /// mirror(B) / mirror(A) and leave the mirror describing bytes the cache file
    /// does not hold — which a Caches purge then promotes to the live card.
    ///
    /// Probabilistic by nature: it races real threads. 400 rounds of 6 writers is
    /// enough that removing the lock fails it every time it was tried.
    func testConcurrentSavesKeepCacheFileAndMirrorConsistent() throws {
        let store = self.store()
        let values: [Data] = (1...6).map { Data(repeating: UInt8($0), count: 4096) }
        let file = tmp.appendingPathComponent("saves/41.srm")

        for _ in 0..<400 {
            DispatchQueue.concurrentPerform(iterations: values.count) { index in
                try? store.save(values[index], romID: 41)
            }
            let onDisk = try Data(contentsOf: file)
            let mirrored = try XCTUnwrap(self.defaults.data(forKey: "srm.41"))
            XCTAssertEqual(onDisk, mirrored,
                           "cache file and defaults mirror must describe the same card")
        }
    }

    /// A reader never sees half a card, whatever a writer is doing.
    func testConcurrentLoadsNeverExposeAPartialCard() throws {
        let store = self.store()
        let cardSize = 128 * 1024
        let values: [Data] = (1...4).map { Data(repeating: UInt8($0), count: cardSize) }
        try store.save(values[0], romID: 42)

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for round in 0..<200 {
                if worker % 2 == 0 {
                    try? store.save(values[(worker + round) % values.count], romID: 42)
                } else {
                    guard let loaded = try? store.load(romID: 42) else { continue }
                    XCTAssertEqual(loaded.count, cardSize, "a torn card reached a reader")
                    let first = loaded.first
                    XCTAssertTrue(loaded.allSatisfy { $0 == first },
                                  "a reader saw two cards spliced together")
                }
            }
        }
    }
}

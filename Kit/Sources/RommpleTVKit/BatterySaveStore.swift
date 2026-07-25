import Foundation

/// The local card area, as the rest of the app sees it.
///
/// Two methods, both throwing, and the distinction between them is the whole
/// point: `load` answers `nil` **only** when the card is genuinely not there, and
/// throws for every other reason a read can fail. `PS1SaveCoordinator` decides
/// whether to replace a card on that answer, so "I could not read it" arriving as
/// "it is not there" is how a known-good memory card gets replaced by a blank one.
public protocol SaveRAMStoring: AnyObject, Sendable {
    /// The stored card, or `nil` if there is none. Throws on any read failure
    /// that is not absence.
    func load(romID: Int) throws -> Data?
    /// Replaces the stored card. Throws if the write did not land.
    func save(_ data: Data, romID: Int) throws
}

/// When a stored card was last written, for a conflict screen that has to tell a
/// player which of two cards is theirs.
///
/// Deliberately separate from `SaveRAMStoring` rather than a third requirement on
/// it: a date is presentation, not persistence, and a store that cannot supply one
/// must still be a legal card store. `PS1SaveCoordinator` asks for this
/// conditionally and shows no local date when the answer is `nil`.
public protocol SaveRAMModificationDating: AnyObject, Sendable {
    func modificationDate(romID: Int) -> Date?
}

/// Battery-save (SRAM) persistence under tvOS's rules: Caches is roomy but
/// purgeable; UserDefaults is guaranteed but ~500KB total. Small saves get
/// both; big saves ride Caches.
///
/// PlayStation memory cards are ~128 KiB and therefore *never* mirrored — the
/// ≤64 KiB rule is what keeps a card out of the defaults budget, and it is
/// checked here rather than at any call site.
///
/// **Ordering.** `save` writes the cache file first and only then touches the
/// mirror. A failed write throws with the mirror untouched, so the two never
/// describe different cards: either both moved forward or neither did. (The
/// previous version swallowed write failures on the theory that the mirror
/// covered small saves; that silently produced a mirror newer than the file, and
/// a Caches purge then promoted the wrong bytes.)
///
/// **Concurrency.** `@unchecked Sendable` is earned by `lock`, not asserted: it
/// guards each `load`/`save`/`delete` as one critical section, so two concurrent
/// saves cannot interleave into write(A) / write(B) / mirror(B) / mirror(A).
/// `savesDir` and `defaults` are immutable, and `UserDefaults` is itself
/// thread-safe; the pairing is the only thing that needs protecting.
public final class BatterySaveStore: SaveRAMStoring, SaveRAMModificationDating, @unchecked Sendable {
    public static let mirrorLimit = 65536
    private let savesDir: URL
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(cachesRoot: URL, defaults: UserDefaults = .standard) {
        self.savesDir = cachesRoot.appendingPathComponent("saves", isDirectory: true)
        self.defaults = defaults
    }

    public func save(_ sram: Data, romID: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        // `try?`: a directory that already exists reports failure on some
        // volumes, and the write below is the authoritative check either way.
        try? FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
        try sram.write(to: fileURL(romID), options: .atomic)
        if sram.count <= Self.mirrorLimit {
            defaults.set(sram, forKey: key(romID))
        } else {
            defaults.removeObject(forKey: key(romID))
        }
    }

    /// The stored card, `nil` when there is none, or a throw.
    ///
    /// Only "no such file" counts as absence. A permission error, a directory
    /// sitting at the card's path, or an I/O failure all throw — including when an
    /// eligible mirror could have answered, because a cache file that exists and
    /// cannot be read may hold newer bytes than the mirror, and quietly preferring
    /// the mirror would hand back a stale card as though it were the current one.
    public func load(romID: Int) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try Data(contentsOf: fileURL(romID))
        } catch {
            guard Self.isAbsence(error) else { throw error }
        }
        return defaults.data(forKey: key(romID))
    }

    public func delete(romID: Int) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(romID))
        defaults.removeObject(forKey: key(romID))
    }

    /// When the cache file was last written, or `nil` if there is no file. The
    /// mirror carries no timestamp, so a card that survives only in defaults has
    /// no date — which is why the coordinator treats this as optional.
    public func modificationDate(romID: Int) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(romID).path)
        return attributes?[.modificationDate] as? Date
    }

    /// Whether a read failure means "there is no card" as opposed to "the card
    /// could not be read". `NSFileReadNoSuchFileError` (260) is what
    /// `Data(contentsOf:)` reports for both a missing file and a missing parent
    /// directory, which is the ordinary case on purgeable Caches;
    /// `NSFileNoSuchFileError` (4) and POSIX `ENOENT` are the same condition
    /// reported by other layers. Everything else — 257 no-permission, 256 unknown
    /// (what a directory at the card's path produces) — is a failure.
    static func isAbsence(_ error: Error) -> Bool {
        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain:
            return ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError
        case NSPOSIXErrorDomain:
            return ns.code == Int(ENOENT)
        default:
            return false
        }
    }

    private func fileURL(_ romID: Int) -> URL {
        savesDir.appendingPathComponent("\(romID).srm", isDirectory: false)
    }
    private func key(_ romID: Int) -> String { "srm.\(romID)" }
}

import Foundation

/// Battery-save (SRAM) persistence under tvOS's rules: Caches is roomy but
/// purgeable; UserDefaults is guaranteed but ~500KB total. Small saves get
/// both; big saves ride Caches.
///
/// File-operation failures are silently tolerated: the defaults mirror covers
/// small saves. No logging machinery here.
public final class BatterySaveStore {
    public static let mirrorLimit = 65536
    private let savesDir: URL
    private let defaults: UserDefaults

    public init(cachesRoot: URL, defaults: UserDefaults = .standard) {
        self.savesDir = cachesRoot.appendingPathComponent("saves", isDirectory: true)
        self.defaults = defaults
    }

    public func save(_ sram: Data, romID: Int) {
        try? FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
        try? sram.write(to: fileURL(romID), options: .atomic)
        if sram.count <= Self.mirrorLimit {
            defaults.set(sram, forKey: key(romID))
        } else {
            defaults.removeObject(forKey: key(romID))
        }
    }

    public func load(romID: Int) -> Data? {
        if let data = try? Data(contentsOf: fileURL(romID)) { return data }
        return defaults.data(forKey: key(romID))
    }

    public func delete(romID: Int) {
        try? FileManager.default.removeItem(at: fileURL(romID))
        defaults.removeObject(forKey: key(romID))
    }

    private func fileURL(_ romID: Int) -> URL {
        savesDir.appendingPathComponent("\(romID).srm", isDirectory: false)
    }
    private func key(_ romID: Int) -> String { "srm.\(romID)" }
}

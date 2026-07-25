#if DEBUG
import SwiftUI
import RommpleTVKit

/// A fully synthetic root, reachable only when the process was launched with an
/// explicit `-ui-test-scenario <name>` argument.
///
/// Three rules, and all three are the point of the file rather than decoration:
///
/// - **The whole file is `#if DEBUG`.** A release build contains no fixture
///   route, no scenario names and no reference to any of this.
/// - **Nothing here reads configuration or contacts a server.**
///   `RommpleTVApp` does not even construct a `RommConfig` on this route, so
///   there is no client, no token and no address in the process.
/// - **Every byte, label and date is invented.** Titles are fictional, the
///   memory cards are two short strings, and the "package" is a file name that
///   is never opened.
enum UITestScenario: String, CaseIterable {
    /// Two memory cards, a chooser, and a resolution that then completes.
    case conflict
    /// A preparation that reports progress and then waits, so Cancel has
    /// something to interrupt.
    case cancel
    /// A recoverable failure on the first attempt and success on the second.
    case retry
    /// A disc set the classifier merged, so the disc list and its override are
    /// on screen.
    case discs

    static let argument = "-ui-test-scenario"

    /// The scenario named by `-ui-test-scenario <name>`, or nil.
    ///
    /// The value must follow the flag, so no environment variable, no default
    /// and no partial match can put the app on this route by accident.
    static func selected(from arguments: [String]) -> UITestScenario? {
        guard let flag = arguments.firstIndex(of: argument), flag + 1 < arguments.count else {
            return nil
        }
        return UITestScenario(rawValue: arguments[flag + 1])
    }
}

/// The fixture root: a stand-in library with one launch already pushed onto it,
/// so `dismiss()` from the preparation screen returns to something a test can
/// see.
struct UITestScenarioView: View {
    let scenario: UITestScenario
    @State private var path = [0]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 24) {
                Text("Fixture Library")
                    .font(.title2)
                    .accessibilityIdentifier("fixture.library")
                Button("Launch") { path = [0] }
                    .accessibilityIdentifier("fixture.launch")
            }
            .navigationDestination(for: Int.self) { _ in preparation }
        }
    }

    private var preparation: some View {
        let fixture = UITestFixture(scenario: scenario)
        return LaunchPreparationView(
            model: LaunchPreparationModel(request: fixture.request,
                                          dependencies: fixture.dependencies),
            title: "Fixture Game"
        ) { launch in
            VStack(spacing: 16) {
                Text("Ready")
                    .font(.title2)
                    .accessibilityIdentifier("fixture.ready")
                Text(launch.entryURL.lastPathComponent)
                    .accessibilityIdentifier("fixture.entry")
            }
        }
    }
}

// MARK: - Synthetic seams

/// An in-memory card area. Nothing here touches the filesystem.
private final class FixtureCardStore: SaveRAMStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [Int: Data] = [:]

    init(card: Data?, romID: Int) {
        if let card { cards[romID] = card }
    }

    func load(romID: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return cards[romID]
    }

    func save(_ data: Data, romID: Int) throws {
        lock.lock(); cards[romID] = data; lock.unlock()
    }
}

private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var choice: PS1ConflictChoice?

    func nextAttempt() -> Int { lock.lock(); attempts += 1; let n = attempts; lock.unlock(); return n }
    func record(_ value: PS1ConflictChoice) { lock.lock(); choice = value; lock.unlock() }
    var recordedChoice: PS1ConflictChoice? { lock.lock(); defer { lock.unlock() }; return choice }
}

/// One scenario's request and seams.
private struct UITestFixture {
    let request: LaunchRequest
    let dependencies: LaunchPreparationDependencies

    static let canonicalRomID = 909_090
    static let platformID = 909

    init(scenario: UITestScenario) {
        let state = FixtureState()
        let game = Self.game(merged: scenario == .discs)
        request = .playStation(game: game, platformID: Self.platformID)

        let store = FixtureCardStore(card: Data("fixture-local-card".utf8),
                                     romID: Self.canonicalRomID)
        let conflict = PS1SaveConflict(id: UUID(),
                                       localModifiedAt: Date(timeIntervalSince1970: 1_772_000_000),
                                       remoteModifiedAt: Date(timeIntervalSince1970: 1_772_086_400))
        let systemDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-system", isDirectory: true)

        let playStation = PlayStationLaunchDependencies(
            reconcileSave: {
                scenario == .conflict ? .conflict(conflict) : .ready
            },
            resolveConflict: { _, choice in state.record(choice) },
            prepareFirmware: { _, _, progress in
                if scenario == .retry, state.nextAttempt() == 1 {
                    throw PS1FirmwareError.fetchFailed(fileName: "scph5501.bin",
                                                       reason: .network(.timedOut))
                }
                progress(.validating(label: "scph5501.bin"))
                return systemDirectory
            },
            preparePackage: { game, progress in
                progress(.downloading(label: "Disc 1", completed: 12_582_912,
                                      total: 419_430_400))
                if scenario == .cancel || (scenario == .discs && game.discs.count > 1) {
                    // Long enough that no test can outrun it, and a cancellation
                    // point so Cancel actually interrupts something. The disc
                    // scenario holds here too, because the disc list only exists
                    // while preparation is on screen — and the single-disc
                    // override, whose whole purpose is to change the set, then
                    // runs straight through to ready.
                    try await Task.sleep(nanoseconds: 600_000_000_000)
                }
                let suffix = state.recordedChoice.map { "-\($0 == .local ? "local" : "remote")" }
                    ?? ""
                return PreparedDiscSet(
                    entryURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("fixture\(suffix).m3u"),
                    canonicalRomID: game.canonicalRomID,
                    discLabels: game.discs.map(\.label))
            },
            saveDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("fixture-saves", isDirectory: true),
            saveStore: store,
            onLocalSave: { _ in },
            retrySaveSync: { _ in },
            saveStatuses: nil)

        dependencies = LaunchPreparationDependencies(
            legacy: LegacyLaunchDependencies(
                download: { _, _ in
                    // No fixture uses the legacy route; a request that reached it
                    // would be a wiring mistake, and this says so rather than
                    // quietly succeeding.
                    throw PS1SaveSyncError.localCardUnreadable
                },
                systemDirectory: systemDirectory,
                saveDirectory: FileManager.default.temporaryDirectory,
                saveStore: store),
            makePlayStation: { _ in playStation })
    }

    /// An invented title. `merged` produces the two-disc shape the classifier
    /// cannot distinguish from two separate products.
    private static func game(merged: Bool) -> PS1Game {
        let representative = Rom(id: canonicalRomID, name: "Fixture Game",
                                 fsName: "Fixture Game (USA) (Disc 1).cue",
                                 platformId: platformID, sizeBytes: nil, coverPath: nil,
                                 siblingRoms: [], regions: ["USA"],
                                 fsNameNoExt: "Fixture Game (USA) (Disc 1)")
        var discs = [PS1Disc(romID: canonicalRomID, fileStem: "Fixture Game (USA) (Disc 1)",
                             index: 1, label: "Disc 1")]
        if merged {
            discs.append(PS1Disc(romID: canonicalRomID + 1,
                                 fileStem: "Fixture Game (USA) (Disc 2)",
                                 index: 2, label: "Disc 2"))
        }
        return PS1Game(representative: representative, canonicalRomID: canonicalRomID,
                       discs: discs, excludedSiblings: [])
    }
}
#endif

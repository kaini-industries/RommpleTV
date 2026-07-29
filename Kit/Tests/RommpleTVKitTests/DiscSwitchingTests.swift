import XCTest
@testable import RommpleTVKit

/// Paused disc switching, tested away from a core.
///
/// Three rules are being pinned here, and every one of them is a way a player
/// ends up on a disc they did not choose:
///
/// - **The label list is the only authority for "this session has discs".**
///   `discCount > 0` does not mean PlayStation — Genesis Plus GX registers a
///   Disk Control interface too — so a launch whose `discLabels` is empty gets
///   no disc UI however many discs the core claims.
/// - **A label is never indexed against a count that disagrees with it.** If the
///   core and the package do not report the same number of discs, switching is
///   off: picking "Disc 2" out of a list the core does not share is how a player
///   is sent to disc 3.
/// - **What is displayed is what the drive answered**, success or failure. A
///   switch that failed mid-transaction and could not be fully undone leaves
///   *some* disc in the drive, and saying "Disc 2" while it holds disc 1 is
///   worse than saying nothing.
@MainActor
final class DiscSwitchingTests: XCTestCase {

    // MARK: - The drive

    /// A core's disc drive, with every answer chosen rather than provoked.
    @MainActor
    private final class FakeDrive {
        var hasDiskControl: Bool
        var discCount: Int
        var index: Int?
        var isPaused = true
        /// What `switchDisc` throws, or nil to let it succeed.
        var refusal: Error?
        /// Runs just before a refusal is thrown, so a test can leave the drive
        /// holding whatever a half-undone transaction would have left in it.
        var onRefusal: ((FakeDrive) -> Void)?
        private(set) var requested: [Int] = []

        init(hasDiskControl: Bool = true, discCount: Int = 2, index: Int? = 0) {
            self.hasDiskControl = hasDiskControl
            self.discCount = discCount
            self.index = index
        }

        func switchDisc(to index: Int) throws {
            requested.append(index)
            if let refusal {
                onRefusal?(self)
                throw refusal
            }
            self.index = index
        }

        var seams: DiscSwitchSeams {
            DiscSwitchSeams(hasDiskControl: { [self] in hasDiskControl },
                            discCount: { [self] in discCount },
                            currentIndex: { [self] in index },
                            isPaused: { [self] in isPaused },
                            switchDisc: { [self] in try switchDisc(to: $0) })
        }
    }

    private func makeFlow(_ drive: FakeDrive,
                          labels: [String] = ["Disc 1", "Disc 2"]) -> DiscSwitchFlow {
        DiscSwitchFlow(labels: labels, seams: drive.seams)
    }

    // MARK: - Which launches get disc UI at all

    /// The headline rule. A Sega CD game on Genesis Plus GX reports two discs
    /// through a real Disk Control interface and has an empty `discLabels`,
    /// because nothing prepared a disc set for it.
    func testALegacyLaunchGetsNoDiscUIHoweverManyDiscsTheCoreClaims() {
        let drive = FakeDrive(hasDiskControl: true, discCount: 2, index: 0)
        let flow = makeFlow(drive, labels: [])

        XCTAssertEqual(flow.availability, .single)
        XCTAssertFalse(flow.showsDiscSection,
                       "a legacy launch was offered disc UI because its core has a drive")
        XCTAssertFalse(flow.canSwitch)
        XCTAssertNil(flow.currentDiscLabel)
        XCTAssertNil(flow.note)
    }

    func testASingleDiscLaunchGetsNoDiscUI() {
        let drive = FakeDrive(hasDiskControl: true, discCount: 1, index: 0)
        let flow = makeFlow(drive, labels: ["Disc 1"])

        XCTAssertEqual(flow.availability, .single)
        XCTAssertFalse(flow.showsDiscSection)
        XCTAssertFalse(flow.canSwitch)
    }

    /// A prepared two-disc set on a core with no Disk Control at all. The button
    /// would be a broken action, so it is not offered — but the state is named,
    /// because a two-disc game that cannot reach disc 2 is worth explaining.
    func testAMultiDiscSetOnACoreWithNoDiskControlSaysSoInsteadOfOfferingABrokenButton() {
        let drive = FakeDrive(hasDiskControl: false, discCount: 0, index: nil)
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.availability, .unsupportedCore)
        XCTAssertTrue(flow.showsDiscSection)
        XCTAssertFalse(flow.canSwitch)
        XCTAssertNotNil(flow.note)
        // It must not name a disc: with no interface there is nothing to ask.
        XCTAssertNil(flow.currentDiscLabel)
    }

    /// The core and the package disagree. Switching is off rather than indexing
    /// one list by the other's numbering.
    func testACountMismatchDisablesSwitchingRatherThanIndexingTheWrongLabel() {
        for coreCount in [1, 3] {
            let drive = FakeDrive(hasDiskControl: true, discCount: coreCount, index: 0)
            let flow = makeFlow(drive, labels: ["Disc 1", "Disc 2"])

            XCTAssertEqual(flow.availability, .countMismatch(labels: 2, core: coreCount))
            XCTAssertTrue(flow.showsDiscSection, "core count \(coreCount)")
            XCTAssertFalse(flow.canSwitch, "core count \(coreCount)")
            XCTAssertNotNil(flow.note, "core count \(coreCount)")
            XCTAssertNil(flow.currentDiscLabel,
                         "a disc was named from a mapping that is known to be wrong")
        }
    }

    /// A mismatch is recoverable and says how: the package is rebuilt on the next
    /// launch, and the way to one is already on this overlay.
    /// The remedy has to be the one that can work, and it has to say what it
    /// means when it doesn't.
    ///
    /// "Quit and launch again" is right for a stale or half-installed package.
    /// It is useless for the other cause — a core whose `get_num_images()`
    /// simply disagrees with the playlist — because preparing again rebuilds the
    /// same playlist from the same manifest and produces the same two numbers.
    /// A note that stopped at the first clause would send a player round a loop
    /// that cannot terminate.
    func testTheMismatchStateSaysWhatToDoAboutItAndWhatItMeansIfThatChangesNothing() throws {
        let drive = FakeDrive(hasDiskControl: true, discCount: 3, index: 0)
        let flow = makeFlow(drive)

        let note = try XCTUnwrap(flow.note)
        XCTAssertTrue(note.contains("Quit"), note)
        XCTAssertTrue(note.contains("again"), note)
        XCTAssertTrue(note.contains("says the same thing again"),
                      "the note prescribes a remedy without saying what it means when the "
                          + "remedy changes nothing: \(note)")
        XCTAssertTrue(note.contains("can't be changed on this Apple TV"), note)
    }

    /// The unsupported note used to end at "you can keep playing this disc",
    /// which is a dead end — and a false one when the core simply had not
    /// registered its interface yet. Pausing again re-asks, so the note says so.
    func testTheUnsupportedNoteNamesTheRemedyThatNowExists() throws {
        let drive = FakeDrive(hasDiskControl: false, discCount: 0, index: nil)
        let flow = makeFlow(drive)

        let note = try XCTUnwrap(flow.note)
        XCTAssertTrue(note.contains("pause again"), note)
        XCTAssertTrue(note.lowercased().contains("keeps saying this"),
                      "the note offers a remedy without saying what it means when the remedy "
                          + "changes nothing: \(note)")
    }

    func testAgreeingCountsOfferTheSwitch() {
        let drive = FakeDrive(hasDiskControl: true, discCount: 2, index: 0)
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.availability, .available(["Disc 1", "Disc 2"]))
        XCTAssertTrue(flow.showsDiscSection)
        XCTAssertTrue(flow.canSwitch)
        XCTAssertNil(flow.note, "an offer that works does not need explaining")
        XCTAssertEqual(flow.currentDiscLabel, "Disc 1")
    }

    /// No message anywhere in this surface may carry a path or an address.
    func testNoDiscMessageNamesAFileOrAServer() {
        let states: [DiscSwitchAvailability] = [
            .single, .unsupportedCore, .countMismatch(labels: 2, core: 3),
            .available(["Disc 1", "Disc 2"])
        ]
        for state in states {
            guard let note = state.note else { continue }
            XCTAssertFalse(note.contains("/"), note)
            XCTAssertFalse(note.lowercased().contains("http"), note)
        }
    }

    // MARK: - Switching

    func testSwitchingAsksTheCoreForTheIndexThatWasChosenAndShowsWhatCameBack() {
        let drive = FakeDrive()
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.select(1), .switched)

        XCTAssertEqual(drive.requested, [1])
        XCTAssertEqual(flow.currentIndex, 1)
        XCTAssertEqual(flow.currentDiscLabel, "Disc 2")
        XCTAssertNil(flow.failure)
    }

    /// The disc already in the drive is not a transaction. Ejecting and
    /// reinserting the disc the player is on would be a real risk taken for no
    /// change at all.
    func testChoosingTheDiscAlreadyInTheDriveAsksTheCoreForNothing() {
        let drive = FakeDrive(index: 1)
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.select(1), .alreadyInserted)

        XCTAssertTrue(drive.requested.isEmpty, "the disc in the drive was ejected and reinserted")
        XCTAssertEqual(flow.currentIndex, 1)
    }

    /// The frames guard is about *this moment* rather than about the request, so
    /// it outranks the request being a no-op: a picker that should not be
    /// answering at all must not be told its choice already happened.
    func testAnUnpausedPickerIsRefusedEvenForTheDiscAlreadyInTheDrive() {
        let drive = FakeDrive(index: 1)
        drive.isPaused = false
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.select(1), .failed)

        XCTAssertTrue(drive.requested.isEmpty)
        XCTAssertEqual(flow.failure, DiscSwitchRefusal.framesRunning.localizedDescription)
    }

    /// The one rule the core cannot enforce for itself: `LibretroCore` is
    /// single-owner and a switch racing `runFrame()` is undefined behaviour in C,
    /// not a dropped frame.
    func testASwitchIsRefusedWhileFramesAreStillRunning() {
        let drive = FakeDrive()
        drive.isPaused = false
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.select(1), .failed)

        XCTAssertTrue(drive.requested.isEmpty, "a disc switch ran while the game was running")
        XCTAssertEqual(flow.currentIndex, 0, "the drive still holds the disc it held")
        XCTAssertNotNil(flow.failure)
    }

    /// A refusal is still an answer about the drive: the picker stays on screen
    /// with a "Current disc" line on it, and it may not go on showing whatever it
    /// was showing before.
    func testEvenARefusedSwitchRereadsTheDrive() {
        let drive = FakeDrive(hasDiskControl: true, discCount: 3, index: 0)
        drive.isPaused = false
        let flow = makeFlow(drive, labels: ["Disc 1", "Disc 2", "Disc 3"])
        XCTAssertEqual(flow.currentIndex, 0)

        // The drive moved under the open picker, and the refusal below is about
        // something else entirely.
        drive.index = 2
        XCTAssertEqual(flow.select(1), .failed)

        XCTAssertEqual(flow.currentIndex, 2,
                       "the picker went on showing a disc the drive no longer holds")
    }

    /// Switching is disabled in both recoverable states, and "disabled" has to
    /// mean the core is never asked — not merely that a button is hidden.
    func testAFlowThatCannotSwitchNeverAsksTheCore() {
        let cases: [(String, FakeDrive, [String])] = [
            ("legacy", FakeDrive(hasDiskControl: true, discCount: 2), []),
            ("single", FakeDrive(hasDiskControl: true, discCount: 1), ["Disc 1"]),
            ("unsupported", FakeDrive(hasDiskControl: false, discCount: 0), ["Disc 1", "Disc 2"]),
            ("mismatch", FakeDrive(hasDiskControl: true, discCount: 3), ["Disc 1", "Disc 2"]),
        ]
        for (name, drive, labels) in cases {
            let flow = makeFlow(drive, labels: labels)

            XCTAssertEqual(flow.select(1), .failed, name)

            XCTAssertTrue(drive.requested.isEmpty, "\(name) switched a disc it may not switch")
        }
    }

    func testADiscOutsideTheLabelListIsNeverAskedFor() {
        let drive = FakeDrive()
        let flow = makeFlow(drive)

        for index in [-1, 2, Int.max] {
            XCTAssertEqual(flow.select(index), .failed, "\(index)")
        }
        XCTAssertTrue(drive.requested.isEmpty, "a disc that is not in the list was asked for")
        XCTAssertEqual(flow.currentIndex, 0)
    }

    // MARK: - When a switch fails

    /// The transaction is eject → set index → insert, and a failure at any step
    /// leaves the drive holding whatever the best-effort restore managed. What is
    /// displayed is that, and never the index that was asked for.
    func testAFailedSwitchShowsTheDiscTheDriveActuallyHolds() {
        let drive = FakeDrive(index: 0)
        drive.refusal = CoreError.discSwitchFailed
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.select(1), .failed)

        XCTAssertEqual(drive.requested, [1])
        XCTAssertEqual(flow.currentIndex, 0, "the disc that was asked for was displayed as though "
                           + "it had been inserted")
        XCTAssertEqual(flow.currentDiscLabel, "Disc 1")
        XCTAssertNotNil(flow.failure)
    }

    /// The restore is best-effort: the core may refuse that too, and then the
    /// drive holds neither the old disc nor the new one. The re-query is what
    /// makes this survivable, so it has to happen on the failure path.
    func testAFailedSwitchWhoseRestoreAlsoFailedShowsWhereTheDriveActuallyEndedUp() {
        let drive = FakeDrive(hasDiskControl: true, discCount: 3, index: 0)
        drive.refusal = CoreError.discSwitchFailed
        // The tray opened, the index moved, and closing it again was refused —
        // so the restore put back neither the old disc nor the requested one.
        drive.onRefusal = { $0.index = 1 }
        let flow = makeFlow(drive, labels: ["Disc 1", "Disc 2", "Disc 3"])

        XCTAssertEqual(flow.select(2), .failed)

        XCTAssertEqual(flow.currentIndex, 1,
                       "the drive ended up on a disc that is neither the old one nor the new "
                           + "one, and the display did not follow it")
        XCTAssertEqual(flow.currentDiscLabel, "Disc 2")
    }

    /// An empty drive has no label, and inventing one is the failure this branch
    /// exists to avoid.
    func testADriveThatCannotSayWhatItHoldsSaysUnknown() {
        let drive = FakeDrive(index: 0)
        drive.refusal = CoreError.discSwitchFailed
        drive.onRefusal = { $0.index = nil }
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.select(1), .failed)

        XCTAssertNil(flow.currentIndex)
        XCTAssertNil(flow.currentDiscLabel)
        XCTAssertTrue(flow.currentDiscDescription.lowercased().contains("unknown"),
                      flow.currentDiscDescription)
    }

    /// The message a player reads is the core's own sentence, which is written
    /// for them and carries nothing about this device.
    func testTheFailureMessageIsReadableAndNamesNoPath() {
        let drive = FakeDrive()
        drive.refusal = CoreError.discSwitchFailed
        let flow = makeFlow(drive)

        XCTAssertEqual(flow.select(1), .failed)

        let message = flow.failure ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("/"), message)
        XCTAssertEqual(message, CoreError.discSwitchFailed.localizedDescription)
    }

    /// The picker stays open on a failure, so the next attempt must not open with
    /// the previous attempt's message still under it.
    func testASwitchThatLandsClearsTheMessageTheFailedOneLeft() {
        let drive = FakeDrive()
        drive.refusal = CoreError.discSwitchFailed
        let flow = makeFlow(drive)
        XCTAssertEqual(flow.select(1), .failed)
        XCTAssertNotNil(flow.failure)

        drive.refusal = nil
        XCTAssertEqual(flow.select(1), .switched)

        XCTAssertNil(flow.failure)
        XCTAssertEqual(flow.currentIndex, 1)
    }

    /// A disc that vanished from under the flow — the core unloaded while the
    /// picker was open — refuses rather than crashing on an index.
    func testAFlowWhoseCoreWentAwayRefusesAndSaysSo() {
        let drive = FakeDrive()
        let flow = makeFlow(drive)
        drive.refusal = DiscSwitchRefusal.noGameRunning

        XCTAssertEqual(flow.select(1), .failed)

        XCTAssertNotNil(flow.failure)
        XCTAssertEqual(flow.failure, DiscSwitchRefusal.noGameRunning.localizedDescription)
    }

    // MARK: - Asking the three questions again

    /// The worst hardware outcome this design can produce, and the thing that
    /// stops it being permanent.
    ///
    /// Availability is settled right after `retro_load_game`, on the assumption
    /// that a core registers Disk Control during load. Nobody can rule out a core
    /// that registers on its first `retro_run` instead — and with one resolve at
    /// construction, that assumption failing would hide the button, leave no
    /// picker to open, and never look again: a two-disc game stuck on disc 1 for
    /// the life of the install.
    func testAnInterfaceThatRegistersLateIsPickedUpOnTheNextPause() {
        let drive = FakeDrive(hasDiskControl: false, discCount: 0, index: nil)
        let flow = makeFlow(drive)
        XCTAssertEqual(flow.availability, .unsupportedCore)
        XCTAssertFalse(flow.canSwitch)

        // The core got as far as its first frames and registered.
        drive.hasDiskControl = true
        drive.discCount = 2
        drive.index = 0
        flow.reresolve()

        XCTAssertEqual(flow.availability, .available(["Disc 1", "Disc 2"]))
        XCTAssertTrue(flow.canSwitch, "a late registration stayed invisible for the session")
        XCTAssertEqual(flow.currentDiscLabel, "Disc 1")
        XCTAssertNil(flow.note)
        // And it is a working offer, not just a visible one.
        XCTAssertEqual(flow.select(1), .switched)
        XCTAssertEqual(drive.requested, [1])
    }

    /// Re-resolving may not become a back door into the one rule this whole file
    /// exists for. A Sega CD launch on Genesis Plus GX has a real interface and a
    /// real disc count at every moment, including this one.
    func testReresolvingCannotPromoteALegacyLaunch() {
        let drive = FakeDrive(hasDiskControl: false, discCount: 0, index: nil)
        let flow = makeFlow(drive, labels: [])

        drive.hasDiskControl = true
        drive.discCount = 2
        drive.index = 0
        flow.reresolve()

        XCTAssertEqual(flow.availability, .single)
        XCTAssertFalse(flow.showsDiscSection)
        XCTAssertEqual(flow.select(1), .failed)
        XCTAssertTrue(drive.requested.isEmpty)
    }

    /// Not a one-way upgrade: the three conditions are applied to whatever is
    /// true now. A core that has stopped answering is not a session that should
    /// still be offering a switch.
    func testReresolvingFollowsTheCoreDownwardsToo() {
        let drive = FakeDrive(hasDiskControl: true, discCount: 2, index: 0)
        let flow = makeFlow(drive)
        XCTAssertTrue(flow.canSwitch)

        drive.hasDiskControl = false
        drive.discCount = 0
        drive.index = nil
        flow.reresolve()

        XCTAssertEqual(flow.availability, .unsupportedCore)
        XCTAssertFalse(flow.canSwitch)
        XCTAssertNil(flow.currentDiscLabel)
    }

    /// A failure belongs to the pause it happened in. The next pause opens a
    /// picker that must not have last time's message under it.
    func testReresolvingClearsAMessageFromAnEarlierPause() {
        let drive = FakeDrive()
        drive.refusal = CoreError.discSwitchFailed
        let flow = makeFlow(drive)
        XCTAssertEqual(flow.select(1), .failed)
        XCTAssertNotNil(flow.failure)

        flow.reresolve()

        XCTAssertNil(flow.failure)
    }

    // MARK: - Re-reading the drive

    func testRefreshTakesTheDrivesCurrentAnswer() {
        let drive = FakeDrive(index: 0)
        let flow = makeFlow(drive)
        XCTAssertEqual(flow.currentIndex, 0)

        drive.index = 1
        flow.refresh()

        XCTAssertEqual(flow.currentIndex, 1)
        XCTAssertEqual(flow.currentDiscLabel, "Disc 2")
    }

    // MARK: - The refusals

    func testEveryRefusalSaysSomethingAPlayerCanRead() {
        let refusals: [DiscSwitchRefusal] = [.framesRunning, .noGameRunning, .switchingUnavailable,
                                             .noSuchDisc]
        var messages = Set<String>()
        for refusal in refusals {
            let message = refusal.localizedDescription
            XCTAssertFalse(message.isEmpty, "\(refusal)")
            XCTAssertFalse(message.contains("/"), message)
            messages.insert(message)
        }
        XCTAssertEqual(messages.count, refusals.count,
                       "two refusals say the same thing, so at least one of them is wrong")
    }
}

// MARK: - The save-sync surface

/// What the pause overlay says about the server half of a PlayStation save.
@MainActor
final class SaveSyncStatusDisplayTests: XCTestCase {

    /// Exhaustive over the vocabulary rather than over the handful of statuses
    /// that happen to be interesting, so a status added to the enum cannot reach
    /// the overlay with nothing to say.
    func testEveryStatusExceptIdleSaysSomething() {
        for status in PS1SaveSyncStatus.allCases {
            if status == .idle {
                XCTAssertNil(status.overlayMessage, "idle put a message on screen")
            } else {
                let message = status.overlayMessage ?? ""
                XCTAssertFalse(message.isEmpty, "\(status) has nothing to say")
            }
        }
    }

    func testTheMessagesAreDistinctAndNameNoServer() {
        let messages = PS1SaveSyncStatus.allCases.compactMap(\.overlayMessage)
        XCTAssertEqual(Set(messages).count, messages.count,
                       "two sync states read the same, so at least one of them is wrong")
        for message in messages {
            XCTAssertFalse(message.contains("/"), message)
            XCTAssertFalse(message.lowercased().contains("http"), message)
        }
    }

    /// Only a failure offers a retry. A retry on `.syncing` would ask for a second
    /// upload of the one already in flight, and on `.conflict` it would choose a
    /// side on the player's behalf.
    func testOnlyAFailureOffersARetry() {
        for status in PS1SaveSyncStatus.allCases {
            XCTAssertEqual(status.offersSyncRetry, status == .failed, "\(status)")
        }
    }

    /// A conflict is not an error and not a dead end: it is resolved by the
    /// chooser that runs before this game launches next time, and the message has
    /// to say so or a player is left wondering what to do from here.
    func testTheConflictMessageSaysWhenItGetsResolved() {
        let message = PS1SaveSyncStatus.conflict.overlayMessage ?? ""
        XCTAssertTrue(message.lowercased().contains("next time")
                        || message.lowercased().contains("next launch"),
                      message)
    }
}

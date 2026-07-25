import Combine
import XCTest
@testable import RommpleTVKit

/// The ordering rule the emulator's save path rests on, tested away from an
/// emulator.
///
/// Two things are being pinned here and neither is cosmetic:
///
/// - **The local write happens first, and the remote schedule happens only if it
///   succeeded.** `PS1SaveCoordinator.scheduleUpload` takes the bytes it is
///   handed at their word and prefers them over the stored card until the upload
///   settles, so bytes that never reached the local file would be uploaded, clear
///   the pending flag, and record a baseline the local card does not match —
///   after which the next reconciliation reads "local changed, remote did not"
///   and uploads the *older* card over the newer remote one.
/// - **A failed write is returned to the caller**, so gameplay stays paused and a
///   Quit does not dismiss on top of a card that was never written.
@MainActor
final class EmulatorSaveFlowTests: XCTestCase {

    /// What crossed each seam, in the order it crossed. The event log is the
    /// whole point: an assertion that both closures ran says nothing about which
    /// ran first.
    private final class Recorder {
        var events: [String] = []
        var requests: [EmulatorRemoteSaveRequest] = []
    }

    private let card = Data("card-bytes".utf8)

    private func makeFlow(_ recorder: Recorder,
                          write: @escaping @MainActor () throws -> Data?) -> EmulatorSaveFlow {
        EmulatorSaveFlow(
            localFlush: {
                recorder.events.append("local")
                return try write()
            },
            scheduleRemote: { request in
                recorder.events.append("remote")
                recorder.requests.append(request)
            })
    }

    /// A store that refuses until it is healed, which is what a Retry Save has to
    /// be tested against.
    private struct WriteRefused: Error {
        /// Deliberately something a message must never repeat: a real store's
        /// error carries a filesystem path.
        let path = "/private/var/mobile/Containers/Data/Application/secret/saves/7.srm"
    }

    // MARK: The tick

    func testTheTickWritesLocallyBeforeItSchedulesAnythingRemote() {
        let recorder = Recorder()
        let flow = makeFlow(recorder) { self.card }

        XCTAssertEqual(flow.flush(.periodic), .saved)

        XCTAssertEqual(recorder.events, ["local", "remote"],
                       "the upload was scheduled before the card was on disk")
        XCTAssertEqual(recorder.requests.map(\.bytes), [card])
    }

    /// The periodic tick hands the bytes over and asks for nothing to be hurried:
    /// the coordinator's own debounce is the right amount of waiting for a card
    /// that is still being played.
    func testTheTickLeavesTheTimingToTheDebounce() {
        let recorder = Recorder()
        let flow = makeFlow(recorder) { self.card }

        XCTAssertEqual(flow.flush(.periodic), .saved)

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(recorder.requests[0].retry,
                     "a periodic flush must not bypass the upload debounce")
    }

    func testAnUnchangedCardOnTheTickAsksForNothingAtAll() {
        let recorder = Recorder()
        let flow = makeFlow(recorder) { nil }

        XCTAssertEqual(flow.flush(.periodic), .saved)

        XCTAssertEqual(recorder.events, ["local"],
                       "an unchanged card produced an upload request")
    }

    // MARK: The reasons that cannot wait

    func testPauseQuitBackgroundAndUserBypassTheDebounce() {
        let expected: [(EmulatorSaveTrigger, RetryReason)] = [
            (.pause, .pause), (.quit, .quit), (.background, .background), (.user, .user)
        ]
        for (trigger, reason) in expected {
            let recorder = Recorder()
            let flow = makeFlow(recorder) { self.card }

            XCTAssertEqual(flow.flush(trigger), .saved)

            XCTAssertEqual(recorder.events, ["local", "remote"], "\(trigger)")
            XCTAssertEqual(recorder.requests.map(\.bytes), [card], "\(trigger)")
            XCTAssertEqual(recorder.requests.map(\.retry), [reason],
                           "\(trigger) did not ask for an immediate sync")
        }
    }

    /// Quitting with a card that has not changed since the last write still has to
    /// send what is owed: a previous upload may have failed while the bytes on
    /// disk stayed exactly as they are.
    func testQuittingWithAnUnchangedCardStillSendsWhatIsOwed() {
        let recorder = Recorder()
        let flow = makeFlow(recorder) { nil }

        XCTAssertEqual(flow.flush(.quit), .saved)

        XCTAssertEqual(recorder.events, ["local", "remote"])
        XCTAssertNil(recorder.requests[0].bytes, "there were no new bytes to hand over")
        XCTAssertEqual(recorder.requests[0].retry, .quit)
    }

    // MARK: A failed local write

    func testAFailedLocalWriteSchedulesNothingRemote() {
        for trigger in EmulatorSaveTrigger.allCases {
            let recorder = Recorder()
            let flow = makeFlow(recorder) { throw WriteRefused() }

            XCTAssertEqual(flow.flush(trigger), .failed(.localWriteFailed), "\(trigger)")

            XCTAssertEqual(recorder.events, ["local"],
                           "\(trigger) uploaded a card that never reached the local store")
            XCTAssertTrue(recorder.requests.isEmpty, "\(trigger)")
        }
    }

    func testAFailedLocalWritePublishesAMessageAndReturnsTheFailure() {
        let recorder = Recorder()
        let flow = makeFlow(recorder) { throw WriteRefused() }
        XCTAssertNil(flow.failure)

        XCTAssertEqual(flow.flush(.periodic), .failed(.localWriteFailed))

        XCTAssertEqual(flow.failure, .localWriteFailed)
    }

    /// The published message is a constant, not a rendering of whatever the store
    /// threw. A store's error carries a container path.
    func testThePublishedMessageNeverRepeatsTheUnderlyingError() {
        let recorder = Recorder()
        let thrown = WriteRefused()
        let flow = makeFlow(recorder) { throw thrown }
        _ = flow.flush(.periodic)

        guard let failure = flow.failure else { return XCTFail("nothing was published") }
        XCTAssertFalse(failure.message.contains(thrown.path), failure.message)
        XCTAssertFalse(failure.recovery.contains(thrown.path), failure.recovery)
        XCTAssertFalse(failure.message.contains("/"), failure.message)
    }

    /// The signal the Quit button reads. A dismissal on top of a card that was
    /// never written is the loss this whole path exists to prevent.
    func testAFailedQuitFlushBlocksTheDismissal() {
        let recorder = Recorder()
        let flow = makeFlow(recorder) { throw WriteRefused() }

        let outcome = flow.flush(.quit)

        XCTAssertNotEqual(outcome, .saved, "a failed Quit reported that it was safe to leave")
        XCTAssertEqual(outcome, .failed(.localWriteFailed))
        XCTAssertEqual(flow.failure, .localWriteFailed,
                       "the reason the player cannot leave is not on screen")
    }

    // MARK: Clearing the message

    func testTheMessageSurvivesAFurtherFailureAndClearsOnlyOnALaterLocalSuccess() {
        let recorder = Recorder()
        var refuse = true
        let flow = makeFlow(recorder) {
            if refuse { throw WriteRefused() }
            return self.card
        }

        XCTAssertEqual(flow.flush(.periodic), .failed(.localWriteFailed))
        XCTAssertEqual(flow.flush(.user), .failed(.localWriteFailed))
        XCTAssertEqual(flow.failure, .localWriteFailed,
                       "a second failure cleared the first one's message")
        XCTAssertTrue(recorder.requests.isEmpty)

        refuse = false
        XCTAssertEqual(flow.flush(.user), .saved)
        XCTAssertNil(flow.failure, "Retry Save left the message up after it worked")
        XCTAssertEqual(recorder.requests.map(\.retry), [.user])
    }

    /// A local success clears the message and nothing else does — including not
    /// for the instant a further failing flush is running. Stated over what was
    /// *published* rather than over the value left behind, because "cleared and
    /// immediately set again" leaves the same value behind.
    func testAFailingFlushNeverClearsTheMessageEvenMomentarily() {
        let recorder = Recorder()
        let flow = makeFlow(recorder) { throw WriteRefused() }
        XCTAssertEqual(flow.flush(.periodic), .failed(.localWriteFailed))

        var published: [EmulatorSaveFailure?] = []
        let subscription = flow.$failure.sink { published.append($0) }
        XCTAssertEqual(flow.flush(.user), .failed(.localWriteFailed))
        subscription.cancel()

        XCTAssertFalse(published.contains { $0 == nil },
                       "the message blinked off during a flush that failed: \(published)")
    }

    /// A card that has not changed since the last *successful* write is a card
    /// that is on disk, so the message goes.
    func testASuccessWithNothingToWriteAlsoClearsTheMessage() {
        let recorder = Recorder()
        var written: Data? = nil
        var refuse = true
        let flow = makeFlow(recorder) {
            if refuse { throw WriteRefused() }
            return written
        }
        XCTAssertEqual(flow.flush(.periodic), .failed(.localWriteFailed))

        refuse = false
        written = nil
        XCTAssertEqual(flow.flush(.user), .saved)
        XCTAssertNil(flow.failure)
    }

    // MARK: The note a session leaves behind

    /// Backing out with Menu dismisses the view before the engine's last flush
    /// runs, so a failure there has nowhere to be shown. The note is what makes
    /// the next session able to say so.
    func testTheNoteIsPerGameAndSurvivesUntilAWriteLands() throws {
        let suite = "UnwrittenCardNoteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(UnwrittenCardNote.exists(romID: 7, defaults: defaults))

        UnwrittenCardNote.record(romID: 7, defaults: defaults)
        XCTAssertTrue(UnwrittenCardNote.exists(romID: 7, defaults: defaults))
        XCTAssertFalse(UnwrittenCardNote.exists(romID: 8, defaults: defaults),
                       "one game's failed write was reported against another game")

        // Reading it does not consume it: the player may not pause this session
        // either, and the card is still unwritten until something writes it.
        XCTAssertTrue(UnwrittenCardNote.exists(romID: 7, defaults: defaults))

        UnwrittenCardNote.clear(romID: 7, defaults: defaults)
        XCTAssertFalse(UnwrittenCardNote.exists(romID: 7, defaults: defaults))
        // Idempotent, because it is called after every successful flush.
        UnwrittenCardNote.clear(romID: 7, defaults: defaults)
        XCTAssertFalse(UnwrittenCardNote.exists(romID: 7, defaults: defaults))
    }

    /// The two messages are not interchangeable: one is about progress the player
    /// still has, the other about a session that is over.
    ///
    /// The note's message may not claim to be about the *previous* session. It is
    /// retired by being shown and by nothing else, so a failure in session 1 that
    /// the player never opened an overlay to see is still waiting in session 4
    /// with sessions 2 and 3 having ended cleanly in between. "An earlier
    /// session" is true of every sequence that can reach it; "the last time you
    /// played" is false of that one.
    func testTheTwoSaveMessagesSayDifferentThings() {
        XCTAssertNotEqual(EmulatorSaveFailure.localWriteFailed,
                          EmulatorSaveFailure.lastSessionUnwritten)
        XCTAssertTrue(EmulatorSaveFailure.lastSessionUnwritten.message.contains("earlier session"),
                      EmulatorSaveFailure.lastSessionUnwritten.message)
        XCTAssertFalse(EmulatorSaveFailure.lastSessionUnwritten.message.contains("last time"),
                       "the note claims to be about the previous session, and it is not: "
                           + "nothing retires it but being shown")
        for failure in [EmulatorSaveFailure.localWriteFailed, .lastSessionUnwritten] {
            XCTAssertTrue(failure.recovery.contains("Retry Save"), failure.recovery)
            XCTAssertFalse(failure.message.contains("/"), failure.message)
        }
    }

    // MARK: The trigger table

    /// Every trigger except the tick asks for an immediate sync, and the tick
    /// asks for none. Stated once, over all the cases, so a new trigger cannot be
    /// added without deciding this.
    func testEveryTriggerExceptTheTickBypassesTheDebounce() {
        for trigger in EmulatorSaveTrigger.allCases {
            if trigger == .periodic {
                XCTAssertNil(trigger.retryReason)
            } else {
                XCTAssertNotNil(trigger.retryReason, "\(trigger) would wait out the debounce")
            }
        }
    }
}

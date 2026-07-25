import XCTest
@testable import RommpleTVKit

// MARK: - Test double

/// Deterministic stand-in for `LibraryPageModel.Fetch`.
///
/// Every call is recorded in arrival order and answered one of two ways: from a
/// canned responder, or not at all until the test explicitly resumes it by
/// index. Explicit resumption — never elapsed time, task priority, or sleeps —
/// is what lets these tests complete a newer request before an older one and
/// cancel one chosen in-flight request while another is still running.
private actor FetchDriver {
    struct Request: Equatable, Sendable {
        let limit: Int
        let offset: Int
        let sort: RomSort
    }

    /// Answers a request immediately from its arrival index. `nil` instead
    /// suspends every new request until the test resumes it.
    typealias Responder = @Sendable (Request, Int) throws -> RomPage

    private struct Waiter {
        let id: UUID
        let requiredCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var responder: Responder?
    private var recorded: [Request] = []
    private var suspended: [Int: CheckedContinuation<RomPage, Error>] = [:]
    private var cancelledIndices: Set<Int> = []
    private var waiters: [Waiter] = []

    init(responder: Responder? = nil) { self.responder = responder }

    var requests: [Request] { recorded }
    var requestCount: Int { recorded.count }

    /// Switches modes mid-test. Passing `nil` suspends every subsequent request.
    func setResponder(_ responder: Responder?) { self.responder = responder }

    nonisolated func fetch() -> LibraryPageModel.Fetch {
        { limit, offset, sort in
            try await self.answer(Request(limit: limit, offset: offset, sort: sort))
        }
    }

    /// Suspends until at least `count` requests have arrived, so a test can be
    /// certain a request exists before it answers or cancels it.
    ///
    /// `timeout` is a hang guard only: it fails the test rather than wedging the
    /// whole suite if the model never issues the request. No assertion in this
    /// file depends on how much time passes.
    func waitUntilRequestCount(
        _ count: Int, timeout: Duration = .seconds(5),
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        if recorded.count >= count { return }
        let id = UUID()
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            await self.abandonWaiter(id, expected: count, file: file, line: line)
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, requiredCount: count, continuation: continuation))
        }
        watchdog.cancel()
    }

    func resume(_ index: Int, with page: RomPage,
                file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = suspended.removeValue(forKey: index) else {
            return XCTFail("no suspended request at index \(index)", file: file, line: line)
        }
        continuation.resume(returning: page)
    }

    func resume(_ index: Int, throwing error: Error,
                file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = suspended.removeValue(forKey: index) else {
            return XCTFail("no suspended request at index \(index)", file: file, line: line)
        }
        continuation.resume(throwing: error)
    }

    private func answer(_ request: Request) async throws -> RomPage {
        let index = recorded.count
        recorded.append(request)
        releaseSatisfiedWaiters()
        if let responder { return try responder(request, index) }
        return try await withTaskCancellationHandler {
            try await suspendRequest(index)
        } onCancel: {
            Task { await self.cancelRequest(index) }
        }
    }

    private func suspendRequest(_ index: Int) async throws -> RomPage {
        try await withCheckedThrowingContinuation { continuation in
            // The cancellation handler can land before the continuation is
            // stored; both run on this actor, so checking the set here closes
            // that window instead of leaving the request suspended forever.
            if cancelledIndices.contains(index) {
                continuation.resume(throwing: CancellationError())
            } else {
                suspended[index] = continuation
            }
        }
    }

    private func cancelRequest(_ index: Int) {
        cancelledIndices.insert(index)
        suspended.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }

    private func releaseSatisfiedWaiters() {
        let satisfied = waiters.filter { $0.requiredCount <= recorded.count }
        waiters.removeAll { $0.requiredCount <= recorded.count }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func abandonWaiter(_ id: UUID, expected: Int, file: StaticString, line: UInt) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        XCTFail("timed out waiting for \(expected) fetch requests; saw \(recorded.count)",
                file: file, line: line)
        waiter.continuation.resume()
    }
}

// MARK: - Synthetic fixtures

private let fixturePlatformID = 7

/// `count` synthetic roms numbered from `firstID`. Nothing here comes from a
/// real library.
private func fixtureRoms(_ count: Int, firstID: Int) -> [Rom] {
    (0..<count).map {
        Rom(id: firstID + $0, name: "Fixture Game \(firstID + $0)",
            fsName: "fixture-\(firstID + $0).zip", platformId: fixturePlatformID,
            sizeBytes: 4096, coverPath: nil)
    }
}

/// Emulates an envelope server holding `total` roms: ids run `1...total`, so the
/// ids on a page identify the offset it was sliced from.
private func envelopePage(_ request: FetchDriver.Request, total: Int) -> RomPage {
    RomPage(items: fixtureRoms(max(0, min(request.limit, total - request.offset)),
                               firstID: request.offset + 1),
            total: total, limit: request.limit, offset: request.offset)
}

/// Emulates a server that answered with a bare JSON array: same slicing, no total.
private func bareArrayPage(_ request: FetchDriver.Request, total: Int) -> RomPage {
    RomPage(items: fixtureRoms(max(0, min(request.limit, total - request.offset)),
                               firstID: request.offset + 1),
            total: nil, limit: request.limit, offset: request.offset)
}

// MARK: - Tests

@MainActor
final class LibraryPagingTests: XCTestCase {

    /// A private defaults suite per test — never `.standard` — removed on
    /// teardown so no test can observe another test's persisted preferences.
    private func isolatedDefaults(
        named suiteName: String = "LibraryPagingTests.\(UUID().uuidString)"
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeModel(_ driver: FetchDriver, platformID: Int = fixturePlatformID,
                           defaults: UserDefaults? = nil) -> LibraryPageModel {
        LibraryPageModel(platformID: platformID,
                         defaults: defaults ?? isolatedDefaults(),
                         fetch: driver.fetch())
    }

    /// Loads page 1 through a gated driver and answers it, leaving the driver
    /// gated so the test controls every request that follows.
    private func primeFirstPage(_ model: LibraryPageModel, _ driver: FetchDriver,
                                total: Int = 200) async {
        let initial = Task { await model.loadCurrentPage() }
        await driver.waitUntilRequestCount(1)
        await driver.resume(0, with: RomPage(items: fixtureRoms(48, firstID: 1),
                                             total: total, limit: 48, offset: 0))
        await initial.value
    }

    // MARK: Paging arithmetic

    func testInitialLoadFetchesOnlyOneDefaultPage() async {
        let driver = FetchDriver { request, _ in envelopePage(request, total: 200) }
        let model = makeModel(driver)

        await model.loadCurrentPage()

        let requests = await driver.requests
        XCTAssertEqual(requests, [FetchDriver.Request(limit: 48, offset: 0, sort: .titleAscending)],
                       "entering a platform must fetch page 1 only")
        XCTAssertEqual(model.items.map(\.id), Array(1...48))
        XCTAssertEqual(model.pageSize, 48)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.total, 200)
        XCTAssertEqual(model.pageCount, 5)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorText)
    }

    func testNextAndPreviousUseServerOffsets() async {
        let driver = FetchDriver { request, _ in envelopePage(request, total: 200) }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        await model.goNext()
        XCTAssertEqual(model.pageNumber, 2)
        XCTAssertEqual(model.items.map(\.id), Array(49...96))
        await model.goNext()
        XCTAssertEqual(model.pageNumber, 3)
        await model.goPrevious()
        XCTAssertEqual(model.pageNumber, 2)
        XCTAssertEqual(model.items.map(\.id), Array(49...96))

        let requests = await driver.requests
        XCTAssertEqual(requests.map(\.offset), [0, 48, 96, 48],
                       "each move must ask the server for that page, not slice a cached library")
        XCTAssertEqual(requests.map(\.limit), [48, 48, 48, 48])
    }

    func testLastPageUsesServerTotal() async {
        let driver = FetchDriver { request, _ in envelopePage(request, total: 100) }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        XCTAssertEqual(model.pageCount, 3)
        XCTAssertTrue(model.canGoLast)

        await model.goLast()

        let requests = await driver.requests
        XCTAssertEqual(requests.last?.offset, 96, "Last is server-backed: offset = (pages - 1) * size")
        XCTAssertEqual(model.pageNumber, 3)
        XCTAssertEqual(model.items.map(\.id), Array(97...100))
        XCTAssertFalse(model.canGoNext)
        XCTAssertFalse(model.canGoLast)
        XCTAssertTrue(model.canGoFirst)
        XCTAssertTrue(model.canGoPrevious)

        await model.goFirst()
        let afterFirst = await driver.requests
        XCTAssertEqual(afterFirst.last?.offset, 0)
        XCTAssertEqual(model.pageNumber, 1)
    }

    func testChangingSortReturnsToFirstPage() async {
        let driver = FetchDriver { request, _ in envelopePage(request, total: 200) }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        await model.goNext()
        await model.goNext()
        XCTAssertEqual(model.pageNumber, 3)

        await model.selectSort(.sizeLargest)

        let requests = await driver.requests
        XCTAssertEqual(requests.last?.offset, 0, "a new sort must restart at page 1")
        XCTAssertEqual(requests.last?.sort, .sizeLargest)
        XCTAssertEqual(model.sort, .sizeLargest)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.items.map(\.id), Array(1...48))
    }

    func testEmptyTotalHasSinglePageAndNoNavigation() async {
        let driver = FetchDriver { request, _ in envelopePage(request, total: 0) }
        let model = makeModel(driver)

        await model.loadCurrentPage()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.total, 0)
        XCTAssertEqual(model.pageCount, 1, "an empty library is one empty page, not zero pages")
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertFalse(model.canGoFirst)
        XCTAssertFalse(model.canGoPrevious)
        XCTAssertFalse(model.canGoNext)
        XCTAssertFalse(model.canGoLast)
        XCTAssertNil(model.errorText)
    }

    func testChangingPageSizeReturnsToFirstPage() async {
        let driver = FetchDriver { request, _ in envelopePage(request, total: 200) }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        await model.goNext()
        XCTAssertEqual(model.pageNumber, 2)

        await model.selectPageSize(24)

        let requests = await driver.requests
        XCTAssertEqual(requests.last?.limit, 24)
        XCTAssertEqual(requests.last?.offset, 0, "a new page size must restart at page 1")
        XCTAssertEqual(model.pageSize, 24)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.pageCount, 9)
        XCTAssertEqual(model.items.map(\.id), Array(1...24))

        await model.selectPageSize(96)
        XCTAssertEqual(model.pageSize, 96)
        XCTAssertEqual(model.pageCount, 3)

        let countBeforeUnsupported = await driver.requestCount
        await model.selectPageSize(37)
        let countAfterUnsupported = await driver.requestCount
        XCTAssertEqual(countAfterUnsupported, countBeforeUnsupported,
                       "a size outside 24/48/96 must not reach the server")
        XCTAssertEqual(model.pageSize, 96)
    }

    func testUnknownPersistedPreferencesFallBackToDefaults() async {
        let defaults = isolatedDefaults()
        defaults.set(96, forKey: "library.pageSize")
        defaults.set(RomSort.sizeSmallest.rawValue, forKey: "library.sort.\(fixturePlatformID)")

        let restored = makeModel(FetchDriver(), defaults: defaults)
        XCTAssertEqual(restored.pageSize, 96, "a supported persisted page size must be restored")
        XCTAssertEqual(restored.sort, .sizeSmallest, "a known persisted sort must be restored")

        defaults.set(37, forKey: "library.pageSize")
        defaults.set("byVibes", forKey: "library.sort.\(fixturePlatformID)")

        let coerced = makeModel(FetchDriver(), defaults: defaults)
        XCTAssertEqual(coerced.pageSize, 48, "an unsupported persisted page size must become 48")
        XCTAssertEqual(coerced.sort, .titleAscending, "an unknown persisted sort must become the default")
    }

    // MARK: Failure handling

    func testFailedPageKeepsVisibleItemsAndOffersRetry() async {
        let driver = FetchDriver { request, index in
            if index == 1 { throw RommError.http(503) }
            return envelopePage(request, total: 200)
        }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        await model.goNext()

        XCTAssertEqual(model.items.map(\.id), Array(1...48), "a failed page must not blank the grid")
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.total, 200)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.errorText, "a failed page must offer Retry")

        await model.retry()

        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.pageNumber, 2)
        XCTAssertEqual(model.items.map(\.id), Array(49...96))
    }

    func testRetryReissuesFailedTargetRatherThanVisiblePage() async {
        let driver = FetchDriver { request, index in
            if index == 1 || index == 3 { throw RommError.http(500) }
            return envelopePage(request, total: 200)
        }
        let model = makeModel(driver)

        await model.loadCurrentPage()   // 0: page 1 visible
        await model.goLast()            // 1: page 5 fails; page 1 stays visible
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertNotNil(model.errorText)

        await model.retry()             // 2: reissues page 5, not visible page 1
        XCTAssertEqual(model.pageNumber, 5)
        XCTAssertNil(model.errorText)

        await model.goFirst()           // 3: page 1 fails; page 5 stays visible
        XCTAssertEqual(model.pageNumber, 5)
        XCTAssertNotNil(model.errorText)

        await model.goPrevious()        // 4: page 4 succeeds, so the failure is obsolete
        XCTAssertEqual(model.pageNumber, 4)
        XCTAssertNil(model.errorText)

        await model.retry()             // 5: nothing failed, so it refreshes page 4

        let requests = await driver.requests
        XCTAssertEqual(requests.map(\.offset), [0, 192, 192, 0, 144, 144],
                       "retry reissues the failed target; a newer move clears an obsolete one")
    }

    func testNoOpSortOrSizeSelectionClearsAnObsoleteFailure() async {
        let driver = FetchDriver { request, index in
            if index == 1 || index == 3 { throw RommError.http(500) }
            return envelopePage(request, total: 200)
        }
        let model = makeModel(driver)

        await model.loadCurrentPage()               // 0: page 1, titleAscending, size 48
        await model.selectSort(.sizeLargest)        // 1: fails, so `sort` stays titleAscending
        XCTAssertEqual(model.sort, .titleAscending)
        XCTAssertNotNil(model.errorText)

        // The sort menu binds to the committed sort, so it still reads
        // titleAscending: re-picking it is how the user backs out of the failure.
        await model.selectSort(.titleAscending)
        XCTAssertNil(model.errorText, "backing out of a failed sort must disarm its Retry")

        await model.retry()                         // 2: the visible page, not sizeLargest
        let afterSortRetry = await driver.requests
        XCTAssertEqual(afterSortRetry.last?.sort, .titleAscending,
                       "Retry must not switch to a sort the user backed away from")
        XCTAssertEqual(model.sort, .titleAscending)

        await model.selectPageSize(96)              // 3: fails, so `pageSize` stays 48
        XCTAssertEqual(model.pageSize, 48)
        XCTAssertNotNil(model.errorText)

        await model.selectPageSize(48)              // the size already in use: a no-op action
        XCTAssertNil(model.errorText, "backing out of a failed page size must disarm its Retry too")
        await model.selectPageSize(37)              // a refused size is still a size action

        await model.retry()                         // 4: the visible page at size 48
        let requests = await driver.requests
        XCTAssertEqual(requests.map(\.limit), [48, 48, 48, 96, 48],
                       "Retry must not reissue a page size the user backed away from")
        XCTAssertEqual(model.pageSize, 48)
        XCTAssertEqual(model.pageNumber, 1)
    }

    func testFailureOfTheVisiblePageSurvivesANoOpSelection() async {
        let driver = FetchDriver { request, index in
            if index == 1 { throw RommError.http(500) }
            return envelopePage(request, total: 200)
        }
        let model = makeModel(driver)

        await model.loadCurrentPage()               // 0: page 1 visible
        await model.loadCurrentPage()               // 1: a refresh of that same page fails
        XCTAssertNotNil(model.errorText)

        await model.selectSort(.titleAscending)     // a no-op, but nothing here is obsolete
        XCTAssertNotNil(model.errorText,
                        "a failure whose target is the visible page is still worth retrying")

        await model.retry()                         // 2
        let requests = await driver.requests
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0])
        XCTAssertNil(model.errorText)
    }

    // MARK: Out-of-order completion

    func testLateResponseCannotReplaceNewerRequest() async {
        let driver = FetchDriver()   // every request suspends until this test answers it
        let model = makeModel(driver)
        await primeFirstPage(model, driver)
        XCTAssertEqual(model.items.map(\.id), Array(1...48))

        // Older request: page 2 under the original sort.
        let older = Task { await model.goNext() }
        await driver.waitUntilRequestCount(2)
        // Newer request: a re-sort, which restarts at page 1.
        let newer = Task { await model.selectSort(.sizeLargest) }
        await driver.waitUntilRequestCount(3)

        // Complete the newer request first...
        await driver.resume(2, with: RomPage(items: fixtureRoms(48, firstID: 5001),
                                             total: 200, limit: 48, offset: 0))
        await newer.value
        XCTAssertEqual(model.items.map(\.id), Array(5001...5048))

        // ...then let the older one land late.
        await driver.resume(1, with: RomPage(items: fixtureRoms(48, firstID: 9001),
                                             total: 200, limit: 48, offset: 48))
        await older.value

        XCTAssertEqual(model.items.map(\.id), Array(5001...5048),
                       "a late response from an older request must never become visible")
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.sort, .sizeLargest)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorText)
    }

    func testCurrentCancellationPublishesNoErrorAndClearsLoading() async {
        let driver = FetchDriver()
        let model = makeModel(driver)
        await primeFirstPage(model, driver)

        let cancelled = Task { await model.goNext() }
        await driver.waitUntilRequestCount(2)
        XCTAssertTrue(model.isLoading)

        cancelled.cancel()
        await cancelled.value

        XCTAssertFalse(model.isLoading, "the current generation must clear its own spinner")
        XCTAssertNil(model.errorText, "cancellation is not a failure the user should be shown")
        XCTAssertEqual(model.items.map(\.id), Array(1...48))
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertTrue(model.canGoNext)

        // `URLSession` reports a cancelled request as `URLError.cancelled`, and
        // `RommClient` propagates it unwrapped, so that is the form the model
        // actually meets in production.
        let urlCancelled = Task { await model.goNext() }
        await driver.waitUntilRequestCount(3)
        await driver.resume(2, throwing: URLError(.cancelled))
        await urlCancelled.value

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorText, "a cancelled URL request is not a failure either")
        XCTAssertEqual(model.items.map(\.id), Array(1...48))
        XCTAssertEqual(model.pageNumber, 1)
    }

    func testObsoleteCancellationCannotClearNewerLoading() async {
        let driver = FetchDriver()
        let model = makeModel(driver)
        await primeFirstPage(model, driver)

        let older = Task { await model.goNext() }
        await driver.waitUntilRequestCount(2)
        let newer = Task { await model.selectSort(.sizeLargest) }
        await driver.waitUntilRequestCount(3)
        XCTAssertTrue(model.isLoading)

        older.cancel()
        await older.value

        XCTAssertTrue(model.isLoading,
                      "an obsolete generation must not clear the newer request's spinner")
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.items.map(\.id), Array(1...48), "nothing may be published for it either")
        XCTAssertEqual(model.sort, .titleAscending)

        await driver.resume(2, with: RomPage(items: fixtureRoms(48, firstID: 5001),
                                             total: 200, limit: 48, offset: 0))
        await newer.value

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.items.map(\.id), Array(5001...5048))
        XCTAssertEqual(model.sort, .sizeLargest)
    }

    // MARK: Bare-array compatibility

    func testBareArrayTotalDisablesFirstAndLastButAllowsFullNextPage() async {
        let driver = FetchDriver { request, _ in bareArrayPage(request, total: 200) }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        XCTAssertNil(model.total)
        XCTAssertNil(model.pageCount, "no total means no honest page count")
        XCTAssertFalse(model.canGoFirst)
        XCTAssertFalse(model.canGoLast)
        XCTAssertTrue(model.canGoNext, "a full page could still have more behind it")

        await model.goNext()

        let requests = await driver.requests
        XCTAssertEqual(requests.last?.offset, 48)
        XCTAssertEqual(model.pageNumber, 2)
        XCTAssertEqual(model.items.map(\.id), Array(49...96))
        XCTAssertFalse(model.canGoFirst, "First stays disabled rather than guessing at a total")
        XCTAssertFalse(model.canGoLast)
        XCTAssertTrue(model.canGoPrevious)
        XCTAssertTrue(model.canGoNext)

        await model.goNext()   // page 3
        await model.goNext()   // page 4
        await model.goNext()   // page 5: 8 items, a short page
        XCTAssertEqual(model.pageNumber, 5)
        XCTAssertEqual(model.items.count, 8)
        XCTAssertFalse(model.canGoNext, "a short nonempty page proves it is the last one")
    }

    func testBareArrayEmptyNextKeepsLastNonemptyPageAndDisablesNext() async {
        // A bare-array library of exactly one full page: page 2 comes back empty.
        let driver = FetchDriver { request, _ in bareArrayPage(request, total: 48) }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        XCTAssertTrue(model.canGoNext)

        await model.goNext()

        XCTAssertEqual(model.items.map(\.id), Array(1...48),
                       "an empty speculative page must not blank the grid")
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertFalse(model.canGoNext, "the discovered boundary must disable Next")
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.isLoading)

        let countBefore = await driver.requestCount
        await model.goNext()
        let countAfter = await driver.requestCount
        XCTAssertEqual(countAfter, countBefore, "the boundary is remembered, not re-probed")

        // An empty *first* page is still published normally.
        let emptyDriver = FetchDriver { request, _ in bareArrayPage(request, total: 0) }
        let emptyModel = makeModel(emptyDriver)
        await emptyModel.loadCurrentPage()
        XCTAssertTrue(emptyModel.items.isEmpty)
        XCTAssertEqual(emptyModel.pageNumber, 1)
        XCTAssertFalse(emptyModel.canGoNext)
        XCTAssertNil(emptyModel.errorText)
    }

    // MARK: Persistence

    func testGlobalPageSizeAndPerPlatformSortPersistButPageDoesNot() async {
        let suiteName = "LibraryPagingTests.\(UUID().uuidString)"
        let defaults = isolatedDefaults(named: suiteName)
        let driver = FetchDriver { request, _ in envelopePage(request, total: 200) }
        let model = makeModel(driver, platformID: 7, defaults: defaults)

        await model.loadCurrentPage()
        await model.selectPageSize(96)
        await model.selectSort(.dateAddedNewest)
        model.recordFocusedRom(id: 5)     // a tile on page 1, which page 1 still holds
        await model.goNext()
        model.recordFocusedRom(id: 101)
        XCTAssertEqual(model.pageNumber, 2)

        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Set(domain.keys), ["library.pageSize", "library.sort.7"],
                       "page position and focused rom must never be persisted")

        // Relaunch: the same platform restores size and sort, and starts on page 1.
        let relaunched = makeModel(driver, platformID: 7, defaults: defaults)
        XCTAssertEqual(relaunched.pageSize, 96)
        XCTAssertEqual(relaunched.sort, .dateAddedNewest)
        XCTAssertEqual(relaunched.pageNumber, 1)
        await relaunched.loadCurrentPage()
        XCTAssertEqual(relaunched.items.map(\.id), Array(1...96))
        XCTAssertNil(relaunched.preferredFocusedRomID,
                     "rom 5 is on the restored page, so a persisted focus would surface here")

        // A different platform shares the global page size but keeps its own sort.
        let otherPlatform = makeModel(driver, platformID: 8, defaults: defaults)
        XCTAssertEqual(otherPlatform.pageSize, 96)
        XCTAssertEqual(otherPlatform.sort, .titleAscending)

        // A failed load must not persist the preferences it asked for.
        let failing = makeModel(FetchDriver { _, _ in throw RommError.http(500) },
                                platformID: 7, defaults: defaults)
        await failing.selectPageSize(24)
        XCTAssertEqual(defaults.integer(forKey: "library.pageSize"), 96,
                       "preferences are committed only with a successful page")
    }

    func testRefreshDoesNotRewriteGlobalPageSizeSetByAnotherModel() async {
        let defaults = isolatedDefaults()
        let driver = FetchDriver { request, _ in envelopePage(request, total: 200) }

        // Two platforms' models alive at once, as a navigation stack would keep them.
        let stale = makeModel(driver, platformID: 7, defaults: defaults)
        await stale.loadCurrentPage()
        XCTAssertEqual(stale.pageSize, 48)

        let newer = makeModel(driver, platformID: 8, defaults: defaults)
        await newer.loadCurrentPage()
        await newer.selectPageSize(96)
        XCTAssertEqual(defaults.integer(forKey: "library.pageSize"), 96)

        await stale.loadCurrentPage()   // a refresh, not a size action
        XCTAssertEqual(defaults.integer(forKey: "library.pageSize"), 96,
                       "paging or refreshing must not clobber a global size another model just set")
        XCTAssertEqual(stale.pageSize, 48, "the stale model keeps showing what it loaded")
    }

    // MARK: Shrunken library

    func testShrunkenTotalRefetchesLastValidPage() async {
        let driver = FetchDriver()
        let model = makeModel(driver)
        await primeFirstPage(model, driver)
        XCTAssertEqual(model.pageCount, 5)

        // Page 5 is requested, but the library shrank to 100 roms in the meantime.
        let last = Task { await model.goLast() }
        await driver.waitUntilRequestCount(2)
        await driver.resume(1, with: RomPage(items: [], total: 100, limit: 48, offset: 192))
        await driver.waitUntilRequestCount(3)
        let afterShrink = await driver.requests
        XCTAssertEqual(afterShrink.count, 3)
        XCTAssertEqual(afterShrink.last?.offset, 96,
                       "an offset the shrunken library no longer has must be corrected to the last valid page")
        await driver.resume(2, with: RomPage(items: fixtureRoms(4, firstID: 97),
                                             total: 100, limit: 48, offset: 96))
        await last.value

        XCTAssertEqual(model.pageNumber, 3, "only the corrected page is published")
        XCTAssertEqual(model.items.map(\.id), Array(97...100))
        XCTAssertEqual(model.total, 100)
        XCTAssertEqual(model.pageCount, 3)
        XCTAssertFalse(model.canGoNext)
        XCTAssertFalse(model.isLoading)

        // The correcting refetch is itself generation-guarded: shrink again, then
        // let a newer sort start before the correction lands.
        let previous = Task { await model.goPrevious() }
        await driver.waitUntilRequestCount(4)
        await driver.resume(3, with: RomPage(items: [], total: 20, limit: 48, offset: 48))
        await driver.waitUntilRequestCount(5)
        let afterSecondShrink = await driver.requests
        XCTAssertEqual(afterSecondShrink.count, 5)
        XCTAssertEqual(afterSecondShrink.last?.offset, 0)

        let newer = Task { await model.selectSort(.sizeLargest) }
        await driver.waitUntilRequestCount(6)
        await driver.resume(4, with: RomPage(items: fixtureRoms(20, firstID: 7001),
                                             total: 20, limit: 48, offset: 0))
        await previous.value

        XCTAssertEqual(model.items.map(\.id), Array(97...100),
                       "a superseded correction must not publish either")
        XCTAssertEqual(model.pageNumber, 3)
        XCTAssertTrue(model.isLoading, "the newer request still owns the spinner")

        await driver.resume(5, with: RomPage(items: fixtureRoms(20, firstID: 5001),
                                             total: 20, limit: 48, offset: 0))
        await newer.value
        XCTAssertEqual(model.items.map(\.id), Array(5001...5020))
        XCTAssertEqual(model.sort, .sizeLargest)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: Focus memory

    func testFocusedRomIsRememberedPerPageInMemory() async {
        let driver = FetchDriver { request, _ in envelopePage(request, total: 200) }
        let model = makeModel(driver)

        await model.loadCurrentPage()
        XCTAssertNil(model.preferredFocusedRomID)

        model.recordFocusedRom(id: 12)
        XCTAssertEqual(model.preferredFocusedRomID, 12)

        model.recordFocusedRom(id: nil)
        XCTAssertEqual(model.preferredFocusedRomID, 12,
                       "focus moving to the control row must not erase the page's tile")

        await model.goNext()
        XCTAssertNil(model.preferredFocusedRomID, "an unvisited page has no remembered tile")
        model.recordFocusedRom(id: 60)

        await model.goPrevious()
        XCTAssertEqual(model.preferredFocusedRomID, 12)
        await model.goNext()
        XCTAssertEqual(model.preferredFocusedRomID, 60)

        await model.selectSort(.sizeLargest)
        XCTAssertNil(model.preferredFocusedRomID, "a re-sorted library is a different list")

        model.recordFocusedRom(id: 99_999)
        XCTAssertNil(model.preferredFocusedRomID,
                     "a remembered tile that is not on the visible page must not be offered")
    }
}

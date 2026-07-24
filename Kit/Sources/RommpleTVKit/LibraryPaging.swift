import Combine
import Foundation

/// Server-paged state for one platform's library.
///
/// Paging and fetching live in one model on purpose: whether a response that
/// has just landed still describes what the user is looking at can only be
/// decided where both the request that produced it and the currently visible
/// page are known. Every load is an immutable `Target` — page index, page size
/// and sort — stamped with a monotonically increasing generation. A response
/// may touch published state only while its stamp is still the newest one, so a
/// late answer from an abandoned sort, a cancelled request, or a correction for
/// a library that shrank mid-flight can never overwrite fresher state.
///
/// Nothing but the visible page is kept in memory: there is no page cache to
/// grow unbounded as the user walks a large library.
@MainActor
public final class LibraryPageModel: ObservableObject {
    public typealias Fetch = @Sendable (
        _ limit: Int, _ offset: Int, _ sort: RomSort
    ) async throws -> RomPage

    /// The page sizes offered to the user. Any other value is refused.
    public static let pageSizes = [24, 48, 96]
    public static let defaultPageSize = 48

    /// Page size is a global preference; sort is per platform. Neither the page
    /// position nor the focused rom is ever written here.
    static let pageSizeDefaultsKey = "library.pageSize"
    static func sortDefaultsKey(platformID: Int) -> String { "library.sort.\(platformID)" }

    @Published public private(set) var items: [Rom] = []
    @Published public private(set) var pageIndex: Int
    @Published public private(set) var pageSize: Int
    @Published public private(set) var sort: RomSort
    @Published public private(set) var total: Int?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorText: String?

    /// The page index proven to be the end of a library that answered without a
    /// total. Only an empty page beyond a full one can establish it.
    private var bareArrayTerminalPageIndex: Int?

    /// One load's immutable description. Held by value so an in-flight request
    /// keeps asking for what it was issued for, whatever the user does next.
    private struct Target: Equatable {
        let pageIndex: Int
        let pageSize: Int
        let sort: RomSort
        var offset: Int { pageIndex * pageSize }
    }

    private let platformID: Int
    private let defaults: UserDefaults
    private let fetch: Fetch
    /// Monotonic request stamp. Only the newest generation may publish anything.
    private var generation = 0
    /// The target of the last failed load, reissued verbatim by `retry()`.
    private var failedTarget: Target?
    /// Focused rom per page index, in memory only, so returning to a page or
    /// coming back from a game lands on the tile the user left.
    private var focusedRomIDsByPage: [Int: Int] = [:]

    public init(platformID: Int, defaults: UserDefaults = .standard, fetch: @escaping Fetch) {
        self.platformID = platformID
        self.defaults = defaults
        self.fetch = fetch
        // Page position deliberately does not survive relaunch: every model starts
        // on page 1 with the restored global size and this platform's sort.
        self.pageIndex = 0
        self.pageSize = Self.validPageSize(defaults.object(forKey: Self.pageSizeDefaultsKey) as? Int)
        self.sort = defaults.string(forKey: Self.sortDefaultsKey(platformID: platformID))
            .flatMap(RomSort.init(rawValue:)) ?? .titleAscending
    }

    private static func validPageSize(_ candidate: Int?) -> Int {
        guard let candidate, pageSizes.contains(candidate) else { return defaultPageSize }
        return candidate
    }

    // MARK: - Derived state

    public var pageNumber: Int { pageIndex + 1 }
    public var pageCount: Int? {
        total.map { max(1, $0 / pageSize + ($0 % pageSize == 0 ? 0 : 1)) }
    }
    public var canGoFirst: Bool { total != nil && pageIndex > 0 }
    public var canGoPrevious: Bool { pageIndex > 0 }
    public var canGoNext: Bool {
        if let pageCount { return pageIndex + 1 < pageCount }
        // Without a total, a full page is the only evidence more might exist.
        return bareArrayTerminalPageIndex != pageIndex && items.count == pageSize
    }
    public var canGoLast: Bool { pageCount.map { pageIndex + 1 < $0 } ?? false }

    /// The tile to restore on the visible page, if it is still on it.
    public var preferredFocusedRomID: Int? {
        guard let id = focusedRomIDsByPage[pageIndex],
              items.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    // MARK: - Actions

    public func loadCurrentPage() async { await load(currentTarget) }

    /// Reissues the exact request that failed — which is usually not the page
    /// still on screen, because the failed page never became visible.
    public func retry() async { await load(failedTarget ?? currentTarget) }

    public func goFirst() async {
        guard canGoFirst else { return }
        await load(Target(pageIndex: 0, pageSize: pageSize, sort: sort))
    }

    public func goPrevious() async {
        guard canGoPrevious else { return }
        await load(Target(pageIndex: pageIndex - 1, pageSize: pageSize, sort: sort))
    }

    public func goNext() async {
        guard canGoNext else { return }
        await load(Target(pageIndex: pageIndex + 1, pageSize: pageSize, sort: sort))
    }

    public func goLast() async {
        guard canGoLast, let pageCount else { return }
        await load(Target(pageIndex: pageCount - 1, pageSize: pageSize, sort: sort))
    }

    /// Re-sorting is a new library ordering, so it restarts at page 1.
    /// Re-picking the sort already in use changes nothing and keeps the page.
    public func selectSort(_ sort: RomSort) async {
        guard sort != self.sort else { return }
        await load(Target(pageIndex: 0, pageSize: pageSize, sort: sort))
    }

    /// A new page size repartitions the library, so it restarts at page 1. A
    /// size outside `pageSizes` is refused rather than silently coerced, which
    /// would otherwise downgrade a valid preference the user already chose.
    public func selectPageSize(_ size: Int) async {
        guard Self.pageSizes.contains(size), size != pageSize else { return }
        await load(Target(pageIndex: 0, pageSize: size, sort: sort))
    }

    /// Remembers the focused tile for the visible page, in memory only.
    ///
    /// A `nil` id means focus moved off the grid — to the sort menu or a paging
    /// button — not that the page has no tile worth returning to, so it leaves
    /// the remembered tile alone. Changing sort or page size clears the whole
    /// memory, because the grid then holds a different list.
    public func recordFocusedRom(id: Int?) {
        guard let id else { return }
        focusedRomIDsByPage[pageIndex] = id
    }

    // MARK: - Loading

    private var currentTarget: Target {
        Target(pageIndex: pageIndex, pageSize: pageSize, sort: sort)
    }

    private func load(_ requested: Target) async {
        generation += 1
        let stamp = generation
        var target = requested
        isLoading = true
        errorText = nil
        // Any newly issued load makes an earlier failure obsolete; `retry()` has
        // already taken the target it wants above.
        failedTarget = nil

        while true {
            do {
                let page = try await fetch(target.pageSize, target.offset, target.sort)
                // Everything below this line is conditional on still being current.
                guard stamp == generation else { return }
                if Task.isCancelled { finishCancelled(); return }
                if let total = page.total, let corrected = correction(for: target, total: total) {
                    // The library shrank under this request: the offset it asked
                    // for no longer exists. Fetch the last page that does, under
                    // the same stamp, and publish only that — a newer user action
                    // still wins, because it moves `generation` past this stamp.
                    target = corrected
                    continue
                }
                publish(page, for: target)
                return
            } catch {
                guard stamp == generation else { return }
                if isCancellation(error) { finishCancelled(); return }
                // The visible page is untouched: only the failure is published,
                // and the target is kept so Retry can reissue exactly it.
                isLoading = false
                errorText = Self.message(for: error)
                failedTarget = target
                return
            }
        }
    }

    /// The last valid page when `total` no longer covers `target`'s offset, or
    /// `nil` when the requested page still exists. A zero total leaves page 1
    /// valid, so an empty library publishes an empty page 1 rather than looping.
    private func correction(for target: Target, total: Int) -> Target? {
        let pages = max(1, total / target.pageSize + (total % target.pageSize == 0 ? 0 : 1))
        guard target.pageIndex >= pages else { return nil }
        return Target(pageIndex: pages - 1, pageSize: target.pageSize, sort: target.sort)
    }

    /// Cancellation means the user asked for something else, not that anything
    /// went wrong, so it clears the spinner and says nothing. Reached only while
    /// the cancelled load is still the current generation.
    private func finishCancelled() {
        isLoading = false
        errorText = nil
    }

    /// Commits a successful response: items, page, size, sort, total and the
    /// persisted preferences all move together, and never before this point.
    private func publish(_ page: RomPage, for target: Target) {
        if page.total == nil, page.items.isEmpty, target.pageIndex > 0, !items.isEmpty {
            // A bare array carries no total, so Next past a full page is a
            // guess. An empty answer proves only that the previous page was the
            // last one — it must not blank the grid. Remember the boundary so
            // Next disables instead of probing it again.
            bareArrayTerminalPageIndex = pageIndex
            isLoading = false
            errorText = nil
            return
        }
        if target.sort != sort || target.pageSize != pageSize {
            focusedRomIDsByPage.removeAll()   // a different list is on screen now
        }
        items = page.items
        pageIndex = target.pageIndex
        pageSize = target.pageSize
        sort = target.sort
        total = page.total
        // A short nonempty page is itself proof of the end of a total-less library.
        bareArrayTerminalPageIndex =
            (page.total == nil && !page.items.isEmpty && page.items.count < target.pageSize)
            ? target.pageIndex : nil
        isLoading = false
        errorText = nil
        persistPreferences()
    }

    private func persistPreferences() {
        defaults.set(pageSize, forKey: Self.pageSizeDefaultsKey)
        defaults.set(sort.rawValue, forKey: Self.sortDefaultsKey(platformID: platformID))
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func message(for error: Error) -> String {
        if let error = error as? RommError {
            switch error {
            case .http(let status): return "The server returned an error (\(status))."
            case .badResponse: return "The server sent an unexpected response."
            }
        }
        return error.localizedDescription
    }
}

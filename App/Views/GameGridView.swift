import SwiftUI
import RommpleTVKit

/// Decoded cover artwork for the page on screen and, as far as the budget
/// stretches, the one just left.
///
/// The grid no longer holds a whole platform in memory, so the artwork behind
/// it must not either. Two limits bound it, and they are not equal partners:
///
/// - `totalCostLimit` is 64 MiB of *decoded* pixels — the memory a cover
///   actually occupies once it is a `UIImage`, and the figure that has to fit
///   inside a tvOS app's footprint. This is the limit that binds in practice.
/// - `countLimit = 192` is 2 × 96, the largest offered page size doubled. It is
///   an upper bound on entries, not an achievable depth: 64 MiB spread over 192
///   entries budgets only ~341 KB each, about a 295 × 295 RGBA image, and RomM's
///   `small.png` covers decode larger than that. Real depth is therefore closer
///   to a single page at 96 than to two.
///
/// Cost is the budget; count is the backstop for images whose decoded size
/// cannot be measured. This cache is in-memory only; nothing here is written to
/// disk.
private let coverCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 192
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
}()

/// The bytes a decoded cover occupies, or 0 when the image has no `CGImage`
/// backing and its true size cannot be measured — such an image is still
/// bounded by `countLimit`. The compressed response size is deliberately not
/// used: it understates a decoded cover several-fold, which would let the cache
/// hold a multiple of its stated ceiling.
private func decodedByteCost(of image: UIImage) -> Int {
    guard let cgImage = image.cgImage else { return 0 }
    return cgImage.height * cgImage.bytesPerRow
}

struct CoverImage: View {
    let rom: Rom
    let client: RommClient
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Text(rom.name ?? rom.fsName).font(.caption2)
                        .multilineTextAlignment(.center).padding(6)
                }
            }
        }
        .task {
            guard image == nil, let url = client.coverURL(for: rom) else { return }
            let key = url.absoluteString as NSString
            if let hit = coverCache.object(forKey: key) { image = hit; return }
            guard let (data, resp) = try? await URLSession.shared.data(
                for: client.authorizedRequest(url)),
                (resp as? HTTPURLResponse)?.statusCode == 200,
                let img = UIImage(data: data) else { return }
            coverCache.setObject(img, forKey: key, cost: decodedByteCost(of: img))
            image = img
        }
    }
}

/// One platform's library, one server page at a time.
///
/// The view owns nothing about paging except where focus should sit: every
/// question of what to show, whether a control can be pressed, and whether a
/// response is still current is answered by `LibraryPageModel`. The model's
/// published state is `private(set)`, so the only way this view changes
/// anything is by calling one of its methods.
struct GameGridView: View {
    let platform: Platform
    let client: RommClient

    /// One model per visible platform, created once with the view and dying
    /// with it. A `@StateObject` here — rather than a shared or injected model
    /// — is what keeps a model from outliving the screen it belongs to, which
    /// is the assumption its per-platform sort persistence is written against.
    @StateObject private var model: LibraryPageModel

    /// The focused tile. `nil` means focus is not on the grid at all.
    @FocusState private var focusedRomID: Int?

    /// The focused control, when focus is on one. Two `@FocusState` properties
    /// can never both be non-nil, so this is exactly the question "is the user
    /// currently standing on a menu or a paging button?" — which is what the
    /// focus-restoration rules below are gated on. Retry is deliberately not
    /// tracked here: it vanishes the moment it is pressed, so nothing is left to
    /// steal focus from and the grid becomes a valid destination — though the
    /// focus engine's own fixup for the removed button may land elsewhere in the
    /// control row first.
    @FocusState private var focusedControl: ControlFocus?

    /// Whether any load has finished on this screen yet.
    ///
    /// This is what "the very first page of a fresh screen" means, and it is
    /// deliberately not the same question as "is the grid empty right now".
    /// Every later load — a Retry after a failed first attempt, a sort change on
    /// a platform that legitimately has no games — also runs with an empty grid,
    /// and gating the controls on emptiness would delete the row the user is
    /// standing on for the length of that request. Once true this never goes
    /// back to false, so the control row, once it exists, is permanent.
    @State private var hasSettledOnce = false

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 32)]

    init(platform: Platform, client: RommClient) {
        self.platform = platform
        self.client = client
        let platformID = platform.id
        _model = StateObject(wrappedValue: LibraryPageModel(
            platformID: platformID,
            fetch: { limit, offset, sort in
                try await client.romsPage(
                    platformId: platformID,
                    limit: limit,
                    offset: offset,
                    sort: sort,
                    groupByMetaId: true
                )
            }
        ))
    }

    // MARK: - Focus identities

    private enum PagingAction: Hashable {
        case first, previous, next, last
        var title: String {
            switch self {
            case .first: "First"
            case .previous: "Previous"
            case .next: "Next"
            case .last: "Last"
            }
        }
    }

    /// The controls appear twice — once above the grid and once below it — so a
    /// remote user never has to travel back to the top. Each copy needs its own
    /// focus identity.
    private enum ControlRow: Hashable { case top, bottom }

    private enum ControlFocus: Hashable {
        case sortMenu
        case pageSizeMenu
        case paging(PagingAction, ControlRow)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if showsControls {
                controlRow(.top)
                // Gating the whole row on `errorText` is what closes the
                // double-Retry hole: `retry()` clears the failed target when it
                // issues, so a second press while the first is in flight would
                // reload the visible page instead of the page that failed.
                // `errorText` is cleared at issue too, so this row — and the
                // only Retry button in the view — is gone before that second
                // press is possible.
                if let errorText = model.errorText {
                    errorRow(errorText)
                }
            }
            content
        }
        .navigationTitle(platform.name)
        .task { await loadFirstPageIfNeeded() }
        // Returning from a game does not reload; it only puts focus back where
        // the user left it, if the pop did not already do that.
        .onAppear { focusPreferredTile(onlyWhenGridUnfocused: true) }
        .onChange(of: focusedRomID) { _, id in model.recordFocusedRom(id: id) }
        // The first completed load settles the screen for good.
        //
        // `isLoading` falling back to false is the event common to all four
        // outcomes — a committed page, a failure, a cancellation, and a
        // successful but *empty* page. That last one is why this cannot watch
        // `items`: a platform with no games publishes no item change and no
        // error, so an observer on those would never fire and the control row
        // would stay removable underneath a user who is standing on it.
        //
        // The `errorText` half is a backstop for the one outcome the first half
        // could miss: a load that fails before it ever suspends never renders
        // `isLoading` as true, so nothing changes on the way back down. The real
        // client always suspends in `URLSession` first, but a latch that leaves
        // the screen showing a spinner with no controls if it is ever wrong is
        // not worth leaving to that.
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading { hasSettledOnce = true }
        }
        .onChange(of: model.errorText) { _, text in
            if text != nil { hasSettledOnce = true }
        }
        // Fires exactly when a page commits, which the model only ever does on
        // success — so nothing below reacts to a request that failed or to one
        // that was superseded while in flight.
        .onChange(of: model.items.map(\.id)) { _, _ in
            focusPreferredTile(onlyWhenGridUnfocused: false)
        }
    }

    /// The controls are hidden only until the first load of a fresh screen has
    /// finished: there is nothing yet to sort, resize, or page through, and
    /// leaving them out means the focus engine has nowhere to park focus — so
    /// the page that lands can take focus without taking it from anything. From
    /// the first settle onward the row is permanent, whatever the grid contains.
    ///
    /// `hasSettledOnce` is set by an observer, which runs *after* the body that
    /// first draws the page it settled on. The `!items.isEmpty` term is what
    /// keeps the row arriving in the same render pass as that first page
    /// instead of one pass behind it — which is also the timing the original
    /// predicate had, so the first-entry focus behaviour is unchanged.
    ///
    /// That the row is never torn down once it appears is also what keeps
    /// `focusedControl` from being left pointing at a view that no longer
    /// exists, which would arm `focusPreferredTile`'s no-steal guard
    /// permanently and leave every later page with no focused tile.
    private var showsControls: Bool { hasSettledOnce || !model.items.isEmpty }

    @ViewBuilder
    private var content: some View {
        if !model.items.isEmpty {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(model.items) { rom in
                        card(for: rom)
                    }
                }
                .padding(48)
                controlRow(.bottom)
            }
        } else if model.isLoading || !hasSettledOnce {
            // `!hasSettledOnce` covers the frame between this screen appearing
            // and its `.task` starting the first load, where the model is idle
            // with nothing in it. Without it that frame reads "No games on this
            // page." about a library nobody has asked the server about yet.
            ProgressView("Loading \(platform.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.errorText != nil {
            // The message and the Retry button live in the error row above; an
            // empty grid only needs to say which library stayed empty.
            Text("Couldn't load \(platform.name)")
                .font(.title3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No games on this page.")
                .font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func card(for rom: Rom) -> some View {
        NavigationLink {
            EmulatorScreen(rom: rom, platformSlug: platform.slug, client: client)
        } label: {
            VStack {
                CoverImage(rom: rom, client: client)
                    .frame(height: 260)
                Text(rom.name ?? rom.fsName)
                    .font(.caption).lineLimit(1)
            }
        }
        .buttonStyle(.card)
        .disabled(!PlatformSupport.isPlayable(slug: platform.slug))
        .focused($focusedRomID, equals: rom.id)
    }

    // MARK: - Controls

    private func controlRow(_ row: ControlRow) -> some View {
        HStack(spacing: 16) {
            if row == .top {
                sortMenu
                pageSizeMenu
            }
            Spacer(minLength: 0)
            pagingButton(.first, in: row)
            pagingButton(.previous, in: row)
            Text(pageLabel).monospacedDigit()
            pagingButton(.next, in: row)
            pagingButton(.last, in: row)
            // A page already on screen is never replaced by a spinner; progress
            // shows here instead. Always present and only faded, so a request
            // starting or finishing cannot shuffle the buttons under a thumb.
            ProgressView()
                .opacity(model.isLoading ? 1 : 0)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 48)
        .padding(.vertical, row == .top ? 12 : 32)
        // Lets a swipe out of the grid reach this row even when it lands
        // between two of its buttons.
        .focusSection()
    }

    /// The menu shows the sort the server has actually delivered, not the one
    /// last tapped: `model.sort` commits only when its page lands. A failed
    /// sort therefore leaves this label on the ordering still on screen, which
    /// is also what makes re-picking that visible value a working undo for the
    /// failure (the model treats a no-op selection as dismissing it).
    private var sortMenu: some View {
        Menu {
            ForEach(RomSort.allCases, id: \.self) { sort in
                Button { Task { await model.selectSort(sort) } } label: {
                    if sort == model.sort {
                        Label(sort.title, systemImage: "checkmark")
                    } else {
                        Text(sort.title)
                    }
                }
            }
        } label: {
            Label(model.sort.title, systemImage: "arrow.up.arrow.down")
        }
        .focused($focusedControl, equals: .sortMenu)
    }

    /// Sizes come from the model, never from `UserDefaults`: the model owns
    /// that key and normalizes whatever is stored under it, so a value read
    /// here could disagree with the one actually in use.
    private var pageSizeMenu: some View {
        Menu {
            ForEach(LibraryPageModel.pageSizes, id: \.self) { size in
                Button { Task { await model.selectPageSize(size) } } label: {
                    if size == model.pageSize {
                        Label("\(size) per page", systemImage: "checkmark")
                    } else {
                        Text("\(size) per page")
                    }
                }
            }
        } label: {
            Label("\(model.pageSize) per page", systemImage: "square.grid.3x3")
        }
        .focused($focusedControl, equals: .pageSizeMenu)
    }

    private func pagingButton(_ action: PagingAction, in row: ControlRow) -> some View {
        Button(action.title) {
            // Presses do not stack. The model commits `pageIndex` only on
            // success, so a second press while the first is in flight rebuilds
            // the same target rather than advancing twice — and nothing here
            // suggests otherwise, because the page label only ever shows the
            // page that has committed.
            //
            // Unstructured on purpose: unlike `.task`, this is not cancelled
            // when the screen is covered by a pushed `EmulatorScreen`, so a page
            // requested just before a game is launched still commits behind it.
            // Pressing Next and then opening a game before the page lands
            // therefore returns to the new page rather than the one the game was
            // launched from — the user did press Next, and cancelling their
            // request because they were quick would be the stranger answer.
            Task { await perform(action) }
        }
        .disabled(!isEnabled(action))
        .focused($focusedControl, equals: .paging(action, row))
    }

    /// Below the top controls, where the failure and its remedy sit together.
    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 24) {
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Button("Retry") { Task { await model.retry() } }
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 12)
        .focusSection()
    }

    /// `pageCount` is `nil` when the server answered with a bare array and no
    /// total, and the total is not guessed from a page that happened to be
    /// full — so the count is simply left off rather than invented. First and
    /// Last disable themselves for the same reason.
    private var pageLabel: String {
        if let pageCount = model.pageCount {
            "Page \(model.pageNumber) of \(pageCount)"
        } else {
            "Page \(model.pageNumber)"
        }
    }

    private func perform(_ action: PagingAction) async {
        switch action {
        case .first: await model.goFirst()
        case .previous: await model.goPrevious()
        case .next: await model.goNext()
        case .last: await model.goLast()
        }
    }

    private func isEnabled(_ action: PagingAction) -> Bool {
        switch action {
        case .first: model.canGoFirst
        case .previous: model.canGoPrevious
        case .next: model.canGoNext
        case .last: model.canGoLast
        }
    }

    // MARK: - Loading and focus

    /// The first page, and only the first page.
    ///
    /// `.task` runs again every time this screen reappears — including the pop
    /// back from a game — and `loadCurrentPage()` is unconditional: it always
    /// issues a request. Ungated, coming back from a game would refetch the
    /// page the user left and discard the in-memory page and remembered tile
    /// this screen exists to preserve. An empty grid with no failure on screen
    /// is the only state that still needs a first page; a failure belongs to
    /// the Retry button, not to an automatic reload racing it.
    private func loadFirstPageIfNeeded() async {
        guard model.items.isEmpty, model.errorText == nil else { return }
        await model.loadCurrentPage()
    }

    /// The tile a page wants focus to be on: the one the user left on this page
    /// if it is still there, otherwise the first. After a sort or page-size
    /// change the model has cleared its focus memory, so this is the first tile
    /// of the new ordering.
    private var preferredTileID: Int? {
        model.preferredFocusedRomID ?? model.items.first?.id
    }

    /// Moves focus onto `preferredTileID`, but never out from under the user.
    ///
    /// A menu or paging button holding focus is a live interaction: the user is
    /// about to press it again, or is reading the page count beside it. Pulling
    /// focus into the grid there would send their next swipe somewhere they did
    /// not aim it, so this returns instead and leaves the grid to the focus
    /// engine, which enters it from whichever control the user swipes off.
    ///
    /// - Parameter onlyWhenGridUnfocused: `true` on reappearance, where the pop
    ///   back from a game may already have restored the tile and re-assigning
    ///   would only risk moving it.
    private func focusPreferredTile(onlyWhenGridUnfocused: Bool) {
        guard focusedControl == nil else { return }
        if onlyWhenGridUnfocused, focusedRomID != nil { return }
        guard let preferredTileID else { return }
        focusedRomID = preferredTileID
    }
}

import SwiftUI
import RommpleTVKit

/// The one screen between a card and a running game, for every platform.
///
/// It renders `LaunchPreparationModel` and does nothing else: it holds no
/// download state, builds no URL, and knows nothing about packages, BIOS files,
/// memory-card identities or RomM endpoints. Everything on screen comes from the
/// model's published `state` and throttled `progress`, and every action is one
/// of the model's four commands.
///
/// `ready` is a builder rather than a fixed `EmulatorHostView` so the
/// argument-gated UI-test fixture can drive this exact view without dlopening a
/// core the simulator does not have.
struct LaunchPreparationView<Ready: View>: View {
    let title: String
    @ViewBuilder let ready: (PreparedLaunch) -> Ready

    @StateObject private var model: LaunchPreparationModel
    @Environment(\.dismiss) private var dismiss

    /// Which control a failure screen opens on. Explicit rather than left to the
    /// focus engine so the remedy is the button under the player's thumb.
    private enum FailureAction: Hashable { case retry, back }
    @FocusState private var focusedFailureAction: FailureAction?

    init(model: @autoclosure @escaping () -> LaunchPreparationModel,
         title: String,
         @ViewBuilder ready: @escaping (PreparedLaunch) -> Ready) {
        _model = StateObject(wrappedValue: model())
        self.title = title
        self.ready = ready
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .preparing:
                preparing
            case let .conflict(conflict, failure):
                ConflictChooser(conflict: conflict, failure: failure,
                                onChoose: { model.resolve(choice: $0) },
                                onCancel: cancelAndLeave)
            case let .ready(launch):
                ready(launch)
            case let .failed(failure):
                failureView(failure)
            case .cancelled:
                // The dismissal is already on its way; this frame just must not
                // claim anything is still happening.
                ProgressView()
            }
        }
        .task { model.run() }
        // Backing out with the Siri Remote's Menu button is the same decision as
        // pressing Cancel — but **not the same guarantee**, and the difference is
        // worth knowing before relying on it. `cancelAndLeave()` awaits the
        // cleanup and only then dismisses; `onDisappear` cannot await anything,
        // so this is fire-and-forget and the screen is already gone. Backing out
        // and immediately launching another PlayStation game can therefore
        // construct a second `PS1PackageStore` — whose initializer sweeps
        // `Caches/games/psx` — while the previous attempt is still unwinding.
        // That is not corrupting: the new attempt's staging directory carries a
        // fresh UUID and does not exist yet when the sweep runs, and the
        // cancelled attempt's remaining writes simply fail into the cleanup it
        // was already performing. It is left as is rather than restructured,
        // because the alternatives (blocking dismissal, or a shared store that
        // outlives an attempt) are both worse.
        .onDisappear { Task { await model.cancel() } }
    }

    // MARK: Preparing

    private var preparing: some View {
        VStack(spacing: 20) {
            Text(title).font(.title3).lineLimit(2)
            Text(model.progress.headline)
                .font(.headline)
                .accessibilityIdentifier("prep.stage")
            if let fraction = model.progress.fraction {
                ProgressView(value: fraction).frame(maxWidth: 800)
            } else {
                ProgressView().frame(maxWidth: 800)
            }
            if !model.progress.detail.isEmpty {
                Text(model.progress.detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("prep.detail")
            }
            if model.progress.totalBytes > 0 {
                Text("\(byteText(model.progress.completedBytes)) of "
                     + "\(byteText(model.progress.totalBytes))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("prep.bytes")
            }
            discSection
            Button("Cancel", action: cancelAndLeave)
                .accessibilityIdentifier("prep.cancel")
        }
        .padding(48)
    }

    /// The defence against a disc set the classifier got wrong.
    ///
    /// `PS1GameClassifier` cannot distinguish a genuine multi-disc game from two
    /// separately numbered products that share a metadata group and both start at
    /// disc 1 — a demo or sampler series is the known case, and no filename rule
    /// separates them. Showing the resolved set is what turns "the wrong game
    /// silently launched" into something the player can see, and the override
    /// button is what lets them do something about it.
    @ViewBuilder
    private var discSection: some View {
        // Read from the model, not from a value captured when this screen was
        // built, so refusing the merge changes what is listed as well as what is
        // launched.
        let discs = model.discs
        if discs.count > 1 {
            VStack(spacing: 8) {
                Text("This game was read as \(discs.count) discs:")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("prep.discSummary")
                ForEach(discs) { disc in
                    Text("\(disc.label) — \(disc.fileStem)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let singleDiscOverride = model.singleDiscOverride {
                    Button("Not one game — play this disc only") {
                        model.override(with: singleDiscOverride)
                    }
                    .accessibilityIdentifier("prep.singleDisc")
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: Failure

    private func failureView(_ failure: LaunchFailure) -> some View {
        VStack(spacing: 16) {
            Text("Can't start \(title)").font(.title3).lineLimit(2)
            Text(failure.message)
                .font(.callout).multilineTextAlignment(.center)
                .accessibilityIdentifier("prep.failure")
            if let recovery = failure.recovery {
                Text(recovery)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("prep.recovery")
            }
            if failure.isRetryable {
                Button("Retry") { model.retry() }
                    .focused($focusedFailureAction, equals: .retry)
                    .accessibilityIdentifier("prep.retry")
            }
            Button("Back to Library", action: cancelAndLeave)
                .focused($focusedFailureAction, equals: .back)
                .accessibilityIdentifier("prep.back")
        }
        .frame(maxWidth: 900)
        .padding(48)
        .onAppear { focusedFailureAction = failure.isRetryable ? .retry : .back }
    }

    // MARK: Actions

    /// Cancel waits for the attempt to unwind — handles closed, staging
    /// directory and part file removed — and only then leaves the screen.
    private func cancelAndLeave() {
        Task {
            await model.cancel()
            dismiss()
        }
    }

    /// Whole megabytes, which is the only precision a player can read off a
    /// television. Never a path, and never a byte-exact figure that changes
    /// faster than it can be read.
    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// Two cards, two dates, and a sentence saying nothing is thrown away.
private struct ConflictChooser: View {
    let conflict: PS1SaveConflict
    let failure: LaunchFailure?
    let onChoose: (PS1ConflictChoice) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: PS1ConflictChoice?

    var body: some View {
        VStack(spacing: 20) {
            Text("Two memory cards").font(.title3)
            Text("This game's memory card on this Apple TV and the one on your RomM server "
                 + "are different, and RommpleTV will not choose for you.")
                .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 900)
            HStack(spacing: 48) {
                VStack(spacing: 6) {
                    Text("This Apple TV").font(.caption).foregroundStyle(.secondary)
                    Text(Self.dateText(conflict.localModifiedAt))
                        .font(.callout).monospacedDigit()
                        .accessibilityIdentifier("conflict.localDate")
                }
                VStack(spacing: 6) {
                    Text("RomM").font(.caption).foregroundStyle(.secondary)
                    Text(Self.dateText(conflict.remoteModifiedAt))
                        .font(.callout).monospacedDigit()
                        .accessibilityIdentifier("conflict.remoteDate")
                }
            }
            Text("Whichever you do not choose is copied to your RomM server first, so nothing "
                 + "is thrown away and you can go back to it.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 900)
                .accessibilityIdentifier("conflict.explanation")
            if let failure {
                VStack(spacing: 4) {
                    Text(failure.message).font(.caption)
                    if let recovery = failure.recovery {
                        Text(recovery).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("conflict.failure")
            }
            HStack(spacing: 24) {
                Button("Use This Apple TV") { onChoose(.local) }
                    .focused($focused, equals: .local)
                    .accessibilityIdentifier("conflict.local")
                Button("Use RomM") { onChoose(.remote) }
                    .focused($focused, equals: .remote)
                    .accessibilityIdentifier("conflict.remote")
            }
            Button("Cancel", action: onCancel)
                .accessibilityIdentifier("prep.cancel")
        }
        .padding(48)
        .onAppear { focused = .local }
    }

    /// A card whose date is unknown says so rather than showing a wrong one:
    /// RomM's timestamps do not always parse, and the mirror in UserDefaults
    /// carries no date at all.
    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "Date unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

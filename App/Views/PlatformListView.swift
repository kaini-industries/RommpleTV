import SwiftUI
import RommpleTVKit

struct PlatformListView: View {
    let client: RommClient
    var onReset: () -> Void
    @State private var platforms: [Platform] = []
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if platforms.isEmpty, let errorText {
                    VStack(spacing: 16) {
                        Text("Couldn't reach RomM").font(.title3)
                        Text(errorText).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await load() } }
                        Button("Server Settings") { onReset() }
                    }
                } else if platforms.isEmpty && isLoading {
                    ProgressView("Loading library…")
                } else {
                    List(platforms) { platform in
                        NavigationLink {
                            GameGridView(platform: platform, client: client)
                        } label: {
                            HStack {
                                Text(platform.name)
                                Spacer()
                                Text("\(platform.romCount)").foregroundStyle(.secondary)
                                if !PlatformSupport.isPlayable(slug: platform.slug) {
                                    Text("browse only").font(.caption2)
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("RommpleTV")
            .task { await load() }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorText = nil
        do {
            let all = try await client.platforms().filter { $0.romCount > 0 }
            // Playable platforms first, then by library size.
            platforms = all.sorted {
                (PlatformSupport.isPlayable(slug: $0.slug) ? 0 : 1, -$0.romCount)
                    < (PlatformSupport.isPlayable(slug: $1.slug) ? 0 : 1, -$1.romCount)
            }
        } catch is CancellationError { return }
        catch let e as URLError where e.code == .cancelled { return }
        catch { errorText = String(describing: error) }
    }
}

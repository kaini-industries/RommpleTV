import SwiftUI
import RommpleTVKit

struct EmulatorScreen: View {
    let rom: Rom
    let platformSlug: String
    let client: RommClient
    @State private var progress: Double = 0
    @State private var localURL: URL?
    @State private var errorText: String?
    @State private var isDownloading = false
    @State private var attempt = 0

    private var cache: CacheManager {
        CacheManager(client: client,
                     cacheRoot: FileManager.default.urls(for: .cachesDirectory,
                                                         in: .userDomainMask)[0]
                        .appendingPathComponent("roms", isDirectory: true))
    }

    var body: some View {
        Group {
            if let localURL {
                if let core = PlatformSupport.core(forSlug: platformSlug) {
                    EmulatorHostView(romURL: localURL, coreName: core.coreName, romID: rom.id)
                } else {
                    VStack(spacing: 12) {
                        Text("Not playable on Apple TV").font(.title3)
                        Text("\(platformSlug) has no embedded core (see the spec's platform notes).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let errorText {
                VStack(spacing: 16) {
                    Text("Download failed").font(.title3)
                    Text(errorText).font(.caption).foregroundStyle(.secondary)
                    // Bumping attempt reruns .task(id:) — structured, so
                    // backing out cancels the download instead of leaving an
                    // orphan Task writing the shared .part file.
                    Button("Retry") { attempt += 1 }
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 800)
                    Text("Downloading \(rom.fsName) — \(Int(progress * 100))%")
                }
            }
        }
        .task(id: attempt) { await download() }
    }

    private func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        defer { isDownloading = false }
        errorText = nil
        do {
            localURL = try await cache.download(rom) { p in
                Task { @MainActor in progress = p }
            }
        } catch { errorText = String(describing: error) }
    }
}

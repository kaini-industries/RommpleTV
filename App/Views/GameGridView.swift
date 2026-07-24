import SwiftUI
import RommpleTVKit

private let coverCache = NSCache<NSString, UIImage>()

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
            coverCache.setObject(img, forKey: key)
            image = img
        }
    }
}

struct GameGridView: View {
    let platform: Platform
    let client: RommClient
    @State private var roms: [Rom] = []
    @State private var errorText: String?
    @State private var isLoading = false
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 32)]

    var body: some View {
        Group {
            if roms.isEmpty, let errorText {
                VStack(spacing: 16) {
                    Text("Couldn't load \(platform.name)").font(.title3)
                    Text(errorText).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
            } else if roms.isEmpty && isLoading {
                ProgressView("Loading \(platform.name)…")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(roms) { rom in
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
                        }
                    }.padding(48)
                }
            }
        }
        .navigationTitle(platform.name)
        .task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorText = nil
        do {
            var all: [Rom] = []
            var offset = 0
            while true {
                let page = try await client.romsPage(platformId: platform.id,
                                                     limit: 500, offset: offset)
                all += page.items
                offset = all.count
                if page.items.count < 500 { break }
                if let total = page.total, all.count >= total { break }
            }
            roms = all
        } catch is CancellationError { return }
        catch let e as URLError where e.code == .cancelled { return }
        catch { errorText = String(describing: error) }
    }
}

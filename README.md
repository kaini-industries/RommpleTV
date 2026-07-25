# RommpleTV

RommpleTV is a native tvOS client for a self-hosted [RomM](https://romm.app) server. It browses a RomM library and runs supported systems locally through libretro cores embedded at build time.

## Status

Early development. Supported systems currently include SNES, NES, Game Boy/Game Boy Color/Game Boy Advance, Genesis/Master System/Game Gear, and Virtual Boy.

## Requirements

- Apple TV running tvOS 17 or newer
- Xcode with the tvOS SDK
- XcodeGen
- A reachable RomM 5.x server and RomM client API token
- A paired game controller

## Build

1. Clone the repository.
2. Install XcodeGen: `brew install xcodegen`.
3. Download local libretro cores: `scripts/fetch-cores.sh`.
4. Prepare the project: `scripts/bootstrap.sh`. Run this rather than `xcodegen generate` directly — it writes a generated config file that has to exist before XcodeGen collects sources.
5. Open `RommpleTV.xcodeproj`.
6. Set your Apple development team and a unique bundle identifier (see below).
7. Build and run on Apple TV.

On first launch, enter the URL of your RomM server and a RomM client API token. No server address or credential is included in the repository.

### Local settings

Signing and server details are personal, so they live in untracked files that override tracked public defaults. Nothing here is required — without any of it you get `com.example.rommpletv`, an unsigned Simulator build, and on-screen setup.

- **`Config/Local.xcconfig`** — your `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER`. `Config/Public.xcconfig` pulls it in with an optional `#include?`, which is skipped when the file is absent. Device builds need it.
- **`Config/local.env`** — your RomM base URL and the Apple TV's device identifier. Copy `Config/local.env.example` and fill it in.
- **`.romm.token`** — your RomM API token, alone on the first line.

With `Config/local.env` and `.romm.token` present, `scripts/bootstrap.sh` bakes the server URL and token into the build so a development install configures itself instead of asking you to type a token with a remote. This is a development convenience and is not how the app is meant to be configured long term.

`scripts/deploy.sh` builds, installs and launches on the Apple TV named in `Config/local.env`, reading the bundle identifier back from the app it just built so it can never launch a stale install.

## Test

After running `scripts/fetch-cores.sh`:

```sh
cd Kit
swift test
```

Some SNES integration tests use an optional, untracked `test.sfc` supplied by the developer and skip when it is absent. The NES core regression test generates its own minimal non-game iNES payload.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Legal

RommpleTV contains no games, firmware, saves, artwork, or downloaded emulator cores. Supply only content you are legally entitled to use. Downloaded libretro cores retain their own licenses.

## License

RommpleTV source code is available under the MIT License. See [LICENSE](LICENSE).

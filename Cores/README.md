# Local libretro cores

RommpleTV plays supported systems on-device through prebuilt libretro cores. The
cores are not part of this repository. Run `scripts/fetch-cores.sh` to download
them from the [libretro buildbot](https://buildbot.libretro.com/) before building
or testing:

```sh
scripts/fetch-cores.sh
```

The script downloads two sets of artifacts:

- `Cores/tvos/` — tvOS (`arm64`) cores that are embedded in the app at build time.
- `Cores/macos/` — macOS (`arm64`) cores used only by the `Kit` Swift package
  integration tests.

After downloading, the script writes `Cores/MANIFEST.md` recording the fetch time
and the SHA-256 of each dylib. The downloaded dylibs and the generated
`MANIFEST.md` are untracked (see `.gitignore`); rerun the script to regenerate
them.

## Cores and upstream projects

Each core is built and distributed by the [libretro](https://www.libretro.com/)
project and retains its own license. Consult the source repository and the
libretro documentation page for authorship and license terms.

| Core file | Project | Systems | Source | License / details |
| --- | --- | --- | --- | --- |
| `snes9x` | Snes9x | SNES | [libretro/snes9x](https://github.com/libretro/snes9x) | [docs.libretro.com](https://docs.libretro.com/library/snes9x/) |
| `mgba` | mGBA | Game Boy, Game Boy Color, Game Boy Advance | [libretro/mgba](https://github.com/libretro/mgba) (upstream [mgba-emu/mgba](https://github.com/mgba-emu/mgba)) | [docs.libretro.com](https://docs.libretro.com/library/mgba/) |
| `genesis_plus_gx` | Genesis Plus GX | Genesis/Mega Drive, Master System, Game Gear | [libretro/Genesis-Plus-GX](https://github.com/libretro/Genesis-Plus-GX) | [docs.libretro.com](https://docs.libretro.com/library/genesis_plus_gx/) |
| `fceumm` | FCEUmm | NES | [libretro/libretro-fceumm](https://github.com/libretro/libretro-fceumm) | [docs.libretro.com](https://docs.libretro.com/library/fceumm/) |
| `mednafen_vb` | Beetle VB (Mednafen VB) | Virtual Boy | [libretro/beetle-vb-libretro](https://github.com/libretro/beetle-vb-libretro) | [docs.libretro.com](https://docs.libretro.com/library/beetle_vb/) |

These cores are downloaded, not bundled here. RommpleTV ships no games, firmware,
saves, artwork, or emulator binaries; supply only content you are legally
entitled to use.

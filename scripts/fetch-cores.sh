#!/usr/bin/env bash
# Downloads prebuilt libretro cores from the libretro buildbot.
# tvOS cores ship in the app; macOS cores exist only for Kit unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."
BB=https://buildbot.libretro.com/nightly/apple
CORES_TVOS=(snes9x mgba genesis_plus_gx fceumm mednafen_vb mednafen_psx)
CORES_MACOS=(snes9x mgba genesis_plus_gx fceumm mednafen_vb mednafen_psx)
mkdir -p Cores/tvos Cores/macos
fetch() { # $1 url  $2 outdir
  local zip; zip="$2/$(basename "$1")"
  curl -fL --retry 3 -o "$zip" "$1"
  unzip -o "$zip" -d "$2" && rm "$zip"
}
for c in "${CORES_TVOS[@]}";  do fetch "$BB/tvos-arm64/latest/${c}_libretro_tvos.dylib.zip" Cores/tvos;  done
for c in "${CORES_MACOS[@]}"; do fetch "$BB/osx/arm64/latest/${c}_libretro.dylib.zip"       Cores/macos; done
{ echo "# Core provenance — regenerate with scripts/fetch-cores.sh"
  echo "Fetched: $(date -u +%Y-%m-%dT%H:%M:%SZ) from $BB (nightly/latest)"
  echo; shasum -a 256 Cores/tvos/*.dylib Cores/macos/*.dylib
} > Cores/MANIFEST.md
echo OK

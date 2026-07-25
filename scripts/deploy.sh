#!/usr/bin/env bash
# Builds, installs and launches on a real Apple TV.
#
# The bundle identifier is read back out of the app that was just built, rather
# than hardcoded here. That matters: the tracked default identifier and a
# personal one from Config/Local.xcconfig differ, and launching a hardcoded
# identifier after installing a different one silently starts the *previous*
# install — a build that looks deployed but isn't.
#
# Needs APPLE_TV_DEVICE_ID in Config/local.env (see Config/local.env.example)
# or in the environment. Signing needs a DEVELOPMENT_TEAM, which comes from
# Config/Local.xcconfig.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

env_file="Config/local.env"
device_id="${APPLE_TV_DEVICE_ID:-}"
if [[ -z "$device_id" && -f "$env_file" ]]; then
    device_id="$(sed -n 's/^[[:space:]]*APPLE_TV_DEVICE_ID[[:space:]]*=[[:space:]]*//p' "$env_file" | head -n1)"
    device_id="${device_id%\"}"
    device_id="${device_id#\"}"
fi

if [[ -z "$device_id" ]]; then
    echo "deploy: no APPLE_TV_DEVICE_ID (set it in $env_file or the environment)" >&2
    echo "deploy: list devices with: xcrun devicectl list devices" >&2
    exit 1
fi

if [[ ! -f Config/Local.xcconfig ]]; then
    echo "deploy: Config/Local.xcconfig is missing — a device build needs DEVELOPMENT_TEAM." >&2
    echo "deploy: see Config/Public.xcconfig for the settings it overrides." >&2
    exit 1
fi

./scripts/bootstrap.sh

app_path="build/Build/Products/Debug-appletvos/RommpleTV.app"

xcodebuild -project RommpleTV.xcodeproj -scheme RommpleTV -configuration Debug \
    -destination "platform=tvOS,id=$device_id" -derivedDataPath build \
    -allowProvisioningUpdates build

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
if [[ -z "$bundle_id" ]]; then
    echo "deploy: could not read the built app's bundle identifier" >&2
    exit 1
fi

xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" "$bundle_id"

echo "deploy: launched $bundle_id"

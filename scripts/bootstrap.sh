#!/usr/bin/env bash
# Prepares the working tree for a build: generates the local config, then
# regenerates the Xcode project from project.yml.
#
# Run this instead of calling `xcodegen generate` directly. XcodeGen globs the
# App directory when it generates, so App/LocalConfig.generated.swift has to
# exist first or it will be missing from the project and the build will fail to
# compile.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

./scripts/gen-local-config.sh
xcodegen generate

echo "bootstrap: project regenerated"

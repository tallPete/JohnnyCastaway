#!/usr/bin/env bash
#
# ci.sh — run `swift test` across all SwiftPM packages.
#
# This is the Phase 0 verification step: every package must build, every
# test target must compile, and every test must pass. Initially that
# means each package's "skeleton" tests pass; in later phases this
# expands to the parser, engine, renderer, and debug-overlay test
# suites.
#
# Apps/ targets (.xcodeproj) are deliberately not built here — they are
# local-only Xcode projects added in Phases 5 and 6. CI lives at the
# package layer.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

readonly PACKAGES=(
    "Packages/JohnnyResources"
    "Packages/JohnnyEngine"
    "Packages/JohnnyMetalRenderer"
    "Packages/JohnnyDebug"
)

EXIT=0

for pkg in "${PACKAGES[@]}"; do
    echo
    echo "=========================================="
    echo "  swift test — $pkg"
    echo "=========================================="
    if swift test --package-path "$pkg"; then
        echo "PASS: $pkg"
    else
        echo "FAIL: $pkg"
        EXIT=1
    fi
done

echo
if [[ $EXIT -eq 0 ]]; then
    echo "All packages green."
else
    echo "One or more packages failed; see output above."
fi

exit $EXIT

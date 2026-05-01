#!/bin/bash
# build-saver.sh
#
# Build the JohnnyScreenSaver.saver bundle.
#
# Steps:
#   1. swift build -c release  (produces libJohnnyScreenSaver.dylib)
#   2. Assemble JohnnyScreenSaver.saver/Contents/{MacOS,Resources}/
#   3. Copy the binary, Info.plist, metallib
#
# Flags:
#   --debug     Build configuration debug (default: release)
#   --install   Copy to ~/Library/Screen Savers/ after building
#   --reload    With --install, prompt SystemSettings to reload
#
# Output: ./build/JohnnyScreenSaver.saver

set -euo pipefail

CONFIG="release"
INSTALL=0
RELOAD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)   CONFIG="debug";   shift ;;
        --install) INSTALL=1;        shift ;;
        --reload)  RELOAD=1;         shift ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

# Resolve script-dir-relative paths so the script works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"     # Apps/JohnnyScreenSaver
BUILD_DIR="$PKG_DIR/build"
SAVER_NAME="JohnnyScreenSaver"
SAVER_BUNDLE="$BUILD_DIR/$SAVER_NAME.saver"

echo "==> Building $SAVER_NAME ($CONFIG)…"
cd "$PKG_DIR"
swift build -c "$CONFIG"

DYLIB="$PKG_DIR/.build/$CONFIG/lib${SAVER_NAME}.dylib"
if [[ ! -f "$DYLIB" ]]; then
    echo "Build failed: $DYLIB not found" >&2
    exit 1
fi

echo "==> Assembling bundle…"
rm -rf "$SAVER_BUNDLE"
mkdir -p "$SAVER_BUNDLE/Contents/MacOS"
mkdir -p "$SAVER_BUNDLE/Contents/Resources"

# The Mach-O executable, named to match CFBundleExecutable in Info.plist.
cp "$DYLIB" "$SAVER_BUNDLE/Contents/MacOS/$SAVER_NAME"

# Info.plist
cp "$PKG_DIR/Resources/Info.plist" "$SAVER_BUNDLE/Contents/Info.plist"

# Renderer's compiled Metal library, if present.
METALLIB_CANDIDATES=(
    "$PKG_DIR/.build/$CONFIG/JohnnyMetalRenderer_JohnnyMetalRenderer.bundle/Contents/Resources/default.metallib"
    "$PKG_DIR/.build/$CONFIG/JohnnyMetalRenderer_JohnnyMetalRenderer.bundle/default.metallib"
)
for cand in "${METALLIB_CANDIDATES[@]}"; do
    if [[ -f "$cand" ]]; then
        cp "$cand" "$SAVER_BUNDLE/Contents/Resources/"
        echo "    metallib: $cand"
        break
    fi
done

# Sanity: require the principal class to be present in the binary.
if ! nm -gU "$SAVER_BUNDLE/Contents/MacOS/$SAVER_NAME" 2>/dev/null \
        | grep -q "_OBJC_CLASS_\$_JohnnyScreenSaverView"; then
    echo "WARNING: principal class _OBJC_CLASS_\$_JohnnyScreenSaverView not exported" >&2
    echo "  legacyScreenSaver may fail to instantiate the view." >&2
fi

echo "==> Signing bundle (ad-hoc)…"
# Strip any Finder metadata / resource forks first — codesign refuses to
# seal a bundle that has them.  Then re-sign the whole bundle so that:
#   • The identifier becomes nz.petesmith.JohnnyScreenSaver (from Info.plist)
#   • Info.plist is bound into the CodeDirectory
#   • Sealed Resources are created
# Without this step the linker leaves only an adhoc,linker-signed stub on
# the Mach-O, which does NOT bind Info.plist — System Settings never matches
# the bundle to its configure-sheet entry.
xattr -cr "$SAVER_BUNDLE"
codesign --force --deep --sign - "$SAVER_BUNDLE"
codesign --verify --verbose "$SAVER_BUNDLE"

echo "==> Built: $SAVER_BUNDLE"

if [[ $INSTALL -eq 1 ]]; then
    INSTALL_DIR="$HOME/Library/Screen Savers"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$SAVER_NAME.saver"
    cp -R "$SAVER_BUNDLE" "$INSTALL_DIR/"
    # Strip any xattrs cp -R may have added to the installed copy.
    xattr -cr "$INSTALL_DIR/$SAVER_NAME.saver"
    echo "==> Installed: $INSTALL_DIR/$SAVER_NAME.saver"

    if [[ $RELOAD -eq 1 ]]; then
        # Kill the legacyScreenSaver process so System Settings re-loads
        # the saver fresh on next preview/activation.
        killall legacyScreenSaver 2>/dev/null || true
        echo "==> Killed legacyScreenSaver (will respawn on demand)"
    fi
fi

#!/bin/sh
# s&box setup for Linux and macOS (Windows: Setup.bat).
# Downloads the prebuilt engine artifacts, builds the managed engine, shaders and
# content, and installs git hooks that keep the artifacts current after a pull,
# rebase or branch switch. Pass --verbose for full build output.
#
# On macOS this branch also builds and installs the KosmicKrisp Vulkan driver it
# was measured against - see the macOS section of README.md. That needs a Mesa
# toolchain (brew install meson ninja cmake pkg-config rust; cargo install
# bindgen-cli). Use --skip-driver to keep the bundled driver instead.
set -e
cd -- "$(dirname -- "$0")"

# --- macOS driver ------------------------------------------------------------
# The driver commit this branch's numbers were measured against. Its history is
# UserDerezzed/mesa-kosmickrisp@macos-optimized.
KK_REPO="https://github.com/UserDerezzed/mesa-kosmickrisp.git"
KK_REF="5e039278bcb9b199e85ee45821926452fbfe3c79"
KK_DIR=".kosmickrisp"
DRIVER_DEST="game/bin/osxarm64/libvulkan_kosmickrisp.dylib"

DO_ENGINE=1
DO_DRIVER=1
CLEAN_DRIVER=0
BOOTSTRAP_ARGS=""

# Only macOS has a driver to build; elsewhere this script is upstream's.
[ "$(uname -s)" = "Darwin" ] || DO_DRIVER=0

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-driver)  DO_DRIVER=0 ;;
        --driver-only)  DO_ENGINE=0 ;;
        --clean-driver) CLEAN_DRIVER=1 ;;
        --driver-ref)
            [ -n "${2:-}" ] || { echo "--driver-ref needs a value." >&2; exit 1; }
            KK_REF="$2"; shift ;;
        *) BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS $1" ;;
    esac
    shift
done
# -----------------------------------------------------------------------------

# Pick a dotnet that actually has an SDK 10+, rather than the first on PATH:
# Homebrew's dotnet installs into its own root, commonly reports no SDKs at all,
# and shadows the official installer's ~/.dotnet.
DOTNET=""
for candidate in "${DOTNET_ROOT:-}/dotnet" "$(command -v dotnet || true)" \
                 "$HOME/.dotnet/dotnet" /usr/local/share/dotnet/dotnet \
                 /opt/homebrew/share/dotnet/dotnet; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    major=$("$candidate" --list-sdks 2>/dev/null | awk '{print $1}' | cut -d. -f1 \
            | grep -E '^[0-9]+$' | sort -rn | head -1)
    if [ -n "$major" ] && [ "$major" -ge 10 ]; then DOTNET="$candidate"; break; fi
done

if [ -z "$DOTNET" ]; then
    echo "The .NET 10 SDK is required but no 'dotnet' with an SDK 10 or newer was found."
    echo "Install it from https://dotnet.microsoft.com/download and rerun ./Setup.sh."
    echo "If you have it somewhere unusual, set DOTNET_ROOT to its install directory."
    exit 1
fi

# The build tool shells out to a bare `dotnet restore`, so the choice above has
# to reach child processes too, not just this script.
DOTNET_DIR=$(dirname -- "$DOTNET")
DOTNET_ROOT="$DOTNET_DIR"
PATH="$DOTNET_DIR:$PATH"
export DOTNET_ROOT PATH

if [ "$DO_ENGINE" = 1 ]; then
    # shellcheck disable=SC2086 # BOOTSTRAP_ARGS is a list of plain flags.
    "$DOTNET" run --verbosity quiet --project ./engine/Tools/SboxBuild/SboxBuild.csproj -- bootstrap $BOOTSTRAP_ARGS
fi

[ "$DO_DRIVER" = 1 ] || exit 0

# --- KosmicKrisp driver ------------------------------------------------------
# After the engine on purpose: bootstrap downloads the artifacts, which include
# Facepunch's bundled driver and would overwrite ours.

if [ "$(uname -m)" != "arm64" ]; then
    echo "Skipping the driver: it is Apple Silicon only."
    exit 0
fi

missing=""
for tool in git meson ninja cmake pkg-config bindgen cargo; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo
    echo "Cannot build the KosmicKrisp driver, missing:$missing"
    echo
    echo "  brew install meson ninja cmake pkg-config rust"
    echo "  cargo install bindgen-cli"
    echo
    echo "Or rerun with --skip-driver to use the bundled driver."
    exit 1
fi

echo
echo "==> KosmicKrisp driver"

if [ ! -d "$KK_DIR/src/.git" ]; then
    echo "    cloning $KK_REPO"
    git clone --filter=blob:none "$KK_REPO" "$KK_DIR/src"
fi
git -C "$KK_DIR/src" fetch --quiet origin "$KK_REF" 2>/dev/null \
    || git -C "$KK_DIR/src" fetch --quiet --tags origin
git -C "$KK_DIR/src" checkout --quiet --detach "$KK_REF"
echo "    at $(git -C "$KK_DIR/src" rev-parse --short HEAD) - $(git -C "$KK_DIR/src" log -1 --format=%s)"

[ "$CLEAN_DRIVER" = 1 ] && rm -rf "$KK_DIR/build"
if [ ! -f "$KK_DIR/build/build.ninja" ]; then
    echo "    configuring (the first build takes a few minutes)"
    meson setup "$KK_DIR/build" "$KK_DIR/src" \
        --buildtype=release \
        --prefer-static \
        -Dplatforms=macos \
        -Dvulkan-drivers=kosmickrisp \
        -Dgallium-drivers= \
        -Dopengl=false \
        -Dzstd=disabled \
        -Dshader-cache=enabled
fi

ninja -C "$KK_DIR/build" src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib

built="$KK_DIR/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"
[ -f "$built" ] || { echo "Driver build reported success but $built is missing." >&2; exit 1; }

# Keep Facepunch's driver the first time we replace it, so testers can A/B.
if [ -f "$DRIVER_DEST" ] && [ ! -f "$DRIVER_DEST.bundled" ]; then
    cp "$DRIVER_DEST" "$DRIVER_DEST.bundled"
    echo "    kept the bundled driver as $DRIVER_DEST.bundled"
fi
mkdir -p "$(dirname "$DRIVER_DEST")"
cp "$built" "$DRIVER_DEST"
# Built locally, so unsigned; clear quarantine in case it was moved between Macs.
xattr -d com.apple.quarantine "$DRIVER_DEST" 2>/dev/null || true

echo "    installed $DRIVER_DEST"
echo
echo "Note: anything that re-downloads artifacts restores the bundled driver."
echo "      Put this one back with ./Setup.sh --driver-only"

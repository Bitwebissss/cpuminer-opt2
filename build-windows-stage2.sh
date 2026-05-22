#!/bin/bash
#
# build-windows-stage2.sh
# Called by build-windows-all.bat via MSYS2 UCRT64 bash.
# Builds fully static cpuminer.exe variants (except libmm_gpu_gate.dll for GPU)
# with automatic copying of required DLLs (only those that are not static).
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Resolve project directory
if [ -n "$1" ] && [ "$1" != "--no-gpu" ]; then
    PROJECT_DIR="$1"
else
    PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# GPU gate directory
if [ -n "$CPUMINER_GPU_GATE_WIN" ]; then
    GPU_GATE_DIR=$(cygpath -u "$CPUMINER_GPU_GATE_WIN")
else
    GPU_GATE_DIR="$PROJECT_DIR/algo/argon2d/argon2-gpu/build_vs/Release"
fi

NO_GPU=0
for arg in "$@"; do
    [ "$arg" = "--no-gpu" ] && NO_GPU=1
done

RELEASE_GPU="$PROJECT_DIR/release-windows/gpu"
RELEASE_NOGPU="$PROJECT_DIR/release-windows/nogpu"

DEFAULT_CFLAGS="-maes -O3 -Wall"
DEFAULT_CFLAGS_OLD="-O3 -Wall"

info "Project dir : $PROJECT_DIR"
info "GPU gate dir: $GPU_GATE_DIR"
info "No-GPU only : $NO_GPU"

export PATH="/ucrt64/bin:/usr/bin:$PATH"

# Install required MSYS2 packages (static libs are included in regular packages)
info "Checking MSYS2 packages..."
REQUIRED_PKGS=(
    mingw-w64-ucrt-x86_64-gcc
    mingw-w64-ucrt-x86_64-curl
    mingw-w64-ucrt-x86_64-openssl
    mingw-w64-ucrt-x86_64-jansson
    mingw-w64-ucrt-x86_64-gmp
    mingw-w64-ucrt-x86_64-opencl-icd
    mingw-w64-ucrt-x86_64-opencl-headers
    autoconf automake libtool pkg-config zip
)
MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    pacman -Q "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Installing missing packages: ${MISSING[*]}"
    pacman -S --noconfirm "${MISSING[@]}" || error "Failed to install packages"
fi
info "Packages OK"

# Validate GPU gate
if [ "$NO_GPU" = "0" ]; then
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll" ]   || error "libmm_gpu_gate.dll not found in $GPU_GATE_DIR"
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll.a" ] || error "libmm_gpu_gate.dll.a not found in $GPU_GATE_DIR"
fi

# Configure arguments
CONF_BASE="--with-curl=/ucrt64 --host=x86_64-w64-mingw32"
CONF_GPU="--enable-gpu --with-mm-gpu-gate=$GPU_GATE_DIR $CONF_BASE"
CONF_NOGPU="$CONF_BASE"

# Export environment for static linking of curl/openssl
export CPPFLAGS="-I/ucrt64/include"
export PKG_CONFIG_PATH="/ucrt64/lib/pkgconfig"
export LDFLAGS="-L/ucrt64/lib -static-libgcc -static-libstdc++"

# Get static library flags for curl and openssl
STATIC_LIBS=$(pkg-config --static --libs libcurl openssl 2>/dev/null || echo "-lcurl -lssl -lcrypto -lz")

cd "$PROJECT_DIR"
info "Running autogen.sh..."
./autogen.sh

# Build function (pass STATIC_LIBS and -DCURL_STATICLIB)
build_variant() {
    local cflags="$1"
    local name="$2"
    local conf_args="$3"
    local out_dir="$4"

    info "  Building $name..."
    make clean 2>/dev/null || true
    rm -f config.status
    export CFLAGS="$cflags -DCURL_STATICLIB"
    # Pass static library flags directly to configure
    ./configure $conf_args LIBS="$STATIC_LIBS" 2>&1 | grep -E "(checking|error|warning)" | tail -5 || true
    make -j$(nproc) 2>&1 | tail -3
    strip -s cpuminer.exe
    cp cpuminer.exe "$out_dir/$name"
    info "  → $name done"
}

# Build GPU variants (static exe + dynamic libmm_gpu_gate)
if [ "$NO_GPU" = "0" ]; then
    info ""
    info "========================================"
    info "  Building GPU variants (8 CPU archs)"
    info "========================================"
    mkdir -p "$RELEASE_GPU"

    build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes.exe" "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512.exe"          "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes.exe"   "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha.exe"        "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2.exe"            "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx.exe"             "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42.exe"       "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2.exe"            "$CONF_GPU" "$RELEASE_GPU"
fi

# Build no-GPU variants (fully static)
info ""
info "========================================"
info "  Building no-GPU variants (8 CPU archs)"
info "========================================"
mkdir -p "$RELEASE_NOGPU"

build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes.exe" "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512.exe"          "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes.exe"   "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha.exe"        "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2.exe"            "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx.exe"             "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42.exe"       "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2.exe"            "$CONF_NOGPU" "$RELEASE_NOGPU"

# Copy runtime DLLs (original logic, preserved)
info ""
info "Copying runtime DLLs..."

if [ "$NO_GPU" = "0" ]; then
    cp "$GPU_GATE_DIR/libmm_gpu_gate.dll" "$RELEASE_GPU/"
    info "  Copied: libmm_gpu_gate.dll"

    mkdir -p "$RELEASE_GPU/data/kernels"
    cp "$PROJECT_DIR/algo/argon2d/argon2-gpu/data/kernels/argon2_kernel.cl" "$RELEASE_GPU/data/kernels/"
    info "  Copied: argon2_kernel.cl"

    (cd "$RELEASE_GPU" && ldd cpuminer-sse2.exe libmm_gpu_gate.dll 2>/dev/null \
        | grep "ucrt64" \
        | awk '{print $3}' \
        | sort -u \
        | xargs -I{} cp {} .)
    info "  Runtime DLLs copied to $RELEASE_GPU"
fi

(cd "$RELEASE_NOGPU" && ldd cpuminer-sse2.exe 2>/dev/null \
    | grep "ucrt64" \
    | awk '{print $3}' \
    | sort -u \
    | xargs -I{} cp {} .)
info "  Runtime DLLs copied to $RELEASE_NOGPU"

# Copy documentation
info "Copying documentation..."
for f in README.txt README.md RELEASE_NOTES verthash-help.txt; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        [ "$NO_GPU" = "0" ] && cp "$PROJECT_DIR/$f" "$RELEASE_GPU/"   || true
        cp "$PROJECT_DIR/$f" "$RELEASE_NOGPU/" || true
    fi
done

# Generate SHA-256 hashes
info "Generating SHA-256 hashes..."
if [ "$NO_GPU" = "0" ]; then
    (cd "$RELEASE_GPU"   && sha256sum * 2>/dev/null > hashes.txt || true)
fi
(cd "$RELEASE_NOGPU" && sha256sum * 2>/dev/null > hashes.txt || true)

# Create zip archives
info "Creating zip archives..."
cd "$PROJECT_DIR"

if [ "$NO_GPU" = "0" ]; then
    rm -f cpuminer-windows-gpu.zip
    zip -r cpuminer-windows-gpu.zip release-windows/gpu/
    info "  Created: cpuminer-windows-gpu.zip"
fi

rm -f cpuminer-windows-nogpu.zip
zip -r cpuminer-windows-nogpu.zip release-windows/nogpu/
info "  Created: cpuminer-windows-nogpu.zip"

# Summary
info ""
info "========================================"
info "  Stage 2 complete."
[ "$NO_GPU" = "0" ] && info "  GPU archive   : cpuminer-windows-gpu.zip"
info "  No-GPU archive: cpuminer-windows-nogpu.zip"
info ""
info "  CPU arch reference:"
info "    avx512-sha-vaes  Intel Icelake, Rocketlake"
info "    avx512           Intel Skylake-X, Cascadelake"
info "    avx2-sha-vaes    Intel Alderlake, AMD Zen3+"
info "    avx2-sha         AMD Zen1 / Zen2"
info "    avx2             Intel Haswell to Cometlake"
info "    avx              Intel Sandybridge / Ivybridge"
info "    aes-sse42        Intel Westmere"
info "    sse2             Generic x64 fallback"
info "========================================"

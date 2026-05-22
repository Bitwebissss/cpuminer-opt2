#!/bin/bash
#
# build-windows-stage2.sh
# Called by build-windows-all.bat via MSYS2 UCRT64 bash.
# Can also be run manually inside MSYS2 UCRT64 terminal:
#
#   # Without GPU (CPU-only, all arch variants):
#   bash build-windows-stage2.sh --no-gpu
#
#   # With GPU (requires Stage 1 / libmm_gpu_gate.dll to exist first):
#   CPUMINER_GPU_GATE_WIN="C:/cpuminer-opt3/algo/argon2d/argon2-gpu/build_vs/Release" \
#   bash build-windows-stage2.sh
#
# Builds: SSE2, AES+SSE4.2, AVX, AVX2, AVX2+SHA, AVX2+SHA+VAES, AVX512, AVX512+SHA+VAES
# Output: cpuminer-windows-gpu.zip (GPU) and/or cpuminer-windows.zip (no-GPU) in project root

set -e

# ============================================================
#  QUICK TEST MODE (build only one variant)
#  Set QUICK_TEST=1 and adjust QUICK_VARIANT if needed
# ============================================================
QUICK_TEST=0
QUICK_VARIANT="cpuminer-sse2.exe"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
found() { echo -e "${CYAN}[FOUND]${NC} $*"; }

# ============================================================
#  RESOLVE PROJECT DIR
# ============================================================
if [ -n "$1" ] && [ "$1" != "--no-gpu" ]; then
    PROJECT_DIR="$1"
else
    PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

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
[ "$QUICK_TEST" = "1" ] && info "QUICK TEST MODE: building only $QUICK_VARIANT"

# ============================================================
#  ENSURE UCRT64 TOOLCHAIN IN PATH
# ============================================================
export PATH="/ucrt64/bin:/usr/bin:$PATH"

# ============================================================
#  CHECK REQUIRED MSYS2 PACKAGES
# ============================================================
info "Checking MSYS2 packages..."
REQUIRED_PKGS=(
    mingw-w64-ucrt-x86_64-gcc
    mingw-w64-ucrt-x86_64-curl
    mingw-w64-ucrt-x86_64-jansson
    mingw-w64-ucrt-x86_64-gmp
    mingw-w64-ucrt-x86_64-openssl
    mingw-w64-ucrt-x86_64-opencl-icd
    mingw-w64-ucrt-x86_64-opencl-headers
    autoconf
    automake
    libtool
    pkg-config
    zip
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

# ============================================================
#  VALIDATE GPU GATE FILES EXIST BEFORE STARTING ANYTHING
# ============================================================
if [ "$NO_GPU" = "0" ]; then
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll" ]   || error "libmm_gpu_gate.dll not found in $GPU_GATE_DIR — run Stage 1 first"
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll.a" ] || error "libmm_gpu_gate.dll.a not found in $GPU_GATE_DIR — run Stage 1 first"
    [ -f "$PROJECT_DIR/algo/argon2d/argon2-gpu/data/kernels/argon2_kernel.cl" ] \
        || error "argon2_kernel.cl not found — check your source tree"
fi

# ============================================================
#  CONFIGURE ARGS
# ============================================================
CONF_BASE="--with-curl=/ucrt64 --host=x86_64-w64-mingw32 LDFLAGS=-L/ucrt64/lib CPPFLAGS=-I/ucrt64/include"
CONF_GPU="--enable-gpu --with-mm-gpu-gate=$GPU_GATE_DIR $CONF_BASE"
CONF_NOGPU="$CONF_BASE"

# ============================================================
#  REGENERATE CONFIGURE
# ============================================================
cd "$PROJECT_DIR"
info "Running autogen.sh..."
./autogen.sh

# ============================================================
#  verify_and_copy_dlls  REL_DIR
#
#  Called after EVERY exe build.
#
#  For each runtime DLL the current folder contents (exe+dll) need:
#    - Already in REL_DIR → [FOUND] SKIP COPY  (guards against antivirus
#      or manual deletion between builds — if it was there and now isn't,
#      the ldd output will still list it and the copy branch below fires)
#    - Not in REL_DIR, exists in toolchain → copy it, then re-scan
#      (transitive deps: newly copied DLL may pull in more)
#    - Not in REL_DIR, missing from toolchain → [ERROR] stop immediately
#
#  This means a DLL deleted mid-build (antivirus, etc.) is caught on the
#  very next exe, not at packaging time.
# ============================================================
verify_and_copy_dlls() {
    local rel_dir="$1"
    local changed=1

    while [ "$changed" = "1" ]; do
        changed=0

        local targets
        targets=$(find "$rel_dir" -maxdepth 1 \( -name "*.exe" -o -name "*.dll" \) 2>/dev/null)
        [ -z "$targets" ] && break

        local dlls
        dlls=$(ldd $targets 2>/dev/null \
            | grep -i "ucrt64\|mingw" \
            | awk '{print $3}' \
            | grep "^/" \
            | sort -u)

        for dll in $dlls; do
            local dllname
            dllname=$(basename "$dll")

            if [ -f "$rel_dir/$dllname" ]; then
                found "    $dllname — SKIP COPY"
                continue
            fi

            # Not in release dir — must copy now or stop
            [ -f "$dll" ] || error "Required DLL missing from toolchain: $dll — cannot continue"

            cp "$dll" "$rel_dir/$dllname" \
                || error "Copy failed: $dll → $rel_dir/ — cannot continue"
            info "    Copied: $dllname"
            changed=1   # re-scan: this DLL may have its own deps
        done
    done
}

# ============================================================
#  verify_and_copy_gpu_files  REL_DIR
#
#  Called after EVERY GPU exe build (same fail-fast logic).
#  GPU-specific files are not runtime DLLs so ldd won't find them —
#  they are checked and copied explicitly here.
# ============================================================
verify_and_copy_gpu_files() {
    local rel_dir="$1"

    # libmm_gpu_gate.dll
    if [ -f "$rel_dir/libmm_gpu_gate.dll" ]; then
        found "    libmm_gpu_gate.dll — SKIP COPY"
    else
        cp "$GPU_GATE_DIR/libmm_gpu_gate.dll" "$rel_dir/" \
            || error "Copy failed: libmm_gpu_gate.dll — cannot continue"
        info "    Copied: libmm_gpu_gate.dll"
    fi

    # argon2_kernel.cl
    local kernel_dst="$rel_dir/data/kernels"
    mkdir -p "$kernel_dst"
    if [ -f "$kernel_dst/argon2_kernel.cl" ]; then
        found "    argon2_kernel.cl — SKIP COPY"
    else
        cp "$PROJECT_DIR/algo/argon2d/argon2-gpu/data/kernels/argon2_kernel.cl" "$kernel_dst/" \
            || error "Copy failed: argon2_kernel.cl — cannot continue"
        info "    Copied: data/kernels/argon2_kernel.cl"
    fi
}

# ============================================================
#  build_variant  CFLAGS  NAME  CONF_ARGS  OUT_DIR  [gpu]
#
#  1. Build the exe
#  2. Immediately verify + copy runtime DLLs — stop on first failure
#  3. If "gpu": verify + copy GPU-specific files — stop on first failure
#  4. Only then return — next variant build can start
# ============================================================
build_variant() {
    local cflags="$1"
    local name="$2"
    local conf_args="$3"
    local out_dir="$4"
    local extra="${5:-}"

    if [ "$QUICK_TEST" = "1" ] && [ "$name" != "$QUICK_VARIANT" ]; then
        info "  Skipping $name (quick test mode)"
        return 0
    fi

    info ""
    info "  ── Building $name ──"
    make clean 2>/dev/null || true
    rm -f config.status
    export CFLAGS="$cflags"
    ./configure $conf_args 2>&1 | grep -E "(checking|error|warning)" | tail -5 || true
    make -j$(nproc) 2>&1 | tail -3
    strip -s cpuminer.exe
    cp cpuminer.exe "$out_dir/$name"
    info "  ✓ $name compiled"

    info "  Verifying runtime DLLs for $name..."
    verify_and_copy_dlls "$out_dir"

    if [ "$extra" = "gpu" ]; then
        info "  Verifying GPU-specific files for $name..."
        verify_and_copy_gpu_files "$out_dir"
    fi

    info "  ✓ $name — all dependencies OK, continuing"
}

# ============================================================
#  GPU VARIANTS
# ============================================================
if [ "$NO_GPU" = "0" ]; then
    info ""
    info "========================================"
    info "  Building GPU variants (8 CPU archs)"
    info "========================================"
    mkdir -p "$RELEASE_GPU"

    build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes.exe" "$CONF_GPU" "$RELEASE_GPU" "gpu"
    build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512.exe"          "$CONF_GPU" "$RELEASE_GPU" "gpu"
    build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes.exe"   "$CONF_GPU" "$RELEASE_GPU" "gpu"
    build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha.exe"        "$CONF_GPU" "$RELEASE_GPU" "gpu"
    build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2.exe"            "$CONF_GPU" "$RELEASE_GPU" "gpu"
    build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx.exe"             "$CONF_GPU" "$RELEASE_GPU" "gpu"
    build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42.exe"       "$CONF_GPU" "$RELEASE_GPU" "gpu"
    build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2.exe"            "$CONF_GPU" "$RELEASE_GPU" "gpu"
fi

# ============================================================
#  NO-GPU VARIANTS
# ============================================================
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

# ============================================================
#  DOCUMENTATION
# ============================================================
info "Copying documentation..."
for f in README.txt README.md RELEASE_NOTES verthash-help.txt; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        [ "$NO_GPU" = "0" ] && cp "$PROJECT_DIR/$f" "$RELEASE_GPU/"  || true
        cp "$PROJECT_DIR/$f" "$RELEASE_NOGPU/" || true
    fi
done

# ============================================================
#  HASHES
# ============================================================
info "Generating SHA-256 hashes..."
if [ "$NO_GPU" = "0" ]; then
    (cd "$RELEASE_GPU"   && sha256sum *.exe *.dll 2>/dev/null > hashes.txt || true)
fi
(cd "$RELEASE_NOGPU" && sha256sum *.exe *.dll 2>/dev/null > hashes.txt || true)

# ============================================================
#  ZIP — contents of folder go directly into zip root (no subfolder)
# ============================================================
info "Creating zip archives..."

if [ "$NO_GPU" = "0" ]; then
    rm -f "$PROJECT_DIR/cpuminer-windows-gpu.zip"
    (cd "$RELEASE_GPU"   && zip -r "$PROJECT_DIR/cpuminer-windows-gpu.zip" .)
    info "  Created: cpuminer-windows-gpu.zip"
fi

rm -f "$PROJECT_DIR/cpuminer-windows.zip"
(cd "$RELEASE_NOGPU" && zip -r "$PROJECT_DIR/cpuminer-windows.zip" .)
info "  Created: cpuminer-windows.zip"

# ============================================================
#  SUMMARY
# ============================================================
info ""
info "========================================"
info "  Stage 2 complete."
[ "$NO_GPU" = "0" ] && info "  GPU archive   : cpuminer-windows-gpu.zip"
info "  No-GPU archive: cpuminer-windows.zip"
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

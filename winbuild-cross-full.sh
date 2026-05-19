#!/bin/bash
#
# Script for building Windows binaries release package using mingw.
# Builds all dependencies and creates release package with different CPU optimizations.

set -e  # Stop on error

mkdir -p $HOME/usr/lib

# Define variables
export HOME_DIR="$HOME"
export LOCAL_LIB="$HOME_DIR/usr/lib"
export MINGW_LIB="/usr/x86_64-w64-mingw32/lib"
export DEFAULT_CFLAGS="-maes -O3 -Wall"
export DEFAULT_CFLAGS_OLD="-O3 -Wall"

# Save the initial working directory
INITIAL_DIR="$(pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Starting build process...${NC}"

# Create directories
mkdir -p "$LOCAL_LIB"

# Function to detect package manager
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# Install required packages based on package manager
install_packages() {
    local pkg_manager=$(detect_pkg_manager)
    echo -e "${GREEN}Detected package manager: $pkg_manager${NC}"
    echo -e "${GREEN}Installing required packages...${NC}"
    
    case $pkg_manager in
        apt)
            sudo apt-get update
            sudo apt-get install -y build-essential automake autoconf pkg-config libssl-dev \
                libgmp-dev libcurl4-openssl-dev libjansson-dev mingw-w64 libz-mingw-w64-dev
            ;;
        dnf|yum)
            sudo $pkg_manager install -y gcc gcc-c++ make automake autoconf pkgconfig openssl-devel \
                gmp-devel libcurl-devel jansson-devel mingw64-gcc mingw64-zlib
            ;;
        pacman)
            sudo pacman -S --noconfirm base-devel automake autoconf pkg-config openssl \
                gmp curl jansson mingw-w64-gcc mingw-w64-zlib
            ;;
        zypper)
            sudo zypper install -y gcc gcc-c++ make automake autoconf pkg-config libopenssl-devel \
                gmp-devel libcurl-devel libjansson-devel mingw64-cross-gcc mingw64-zlib
            ;;
        *)
            echo -e "${RED}Unsupported package manager. Please install required packages manually.${NC}"
            echo "Required: build-essential, automake, autoconf, pkg-config, libssl-dev, libgmp-dev,"
            echo "          libcurl4-openssl-dev, libjansson-dev, mingw-w64, libz-mingw-w64-dev"
            exit 1
            ;;
    esac
}

# Auto-detect GCC_MINGW_LIB path
detect_gcc_mingw_lib() {
    local base="/usr/lib/gcc/x86_64-w64-mingw32"
    if [ -d "$base" ]; then
        # Find the highest version directory (e.g., 13-win32, 12-win32, 9.3-win32, 10-win32, etc.)
        local version_dir=$(ls -1 "$base" | grep -E '[0-9]+(\.[0-9]+)?-win32' | sort -V | tail -n1)
        if [ -n "$version_dir" ]; then
            echo "$base/$version_dir"
            return
        fi
    fi
    # Fallback to a common default
    echo "/usr/lib/gcc/x86_64-w64-mingw32/13-win32"
}

export GCC_MINGW_LIB=$(detect_gcc_mingw_lib)
echo -e "${GREEN}Using GCC_MINGW_LIB: $GCC_MINGW_LIB${NC}"

# Check if required files exist; if not, try alternative paths
copy_dll_if_exists() {
    local src="$1"
    local dst="$2"
    if [ -f "$src" ]; then
        cp "$src" "$dst"
        return 0
    else
        # Try alternative locations (e.g., Fedora places DLLs in sys-root)
        local alt_src="/usr/x86_64-w64-mingw32/sys-root/mingw/bin/$(basename "$src")"
        if [ -f "$alt_src" ]; then
            cp "$alt_src" "$dst"
            return 0
        fi
        echo -e "${RED}Warning: Cannot find $src${NC}"
        return 1
    fi
}

# Install packages
install_packages

# Build CURL
echo -e "${GREEN}Building CURL...${NC}"
cd "$LOCAL_LIB"
if [ ! -f "curl-7.68.0.tar.gz" ]; then
    wget https://github.com/curl/curl/releases/download/curl-7_68_0/curl-7.68.0.tar.gz
fi
tar xzf curl-7.68.0.tar.gz
cd curl-7.68.0

./configure --host=x86_64-w64-mingw32 \
    --with-winssl \
    --enable-shared \
    --disable-static \
    --prefix="$LOCAL_LIB/curl" \
    --without-zlib

make -j$(nproc)
make install

# Build GMP
echo -e "${GREEN}Building GMP...${NC}"
cd "$LOCAL_LIB"
if [ ! -f "gmp-6.2.0.tar.xz" ]; then
    wget https://gmplib.org/download/gmp/gmp-6.2.0.tar.xz
fi
tar xf gmp-6.2.0.tar.xz
cd gmp-6.2.0

./configure --host=x86_64-w64-mingw32 \
    --enable-static \
    --disable-shared \
    --prefix="$LOCAL_LIB/gmp"

make -j$(nproc)
make install

# Set up environment for cpuminer build
export PATH="$LOCAL_LIB/curl/bin:$PATH"
export PKG_CONFIG_PATH="$LOCAL_LIB/curl/lib/pkgconfig:$PKG_CONFIG_PATH"
export LDFLAGS="-L$LOCAL_LIB/curl/lib -L$LOCAL_LIB/gmp/lib"
export CPPFLAGS="-I$LOCAL_LIB/curl/include -I$LOCAL_LIB/gmp/include"
export CONFIGURE_ARGS="--with-curl=$LOCAL_LIB/curl --host=x86_64-w64-mingw32"

# Return to the initial working directory
cd "$INITIAL_DIR"

# Create release directory and copy DLLs
echo -e "${GREEN}Creating release directory and copying DLLs...${NC}"
rm -rf release
mkdir -p release

# Copy documentation
cp README.txt release/ 2>/dev/null || echo "README.txt not found"
cp README.md release/ 2>/dev/null || echo "README.md not found"
cp RELEASE_NOTES release/ 2>/dev/null || echo "RELEASE_NOTES not found"
cp verthash-help.txt release/ 2>/dev/null || echo "verthash-help.txt not found"

# Copy required DLLs (with fallback paths)
copy_dll_if_exists "$MINGW_LIB/zlib1.dll" "release/"
copy_dll_if_exists "$MINGW_LIB/libwinpthread-1.dll" "release/"
copy_dll_if_exists "$GCC_MINGW_LIB/libstdc++-6.dll" "release/"
copy_dll_if_exists "$GCC_MINGW_LIB/libgcc_s_seh-1.dll" "release/"

# libcurl-4.dll might be in $LOCAL_LIB/curl/bin or .libs
if [ -f "$LOCAL_LIB/curl/bin/libcurl-4.dll" ]; then
    cp "$LOCAL_LIB/curl/bin/libcurl-4.dll" release/
elif [ -f "$LOCAL_LIB/curl/lib/.libs/libcurl-4.dll" ]; then
    cp "$LOCAL_LIB/curl/lib/.libs/libcurl-4.dll" release/
else
    echo -e "${RED}Warning: libcurl-4.dll not found${NC}"
fi

# Link GMP header
ln -sf "$LOCAL_LIB/gmp/include/gmp.h" ./gmp.h

# Function to build a specific version
build_version() {
    local cflags="$1"
    local output_name="$2"
    
    echo -e "${GREEN}Building $output_name...${NC}"
    make clean || echo "clean"
    rm -f config.status
    CFLAGS="$cflags" ./configure $CONFIGURE_ARGS
    make -j$(nproc)
    strip -s cpuminer.exe
    mv cpuminer.exe "release/$output_name"
}

# Generate build files
./autogen.sh

# Build all versions
build_version "-march=icelake-client $DEFAULT_CFLAGS" "cpuminer-avx512-sha-vaes.exe"
build_version "-march=skylake-avx512 $DEFAULT_CFLAGS" "cpuminer-avx512.exe"
build_version "-mavx2 -msha -mvaes $DEFAULT_CFLAGS" "cpuminer-avx2-sha-vaes.exe"
build_version "-march=znver1 $DEFAULT_CFLAGS" "cpuminer-avx2-sha.exe"
build_version "-march=core-avx2 $DEFAULT_CFLAGS" "cpuminer-avx2.exe"
build_version "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx.exe"
build_version "-march=westmere -maes $DEFAULT_CFLAGS_OLD" "cpuminer-aes-sse42.exe"
build_version "-msse2 $DEFAULT_CFLAGS_OLD" "cpuminer-sse2.exe"

# Generate hashes and save to file
echo -e "${GREEN}Generating hash sums...${NC}"
cd release
sha256sum * > hashes.txt
cat hashes.txt
cd "$INITIAL_DIR"

# Create release archive
echo -e "${GREEN}Creating release archive...${NC}"
zip -r cpuminer-windows-x64.zip release/

echo -e "${GREEN}Build complete! Release package created as cpuminer-windows-x64.zip${NC}"

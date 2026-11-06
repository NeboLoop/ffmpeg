#!/usr/bin/env bash
# Builds the ffmpeg + ffprobe that nebo-media runs (GPL v2 or later).
#
#   scripts/build-ffmpeg.sh <rust-target-triple>
#
# Writes vendor/<triple>/ffmpeg.gz, ffprobe.gz (what build.rs embeds) and
# BUILDINFO.txt (versions, configure line, license). Work happens in
# build/<triple>/; downloads are cached in build/downloads/.
#
# Every source is a pinned release tarball checked against its sha256. ffmpeg
# is configured with --enable-gpl and WITHOUT --enable-nonfree or
# --enable-version3, so the result is GPL v2 or later and redistributable.
# The script refuses to finish if the built binary says otherwise (see
# check_license); nothing nonfree (fdk-aac, CUDA SDK/NVCC) ever goes in.
# ffmpeg stays a separate program: nebo-media runs it, never links it.
#
# Video encoders:
#   H.264   x264 (GPL-2.0+), and the OS's own: VideoToolbox (macOS), Media
#           Foundation (Windows), NVIDIA NVENC (Linux x86_64, Windows)
#   HEVC    x265 (GPL-2.0+, cmake), built 8- and 10-bit in one library
#           (Main for SDR, Main 10 for HDR10, HLG and Dolby Vision 8.x);
#           VideoToolbox, Media Foundation, NVENC
#   AV1     SVT-AV1 (BSD-3-Clause-Clear + AOMedia Patent License 1.0, cmake);
#           decoded by dav1d (BSD-2-Clause, meson + ninja)
#   ProRes  prores_ks everywhere, VideoToolbox on macOS
#   VP9     libvpx (BSD-3-Clause), with Opus audio via libopus (BSD-3)
# Hardware decoding (H.264 and HEVC; ProRes too on macOS): VideoToolbox
# (macOS), D3D11VA (Windows), NVIDIA NVDEC (Linux x86_64, Windows).
# NVENC and NVDEC come through nv-codec-headers (MIT, header only: the driver
# is loaded at run time, nothing is linked). MP3 is libmp3lame (LGPL-2.0). AAC
# is ffmpeg's native encoder. Filters with libraries: zscale (zimg, WTFPL,
# autotools) for HDR to SDR, vidstabdetect/vidstabtransform (vid.stab,
# GPL-2.0+, cmake), rubberband (Rubber Band, GPL-2.0+, meson, built-in FFT
# and resampler).
#
# Supported triples, and where each one is built:
#   aarch64-apple-darwin       on an Apple-silicon Mac (native)
#   x86_64-apple-darwin        on any Mac (cross: -arch x86_64; needs nasm)
#   aarch64-unknown-linux-gnu  on Linux arm64 (native)
#   x86_64-unknown-linux-gnu   on Linux x86_64 (native; needs nasm)
#   x86_64-pc-windows-msvc     on Linux with mingw-w64 (cross), or in an
#   x86_64-pc-windows-gnu      MSYS2 MINGW64 shell on Windows (native)
#
# Environment:
#   JOBS        parallel make jobs (default: CPU count)
#   KEEP_BUILD  1 keeps build/<triple>/ after success (default: kept; it is
#               the cache CI restores, and it is git-ignored)
set -euo pipefail

TRIPLE="${1:-}"
if [[ -z "$TRIPLE" ]]; then
  echo "usage: $0 <rust-target-triple>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="$ROOT/build/downloads"
WORK="$ROOT/build/$TRIPLE"
SRC="$WORK/src"
PREFIX="$WORK/prefix"
OUT="$ROOT/vendor/$TRIPLE"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# ---- Pinned sources ---------------------------------------------------------
# name|version|url [url ...]|sha256
# A source with several urls (mirrors of one file) is tried in order until one
# gives the pinned sha256.
# x264 has no release tarballs and GitLab regenerates its archives with a new
# hash on every download, so it comes from Debian's .orig tarball of the same
# commit (the identical tree, unmodified): Debian's permanent snapshot, then
# the Ubuntu archive and Launchpad, which carry the same file.
# ffmpeg's sha256 was taken from a tarball whose .asc verified against the
# FFmpeg release signing key (FCF986EA15E6E293A5644F10B4322F04D67658D8).
# ffmpeg.org drops connections from the house runners now and then, so the
# same tarball also comes from Debian's pool (its .orig is the release
# tarball, unmodified), Alpine's distfiles and the OSUOSL mirror.
FFMPEG_VERSION=9.0.2
SOURCES=(
  "ffmpeg|$FFMPEG_VERSION|https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz https://deb.debian.org/debian/pool/main/f/ffmpeg/ffmpeg_$FFMPEG_VERSION.orig.tar.xz https://distfiles.alpinelinux.org/distfiles/edge/ffmpeg-$FFMPEG_VERSION.tar.xz https://ftp.osuosl.org/pub/blfs/conglomeration/ffmpeg/ffmpeg-$FFMPEG_VERSION.tar.xz|8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
  "lame|4.0|https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"
  "libvpx|1.17.0|https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz|1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"
  "opus|1.5.2|https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz|65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1"
  "x264|b35605ace3ddf7c1a5d67a2eb553f034aef41d55|https://snapshot.debian.org/archive/debian/20250915T203450Z/pool/main/x/x264/x264_0.165.3222%2Bgitb35605ac.orig.tar.gz https://archive.ubuntu.com/ubuntu/pool/universe/x/x264/x264_0.165.3222%2Bgitb35605ac.orig.tar.gz https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/x264/2:0.165.3222+gitb35605ac-3/x264_0.165.3222+gitb35605ac.orig.tar.gz|4672fb415c34bf16e2ed9cd43d1ab865158f586c7f1406d507f7f44516fb5ec8"
  "x265|4.2|https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.2.tar.gz|40b1ea0453e0309f0eba934e0ddf533f8f6295966679e8894e8f1c1c8d5e1210"
  "vidstab|1.1.2|https://github.com/georgmartius/vid.stab/archive/refs/tags/v1.1.2.tar.gz|96db34d48a9e3aa13736a48744b56dfb76731ac9bb5193c716de8534c9fd709d"
  "rubberband|4.0.0|https://breakfastquay.com/files/releases/rubberband-4.0.0.tar.bz2|af050313ee63bc18b35b2e064e5dce05b276aaf6d1aa2b8a82ced1fe2f8028e9"
  "dav1d|1.5.4|https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz|686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
  "svtav1|4.2.0|https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.gz|c7b13c4a84bd3751aa35fcc72be13e6875467e7c2216879251a486e5b1e4e740"
  "zimg|3.0.6|https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz|be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"
  "nvcodec|13.0.19.0|https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n13.0.19.0.tar.gz|86d15d1a7c0ac73a0eafdfc57bebfeba7da8264595bf531cf4d8db1c22940116"
  "zlib|1.3.2|https://zlib.net/fossils/zlib-1.3.2.tar.gz|bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
)

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

source_field() { # source_field <name> <index>
  local s
  for s in "${SOURCES[@]}"; do
    IFS='|' read -r n v u h <<<"$s"
    if [[ "$n" == "$1" ]]; then
      case "$2" in version) echo "$v";; url) echo "$u";; sha) echo "$h";; esac
      return
    fi
  done
  die "unknown source $1"
}

# fetch <file> <sha256> <url> [url ...]: downloads <file> from the first url
# that gives the pinned sha256 (kept when it already does). Each url gets a
# few tries, a dropped connection included (a slow ffmpeg.org drops the TLS
# handshake, which curl's plain --retry doesn't retry), before the next.
fetch() {
  local file="$1" sha="$2" u got; shift 2
  [[ -f "$file" && "$(sha256 "$file")" == "$sha" ]] && return 0
  for u in "$@"; do
    log "download $u"
    if curl -fL --retry 4 --retry-all-errors --retry-delay 10 --connect-timeout 30 -o "$file.part" "$u"; then
      got="$(sha256 "$file.part")"
      [[ "$got" == "$sha" ]] && { mv "$file.part" "$file"; return 0; }
      log "sha256 mismatch from $u (got $got, want $sha)"
    fi
    rm -f "$file.part"
  done
  die "$(basename "$file"): no url gave sha256 $sha"
}

# fetch_and_unpack <name>: downloads (cached), verifies, unpacks to $SRC/<name>.
fetch_and_unpack() {
  local name="$1" version urls sha file dir
  version="$(source_field "$name" version)"
  read -r -a urls <<<"$(source_field "$name" url)"
  sha="$(source_field "$name" sha)"
  file="$DL/$name-$version.tar.${urls[0]##*.tar.}"
  mkdir -p "$DL" "$SRC"
  fetch "$file" "$sha" "${urls[@]}"
  dir="$SRC/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar xf "$file" -C "$dir" --strip-components=1
}

# ---- Target -----------------------------------------------------------------
OS=""; ARCH=""; HOST=""; CROSS_PREFIX=""; EXE=""
CFLAGS_T=""; LDFLAGS_T=""; VPX_TARGET=""; FF_TARGET=()
NATIVE_UNAME="$(uname -s)"; NATIVE_ARCH="$(uname -m)"

case "$TRIPLE" in
  aarch64-apple-darwin|x86_64-apple-darwin)
    [[ "$NATIVE_UNAME" == Darwin ]] || die "$TRIPLE builds on macOS"
    OS=darwin
    export MACOSX_DEPLOYMENT_TARGET=11.0
    if [[ "$TRIPLE" == aarch64-* ]]; then ARCH=aarch64; MARCH=arm64; VPX_TARGET=arm64-darwin20-gcc
    else ARCH=x86_64; MARCH=x86_64; VPX_TARGET=x86_64-darwin20-gcc; fi
    HOST="$ARCH-apple-darwin"
    CFLAGS_T="-arch $MARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
    LDFLAGS_T="$CFLAGS_T"
    export CC="clang $CFLAGS_T" CXX="clang++ $CFLAGS_T"
    FF_TARGET=(--target-os=darwin --arch="$ARCH" --cc=clang --cxx=clang++)
    if [[ "$NATIVE_ARCH" != "$MARCH" ]]; then FF_TARGET+=(--enable-cross-compile); fi
    ;;
  aarch64-unknown-linux-gnu|x86_64-unknown-linux-gnu)
    [[ "$NATIVE_UNAME" == Linux ]] || die "$TRIPLE builds on Linux (natively, on that architecture)"
    OS=linux; ARCH="${TRIPLE%%-*}"
    [[ "$NATIVE_ARCH" == "$ARCH" || ( "$NATIVE_ARCH" == arm64 && "$ARCH" == aarch64 ) ]] \
      || die "$TRIPLE builds natively on $ARCH Linux (this is $NATIVE_ARCH)"
    HOST="$ARCH-linux-gnu"
    if [[ "$ARCH" == aarch64 ]]; then VPX_TARGET=arm64-linux-gcc; else VPX_TARGET=x86_64-linux-gcc; fi
    export CC="${CC:-gcc}" CXX="${CXX:-g++}"
    FF_TARGET=(--target-os=linux --arch="$ARCH")
    ;;
  x86_64-pc-windows-msvc|x86_64-pc-windows-gnu)
    OS=windows; ARCH=x86_64; EXE=.exe
    HOST=x86_64-w64-mingw32; VPX_TARGET=x86_64-win64-gcc
    case "$NATIVE_UNAME" in
      MINGW64*|MSYS*) CROSS_PREFIX="" ;;              # native MSYS2 MINGW64 shell
      *) CROSS_PREFIX="x86_64-w64-mingw32-"
         command -v "${CROSS_PREFIX}gcc" >/dev/null || die "need mingw-w64 (${CROSS_PREFIX}gcc) to cross-build $TRIPLE" ;;
    esac
    export CC="${CROSS_PREFIX}gcc" CXX="${CROSS_PREFIX}g++" AR="${CROSS_PREFIX}ar" RANLIB="${CROSS_PREFIX}ranlib"
    LDFLAGS_T="-static -static-libgcc"
    FF_TARGET=(--target-os=mingw32 --arch=x86_64)
    # Cross-compiling, ffmpeg would look for ${CROSS_PREFIX}pkg-config; the
    # host's pkg-config already sees only our own prefix (PKG_CONFIG_LIBDIR).
    [[ -n "$CROSS_PREFIX" ]] && FF_TARGET+=(--enable-cross-compile --cross-prefix="$CROSS_PREFIX" --pkg-config=pkg-config)
    ;;
  *) die "unsupported target $TRIPLE" ;;
esac

if [[ "$ARCH" == x86_64 ]]; then
  command -v nasm >/dev/null || die "x86_64 builds need nasm (brew install nasm / apt install nasm)"
fi
command -v pkg-config >/dev/null || die "need pkg-config"
command -v meson >/dev/null && command -v ninja >/dev/null || die "need meson and ninja (dav1d builds with them)"
command -v cmake >/dev/null || die "need cmake (SVT-AV1, x265 and vid.stab build with it)"
command -v autoreconf >/dev/null && command -v automake >/dev/null || die "need autoconf, automake and libtool (zimg builds with them)"

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"
# Only our own static libraries; never a system or Homebrew copy.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH || true
export CFLAGS="$CFLAGS_T -O2 -fPIC -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$LDFLAGS_T -L$PREFIX/lib"
AUTOTOOLS_HOST=()
if [[ "$OS" == windows || ( "$OS" == darwin && "$NATIVE_ARCH" != "$MARCH" ) ]]; then
  AUTOTOOLS_HOST=(--host="$HOST")
fi

# ---- Dependencies -------------------------------------------------------------
build_zlib() {
  # macOS ships zlib in the OS; elsewhere link a static copy.
  fetch_and_unpack zlib
  log "zlib"
  (cd "$SRC/zlib"
   if [[ "$OS" == windows ]]; then
     make -f win32/Makefile.gcc PREFIX="$CROSS_PREFIX" -j"$JOBS" libz.a
     cp libz.a "$PREFIX/lib/"; cp zlib.h zconf.h "$PREFIX/include/"
     printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: zlib\nDescription: zlib\nVersion: %s\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n' \
       "$PREFIX" "$(source_field zlib version)" > "$PREFIX/lib/pkgconfig/zlib.pc"
   else
     ./configure --prefix="$PREFIX" --static
     make -j"$JOBS" && make install
   fi)
}

build_lame() {
  fetch_and_unpack lame
  log "lame"
  (cd "$SRC/lame"
   ./configure --prefix="$PREFIX" ${AUTOTOOLS_HOST[@]+"${AUTOTOOLS_HOST[@]}"} --disable-shared --enable-static \
     --disable-frontend --disable-decoder --disable-gtktest --enable-nasm=no
   make -j"$JOBS" && make install)
}

build_opus() {
  fetch_and_unpack opus
  log "opus"
  (cd "$SRC/opus"
   ./configure --prefix="$PREFIX" ${AUTOTOOLS_HOST[@]+"${AUTOTOOLS_HOST[@]}"} --disable-shared --enable-static \
     --disable-doc --disable-extra-programs
   make -j"$JOBS" && make install)
}

build_libvpx() {
  fetch_and_unpack libvpx
  log "libvpx ($VPX_TARGET)"
  (cd "$SRC/libvpx"
   local cross=()
   [[ -n "$CROSS_PREFIX" ]] && cross=(env CROSS="$CROSS_PREFIX")
   # libvpx's configure picks its own -arch/-target from --target.
   CC="${CC%% *}" CXX="${CXX%% *}" CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" LDFLAGS="" \
   ${cross[@]+"${cross[@]}"} ./configure --prefix="$PREFIX" --target="$VPX_TARGET" \
     --disable-shared --enable-static --enable-pic \
     --disable-examples --disable-tools --disable-docs --disable-unit-tests \
     --disable-install-bins --disable-install-docs \
     --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --disable-webm-io --disable-libyuv
   make -j"$JOBS" && make install)
}


# A meson cross file for the target (Windows via mingw-w64, or an Intel Mac
# built on Apple silicon), in the current folder; prints the meson flag.
meson_cross() {
  if [[ "$OS" == windows && -n "$CROSS_PREFIX" ]] || [[ "$OS" == darwin && "$NATIVE_ARCH" != "$MARCH" ]]; then
    local c="$CC" cxx="$CXX" ar="${AR:-ar}" strip="${CROSS_PREFIX}strip"
    cat > cross.txt <<CROSS
[binaries]
c = [$(printf "'%s'," $c | sed 's/,$//')]
cpp = [$(printf "'%s'," $cxx | sed 's/,$//')]
ar = '$ar'
strip = '$strip'
nasm = 'nasm'
pkg-config = 'pkg-config'

[host_machine]
system = '$OS'
cpu_family = '$ARCH'
cpu = '$ARCH'
endian = 'little'
CROSS
    echo "--cross-file cross.txt"
  fi
}

# cmake settings for the target (cross builds included).
cmake_target() {
  CMAKE_T=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
           -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
  case "$OS" in
    darwin)
      CMAKE_T+=(-DCMAKE_OSX_ARCHITECTURES="$MARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")
      [[ "$NATIVE_ARCH" != "$MARCH" ]] && CMAKE_T+=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH") ;;
    windows)
      [[ -n "$CROSS_PREFIX" ]] && CMAKE_T+=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64
        -DCMAKE_C_COMPILER="${CROSS_PREFIX}gcc" -DCMAKE_CXX_COMPILER="${CROSS_PREFIX}g++"
        -DCMAKE_RC_COMPILER="${CROSS_PREFIX}windres" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER) ;;
  esac
  return 0
}

# The C++ runtime a static C++ library needs in ffmpeg's C link
# (statically on Linux: the binary must run without libstdc++ installed).
cxx_libs() {
  case "$OS" in darwin) echo "-lc++" ;; linux) echo "-l:libstdc++.a -lm -lpthread -ldl" ;; windows) echo "-lstdc++" ;; esac
}

# Point a .pc file's private libraries at the C++ runtime, nothing else.
pc_cxx() {
  sed -i.bak -e '/^Libs.private:/d' -e "s|^Libs: .*|& $(cxx_libs)|" "$PREFIX/lib/pkgconfig/$1.pc"
}

build_dav1d() {
  fetch_and_unpack dav1d
  log "dav1d"
  (cd "$SRC/dav1d"
   local cross; cross="$(meson_cross)"
   rm -rf _build
   meson setup _build $cross --prefix="$PREFIX" --libdir=lib \
     --default-library=static --buildtype=release \
     -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
   ninja -C _build -j"$JOBS"
   ninja -C _build install)
}

build_rubberband() {
  fetch_and_unpack rubberband
  log "Rubber Band"
  (cd "$SRC/rubberband"
   local cross; cross="$(meson_cross)"
   rm -rf _build
   # Its own FFT and resampler: nothing else to link (no vDSP, no FFTW).
   # 4.0.0 uses size_t without including <cstddef>; newer C++ libraries
   # need it said, so it is force-included rather than the source patched.
   meson setup _build $cross --prefix="$PREFIX" --libdir=lib \
     --default-library=static --buildtype=release -Dfft=builtin -Dresampler=builtin \
     -Dcpp_args="-include cstddef" \
     -Djni=disabled -Dladspa=disabled -Dlv2=disabled -Dvamp=disabled -Dcmdline=disabled -Dtests=disabled
   ninja -C _build -j"$JOBS"
   ninja -C _build install
   pc_cxx rubberband)
}

build_x264() {
  fetch_and_unpack x264
  log "x264"
  (cd "$SRC/x264"
   local host=()
   if [[ "$OS" == windows && -n "$CROSS_PREFIX" ]]; then host=(--host=x86_64-w64-mingw32 --cross-prefix="$CROSS_PREFIX")
   elif [[ "$OS" == darwin && "$NATIVE_ARCH" != "$MARCH" ]]; then host=(--host="$HOST"); fi
   ./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli --disable-opencl \
     --disable-lavf --disable-swscale --disable-ffms --disable-gpac --disable-lsmash \
     ${host[@]+"${host[@]}"} --extra-cflags="$CFLAGS_T" --extra-ldflags="$LDFLAGS_T"
   make -j"$JOBS" && make install)
}

build_x265() {
  fetch_and_unpack x265
  log "x265 (8- and 10-bit)"
  (cd "$SRC/x265"
   cmake_target
   local extra=(-DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_HDR10_PLUS=OFF)
   [[ "$ARCH" == x86_64 ]] && extra+=(-DCMAKE_ASM_NASM_COMPILER=nasm)
   rm -rf _build _build10
   # Main 10 first, as a library of its own (its API kept internal), then the
   # 8-bit library linked to it: one libx265 that encodes either depth, the
   # depth picked by the pixel format ffmpeg hands it (yuv420p or
   # yuv420p10le). HDR delivery (HDR10, HLG, Dolby Vision 8.x) needs Main 10.
   CC="${CC%% *}" CXX="${CXX%% *}" CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" LDFLAGS="" \
     cmake -S source -B _build10 "${CMAKE_T[@]}" "${extra[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
   cmake --build _build10 -j "$JOBS"
   CC="${CC%% *}" CXX="${CXX%% *}" CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" LDFLAGS="" \
     cmake -S source -B _build "${CMAKE_T[@]}" "${extra[@]}" -DLINKED_10BIT=ON \
       -DEXTRA_LIB="x265_main10.a" -DEXTRA_LINK_FLAGS="-L$SRC/x265/_build10"
   cmake --build _build -j "$JOBS"
   cmake --install _build
   cp _build10/libx265.a "$PREFIX/lib/libx265_main10.a"
   pc_cxx x265
   # The 8-bit library calls into the 10-bit one, so it links after it
   # (pc_cxx left the C++ runtime after -lx265, so a space follows it).
   sed -i.bak -e '/^Libs:/s|-lx265 |-lx265 -lx265_main10 |' "$PREFIX/lib/pkgconfig/x265.pc"
   grep -q -- '-lx265_main10' "$PREFIX/lib/pkgconfig/x265.pc" || die "x265.pc does not link the 10-bit library")
}

build_vidstab() {
  fetch_and_unpack vidstab
  log "vid.stab"
  (cd "$SRC/vidstab"
   cmake_target
   rm -rf _build
   # No OpenMP: it would need a runtime library beside the binary.
   CC="${CC%% *}" CXX="${CXX%% *}" CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" LDFLAGS="" \
     cmake -S . -B _build "${CMAKE_T[@]}" -DUSE_OMP=OFF
   cmake --build _build -j "$JOBS"
   cmake --install _build)
}

build_svtav1() {
  fetch_and_unpack svtav1
  log "SVT-AV1"
  (cd "$SRC/svtav1"
   cmake_target
   rm -rf _build
   CC="${CC%% *}" CXX="${CXX%% *}" CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" LDFLAGS="" \
     cmake -S . -B _build "${CMAKE_T[@]}" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DSVT_AV1_LTO=OFF
   cmake --build _build -j "$JOBS"
   cmake --install _build)
}

build_zimg() {
  fetch_and_unpack zimg
  log "zimg"
  (cd "$SRC/zimg"
   if ! command -v libtoolize >/dev/null && command -v glibtoolize >/dev/null; then export LIBTOOLIZE=glibtoolize; fi
   autoreconf -if
   ./configure --prefix="$PREFIX" ${AUTOTOOLS_HOST[@]+"${AUTOTOOLS_HOST[@]}"} --disable-shared --enable-static
   make -j"$JOBS" && make install
   pc_cxx zimg)
}

build_nvcodec() {
  # Headers only (MIT): ffmpeg loads the NVIDIA driver's NVENC at run time.
  fetch_and_unpack nvcodec
  log "nv-codec-headers"
  (cd "$SRC/nvcodec" && make PREFIX="$PREFIX" LIBDIR=lib install)
}

# NVENC and NVDEC where NVIDIA's drivers exist for desktops: Linux x86_64 and Windows.
NVENC=""
[[ "$OS" == windows || ( "$OS" == linux && "$ARCH" == x86_64 ) ]] && NVENC=1

# ---- ffmpeg -----------------------------------------------------------------
# Only what nebo-media's commands use; everything else stays out.
DEMUXERS=ffmetadata,rawvideo,ivf,mov,matroska,avi,mp3,aac,wav,flac,ogg,gif,image2,image_png_pipe,image_jpeg_pipe,image_webp_pipe,image_bmp_pipe,image_tiff_pipe,concat,mpegts,mpegps,flv,ac3,eac3,h264,hevc,m4v,asf
MUXERS=mp4,mov,ipod,webm,matroska,gif,image2,image2pipe,mp3,wav,flac,adts,rawvideo,null
DECODERS=libdav1d,h264,hevc,vp8,vp9,mpeg4,mpeg2video,mpeg1video,h263,mjpeg,prores,png,apng,gif,webp,bmp,tiff,rawvideo,aac,aac_latm,mp3,mp3float,mp2,opus,vorbis,flac,alac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_mulaw,pcm_alaw,wmav2
ENCODERS=aac,libmp3lame,libopus,libvpx_vp9,libsvtav1,libx264,libx265,prores_ks,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,flac,png,gif,mjpeg,rawvideo,wrapped_avframe
# Filters: one per line, in groups, each with what uses it, so none is pruned
# as "unused" again (scripts/check-ffmpeg.sh holds the binary to this list;
# crates/cli/tests/bundled_ffmpeg.rs fails a cargo test, on any machine, when
# the code names a filter it leaves out). Add a filter on its own
# line, in its group, sorted.
FILTERS=(
  # Picture: shape, timing and pixels (every render: compose, edit, video, pipe)
  concat             # video join, compose's segments, edit's cuts
  crop               # video crop, reframe, compose's fit
  fps                # every render's frame rate
  format             # pixel formats in every graph
  loop               # held frames: compose, cutdown, endings
  null               # pass-through branches
  overlay            # compose's layers, logos, picture in picture
  pad                # letterbox, image and video size presets
  scale              # every resize
  select             # end-to-end tests: frames picked from a render
  setdar             # display aspect (kept from the first build)
  setpts             # speed changes, segment starts
  setsar             # square pixels before every overlay
  split              # one picture to several branches (edit, video)
  tpad               # a clip held or padded to its slot
  trim               # every cut
  xstack             # compose's blended layers (the picture under one beside it, read in Rust); grids
  # Picture: transitions, looks and repair
  alphamerge         # compose's masks
  blend              # compose's rounded corners on deep (16-bit) pictures
  colorchannelmixer  # compose's opacity and tints
  deshake            # video stabilize (quick)
  fade               # fades in and out, endings
  lutyuv             # compose's layer opacity on deep (16-bit) pictures
  lut3d              # video grade, looks, compose's color
  minterpolate       # compose's smooth slow motion
  palettegen         # GIF export
  paletteuse         # GIF export
  scdet              # scene cuts: shots, check's flash_frame and level_jump
  showinfo           # live preview: each decoded frame's time
  unsharp            # a grade's sharpen and clarity
  vidstabdetect      # video stabilize (two-pass)
  vidstabtransform   # video stabilize (two-pass)
  xfade              # video join's crossfades
  # Picture: color and HDR
  colorspace         # color conversions
  hue                # end-to-end test fixtures: a tinted phone clip
  setparams          # color tags on SDR output
  sidedata           # drops a source's HDR10 metadata that the run replaces
  tonemap            # HDR to SDR
  zscale             # HDR to SDR
  # Picture: kept from the first build (no caller in the code today)
  chromakey          # green screen
  colorkey           # green screen
  hflip              # mirror
  transpose          # rotate
  vflip              # flip
  # Picture: effects (finishing PRD section 13)
  gblur              # privacy blur that follows; a grade's blur
  noise              # a grade's grain
  vignette           # a grade's vignette
  # Picture: denoise and deband (finishing PRD 10.2 item 10, parity audit; grade's denoise and deband)
  deband             # a grade's deband, at 16 bits before the one dither
  hqdn3d             # a grade's denoise (temporal, any bit depth)
  nlmeans            # high-quality video denoise
  # Picture: analysis (parity audit)
  showspectrum       # a spectrum picture of the sound
  # Sources: generated pictures and sound
  aevalsrc           # end-to-end test fixtures: a rising tone
  anullsrc           # silence: gaps, voice-over starts, compose's beds
  cellauto           # end-to-end test fixtures: distinct moving phone clips
  color              # compose's backgrounds, cards, the canvas; a blended layer's clear canvas
  gradients          # end-to-end test fixtures: distinct moving phone clips
  life               # end-to-end test fixtures: distinct moving phone clips
  mandelbrot         # end-to-end test fixtures: distinct moving phone clips
  sine               # end-to-end test fixtures
  testsrc            # end-to-end test fixtures
  testsrc2           # end-to-end test fixtures
  # Sound: shape, timing and mixing (every render with sound)
  acrossfade         # audio join's crossfades
  adelay             # a layer's sound placed at its start; robot and echo voice effects
  afade              # sound fades
  aformat            # sample formats in every graph
  aloop              # looped music (kept from the first build)
  amix               # compose's mix, voice-over; robot and echo voice effects; normalize's difference (null) render
  anull              # pass-through branches
  apad               # sound padded to its picture
  aresample          # rates, 4x oversampling for the true-peak limiter, TPDF dither to 16 bits
  asetpts            # sound timestamps after a cut
  asetrate           # pitch with speed (audio speed)
  asplit             # one sound to several branches (voice finish, dialogue, robot and echo)
  atempo             # audio speed, compose's speed changes
  atrim              # every sound cut
  sidechaincompress  # ducking music under the voice
  volume             # every gain
  # Sound: cleanup, EQ and dynamics (audio clean, voice finish, EQ Match)
  aeval              # compose's fades on a clip's own sound; the robot voice effect
  afftdn             # noise reduction
  agate              # dialogue isolation's gate
  alimiter           # the one peak limiter (filters::limiter): true-peak hold, voice finish
  arnndn             # dialogue isolation (RNNoise model)
  deesser            # voice finish
  equalizer          # voice finish EQ; phone and megaphone voice effects; the repair assistant's hum notches
  firequalizer       # EQ Match
  highpass           # rumble cut; radio, phone and megaphone voice effects; the repair assistant's wind cut
  highshelf          # voice finish EQ
  lowpass            # dialogue isolation; radio, phone and megaphone voice effects
  lowshelf           # voice finish EQ (finishing PRD 3.B)
  rubberband         # audio speed and pitch at high quality; chipmunk and deep voice effects
  silencedetect      # silences (kept from the first build)
  # Sound: the one meter (meter.rs) and clipping in check
  ametadata          # prints ebur128's readings
  astats             # check's clipping
  ebur128            # loudness, true peak, sample peak, range: every measurement
  # Sound: effects (finishing PRD section 13)
  afir               # room match (impulse responses)
  asoftclip          # voice effects
  # Sound: repair and mixing (parity audit)
  acompressor        # compression: the radio voice effect; normalize's loudness range per content type
  pan                # channel mapping, mono to stereo; check's mono fold-down (phase)
  stereotools        # stereo width, mid/side
)
PROTOCOLS=file,pipe

# Hardware decoders (hwaccels) on each platform. --disable-everything turns
# them all off, so each is named. VideoToolbox and D3D11VA are OS APIs; NVDEC
# loads NVIDIA's driver at run time through the same nv-codec-headers as NVENC
# (nothing linked, nothing nonfree). FFmpeg's own -hwaccel d3d11va runs the
# d3d11va2 ones. scripts/check-ffmpeg.sh checks the finished binary has each.
HWACCELS_DARWIN=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox
HWACCELS_WINDOWS=h264_d3d11va,h264_d3d11va2,hevc_d3d11va,hevc_d3d11va2
HWACCELS_NVDEC=h264_nvdec,hevc_nvdec

configure_ffmpeg() {
  local platform=()
  case "$OS" in
    darwin)  platform=(--enable-videotoolbox --enable-encoder=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox
                       --enable-hwaccel="$HWACCELS_DARWIN") ;;
    linux)   platform=(--extra-ldflags="-static-libgcc -static-libstdc++" --extra-libs="-lpthread -lm -ldl") ;;
    # FFmpeg 9's Media Foundation encoder is built on D3D11 (an OS API).
    windows) platform=(--enable-mediafoundation --enable-d3d11va --enable-encoder=h264_mf,hevc_mf --enable-w32threads
                       --enable-hwaccel="$HWACCELS_WINDOWS" --extra-ldflags="-static -static-libgcc") ;;
  esac
  FF_CONFIGURE=(
    --prefix="$PREFIX"
    "${FF_TARGET[@]}"
    --pkg-config-flags=--static
    --extra-cflags="-I$PREFIX/include $CFLAGS_T"
    --extra-ldflags="-L$PREFIX/lib $LDFLAGS_T"
    --enable-static --disable-shared
    --disable-autodetect --disable-everything
    --disable-debug --disable-doc --disable-network --disable-avdevice --disable-ffplay
    --enable-ffmpeg --enable-ffprobe --enable-swscale --enable-swresample
    --enable-gpl
    --enable-zlib --enable-libmp3lame --enable-libopus --enable-libvpx --enable-libdav1d --enable-libsvtav1 --enable-libzimg
    --enable-libx264 --enable-libx265 --enable-libvidstab --enable-librubberband
    --enable-protocol="$PROTOCOLS"
    --enable-demuxer="$DEMUXERS" --enable-muxer="$MUXERS"
    --enable-decoder="$DECODERS" --enable-encoder="$ENCODERS"
    --enable-filter="$(IFS=,; echo "${FILTERS[*]}")"
    --enable-parsers --enable-bsfs
    "${platform[@]}"
  )
  [[ -n "$NVENC" ]] && FF_CONFIGURE+=(--enable-ffnvcodec --enable-nvenc --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc
                                       --enable-nvdec --enable-hwaccel="$HWACCELS_NVDEC")
  return 0
}

build_ffmpeg() {
  fetch_and_unpack ffmpeg
  log "ffmpeg $FFMPEG_VERSION"
  printf '  %s\n' "${FF_CONFIGURE[@]}" >&2
  (cd "$SRC/ffmpeg"
   # ffmpeg reads its flags from configure, not the environment.
   env -u CFLAGS -u CXXFLAGS -u LDFLAGS ./configure "${FF_CONFIGURE[@]}" \
     || { tail -50 ffbuild/config.log; exit 1; }
   make -j"$JOBS")
}

# ---- Checks -----------------------------------------------------------------
# Before packaging, from the source tree: ffmpeg's config.h says GPL version
# 2 or later (never version 3, never nonfree), its configuration carries no
# --enable-nonfree/--enable-version3, and nothing nonfree is enabled. After
# packaging, the binaries themselves are checked by scripts/check-ffmpeg.sh.
check_license() {
  local ff="$SRC/ffmpeg"
  log "license check"
  local lic conf
  lic="$(sed -n 's/^#define FFMPEG_LICENSE "\(.*\)"/\1/p' "$ff/config.h")"
  conf="$(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"/\1/p' "$ff/config.h")"
  echo "license: $lic"
  [[ "$lic" == "GPL version 2 or later" ]] || die "ffmpeg license is '$lic', not GPL version 2 or later"
  for bad in --enable-nonfree --enable-version3 libfdk cuda-nvcc cuda_nvcc cuda-sdk cuda_sdk libnpp; do
    [[ "$conf" != *"$bad"* ]] || die "configuration contains $bad"
  done
  if grep -Eq '^#define CONFIG_(NONFREE|VERSION3|LIBFDK_AAC|CUDA_NVCC|CUDA_SDK|LIBNPP)[A-Z_]* 1' "$ff/config.h"; then
    die "config.h enables a nonfree or GPLv3-only component"
  fi
}

# Every filter name this FFmpeg has (built or not) is kept in the repo, in
# scripts/ffmpeg-filter-names.txt, so crates/cli/tests/bundled_ffmpeg.rs can
# tell the code's filter names from other words in any cargo test, with no
# ffmpeg built. Read from the source on every run, a cached build too: a new
# FFmpeg rewrites the list and stops here until the new list is committed.
check_filter_catalog() {
  local catalog="$ROOT/scripts/ffmpeg-filter-names.txt" names
  names="$(sed -n 's/^extern const FFFilter ff_[av]\{1,2\}[a-z]*_\([a-z0-9_]*\);/\1/p' "$SRC/ffmpeg/libavfilter/allfilters.c" | LC_ALL=C sort -u)"
  [[ -n "$names" ]] || die "libavfilter/allfilters.c names no filters"
  if [[ ! -f "$catalog" || "$names" != "$(cat "$catalog")" ]]; then
    printf '%s\n' "$names" > "$catalog"
    die "scripts/ffmpeg-filter-names.txt did not match ffmpeg $FFMPEG_VERSION's filters: rewrote it; commit it and run again"
  fi
}

package() {
  log "package -> vendor/$TRIPLE"
  mkdir -p "$OUT"
  local strip_cmd="${CROSS_PREFIX}strip"
  for b in ffmpeg ffprobe; do
    cp "$SRC/ffmpeg/$b$EXE" "$WORK/$b$EXE"
    if [[ "$OS" == darwin ]]; then strip -x "$WORK/$b$EXE"; else "$strip_cmd" "$WORK/$b$EXE"; fi
    if [[ "$OS" == darwin ]]; then
      # Ad-hoc signature: arm64 macOS refuses to run unsigned code.
      codesign --force --sign - "$WORK/$b$EXE" >/dev/null 2>&1 || true
    fi
    gzip -9 -n -c "$WORK/$b$EXE" > "$OUT/$b$EXE.gz"
  done
  {
    echo "ffmpeg $FFMPEG_VERSION for $TRIPLE"
    echo "license: $(sed -n 's/^#define FFMPEG_LICENSE "\(.*\)"/\1/p' "$SRC/ffmpeg/config.h")"
    echo
    echo "sources (sha256-pinned):"
    local s
    for s in "${SOURCES[@]}"; do IFS='|' read -r n v u h <<<"$s"; echo "  $n $v  $u  sha256:$h"; done
    echo
    echo "configure:"
    printf '  %s\n' "${FF_CONFIGURE[@]}"
  } > "$OUT/BUILDINFO.txt"
  ls -l "$OUT" >&2
}

# stage <name> <key> <function>: runs the function unless build/<triple> holds
# a stamp for the same key, so a rerun (or a restored CI cache) skips work done.
stage() {
  local stamp="$WORK/.stamp-$1"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$2" ]]; then
    log "$1: up to date"
    return
  fi
  rm -f "$stamp"
  "$3"
  echo "$2" > "$stamp"
}

dep_key() { echo "$(source_field "$1" sha) $TRIPLE"; }

log "nebo-media ffmpeg for $TRIPLE ($OS/$ARCH, $JOBS jobs)"
[[ "$OS" == darwin ]] || stage zlib "$(dep_key zlib)" build_zlib
stage lame "$(dep_key lame)" build_lame
stage opus "$(dep_key opus)" build_opus
stage libvpx "$(dep_key libvpx)" build_libvpx
stage dav1d "$(dep_key dav1d)" build_dav1d
stage svtav1 "$(dep_key svtav1)" build_svtav1
stage zimg "$(dep_key zimg)" build_zimg
[[ -n "$NVENC" ]] && stage nvcodec "$(dep_key nvcodec)" build_nvcodec
stage x264 "$(dep_key x264)" build_x264
stage x265 "$(dep_key x265) main+main10" build_x265
stage vidstab "$(dep_key vidstab)" build_vidstab
stage rubberband "$(dep_key rubberband)" build_rubberband
configure_ffmpeg
stage ffmpeg "$(dep_key ffmpeg) $(printf '%s ' "${FF_CONFIGURE[@]}" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)" build_ffmpeg
check_license
check_filter_catalog
package
log "license and link check"
"$ROOT/scripts/check-ffmpeg.sh" "$TRIPLE"
log "done"

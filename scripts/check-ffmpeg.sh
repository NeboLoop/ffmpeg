#!/usr/bin/env bash
# Checks the ffmpeg in vendor/<triple>/ (what nebo-media embeds) is GPL
# version 2 or later (never version 3, never nonfree, so it can be
# redistributed) and depends on nothing but the operating system.
#
#   scripts/check-ffmpeg.sh <rust-target-triple>
#
# scripts/build-ffmpeg.sh runs this after every build; CI runs it again on a
# cached build. Exits non-zero on any finding.
#
# Always (any machine, any target): the license and configure line baked
# into the binary say GPL v2+, with no --enable-nonfree/--enable-version3
# and no nonfree library (fdk-aac, CUDA NVCC/SDK, NPP).
# When this machine can run the binary: ffmpeg -version, -L and -encoders
# say the same. When it has the tool: the binary links only OS libraries.
set -euo pipefail

TRIPLE="${1:-}"
[[ -n "$TRIPLE" ]] || { echo "usage: $0 <rust-target-triple>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/vendor/$TRIPLE"
EXE=""; [[ "$TRIPLE" == *windows* ]] && EXE=".exe"

die() { printf 'LICENSE CHECK FAILED (%s): %s\n' "$TRIPLE" "$*" >&2; exit 1; }

[[ -f "$DIR/ffmpeg$EXE.gz" && -f "$DIR/ffprobe$EXE.gz" ]] || die "vendor/$TRIPLE has no ffmpeg/ffprobe"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for b in ffmpeg ffprobe; do
  bin="$TMP/$b$EXE"
  gunzip -c "$DIR/$b$EXE.gz" > "$bin"
  chmod +x "$bin"

  # The strings libavutil reports from av_license() and av_configuration().
  grep -aq 'GPL version 2 or later' "$bin" || die "$b: no 'GPL version 2 or later' license string"
  for bad in 'GPL version 3 or later' 'nonfree and unredistributable' \
             '--enable-nonfree' '--enable-version3' '--enable-libfdk' '--enable-cuda-nvcc' '--enable-cuda-sdk' '--enable-libnpp'; do
    ! grep -aq -- "$bad" "$bin" || die "$b contains '$bad'"
  done
done
echo "license: GPL version 2 or later ($TRIPLE)"

runnable() {
  case "$TRIPLE:$(uname -s):$(uname -m)" in
    aarch64-apple-darwin:Darwin:arm64) return 0 ;;
    x86_64-apple-darwin:Darwin:x86_64) return 0 ;;
    x86_64-apple-darwin:Darwin:arm64) arch -x86_64 /usr/bin/true 2>/dev/null ;; # Rosetta
    aarch64-unknown-linux-gnu:Linux:aarch64) return 0 ;;
    x86_64-unknown-linux-gnu:Linux:x86_64) return 0 ;;
    x86_64-pc-windows-*:MINGW*|x86_64-pc-windows-*:MSYS*) return 0 ;;
    *) return 1 ;;
  esac
}

FF="$TMP/ffmpeg$EXE"
if runnable; then
  ver="$("$FF" -hide_banner -version)"
  echo "$ver" | sed -n '1p'
  conf="$(echo "$ver" | sed -n 's/^configuration: //p')"
  [[ -n "$conf" ]] || die "-version has no configuration line"
  echo "configuration: $conf" | sed "s#$ROOT/##g"
  for bad in --enable-nonfree --enable-version3; do
    [[ "$conf" != *"$bad"* ]] || die "-version shows $bad"
  done
  [[ "$conf" == *--enable-gpl* ]] || die "-version does not show --enable-gpl"
  # -L wraps its text; join it into one line before matching.
  lic="$("$FF" -hide_banner -L | tr -s ' \n\r' '   ')"
  [[ "$lic" == *"GNU General Public License as published"*"either version 2 of the License"* ]] || die "-L does not say GPL version 2 or later"
  [[ "$lic" != *"nonfree"* ]] || die "-L says nonfree"
  echo "-L: GNU General Public License, version 2 or later"
  ! "$FF" -hide_banner -encoders | grep -Eq 'libfdk' || die "a nonfree encoder is present"
  echo "encoders: $("$FF" -hide_banner -encoders | awk 'NR>10 && $1 ~ /^[VA]/ {print $2}' | tr '\n' ' ')"
  # Every component the build asks for is really in the binary: configure
  # drops one silently when its dependency is missing.
  list() { sed -n "s/^$1=//p" "$ROOT/scripts/build-ffmpeg.sh" | tr ',' ' '; }
  have() { # have <-flag> <first column pattern>: the names the binary lists
    "$FF" -hide_banner "$1" 2>/dev/null | awk -v pat="$2" '$1 ~ pat {print $2}' | tr ',-' '\n_'
  }
  missing=""
  check_kind() { # check_kind <LIST> <-flag> <pattern>
    local got; got="$(have "$2" "$3")"
    for n in $(list "$1"); do
      # Listed by their short names: mpegps as mpeg, image_png_pipe as png_pipe.
      local shown="${n#image_}"; [[ "$n" == mpegps ]] && shown=mpeg
      grep -qx "$shown" <<<"$got" || missing="$missing $1:$n"
    done
  }
  check_kind FILTERS -filters '^[.TSC|]+$'
  check_kind DECODERS -decoders '^[VAS][.A-Z]+$'
  check_kind ENCODERS -encoders '^[VAS][.A-Z]+$'
  check_kind DEMUXERS -demuxers '^D'
  check_kind MUXERS -muxers 'E'
  # Each platform's own encoders (hardware, or the OS's).
  case "$TRIPLE" in
    *apple-darwin) platform_enc="h264_videotoolbox hevc_videotoolbox prores_videotoolbox" ;;
    x86_64-unknown-linux-gnu) platform_enc="h264_nvenc hevc_nvenc av1_nvenc" ;;
    *linux-gnu) platform_enc="" ;;
    *windows*) platform_enc="h264_mf hevc_mf h264_nvenc hevc_nvenc av1_nvenc" ;;
  esac
  got="$(have -encoders '^[VAS][.A-Z]+$')"
  for n in $platform_enc; do grep -qx "$n" <<<"$got" || missing="$missing ENCODERS:$n"; done
  [[ -z "$missing" ]] || die "components missing from the build:$missing"
  echo "components: every filter, decoder, encoder, demuxer and muxer asked for is present"
else
  echo "(this machine cannot run $TRIPLE binaries; checked the strings baked into them)"
fi

# Links: only the operating system's own libraries.
case "$TRIPLE" in
  *apple-darwin)
    if command -v otool >/dev/null; then
      libs="$(otool -L "$FF" | tail -n +2 | awk '{print $1}')"
      echo "links:"; echo "$libs" | sed 's/^/  /'
      ! echo "$libs" | grep -Ev '^(/usr/lib/|/System/Library/)' | grep -q . || die "links a non-system library"
    fi ;;
  *linux-gnu)
    if command -v readelf >/dev/null; then
      libs="$(readelf -d "$FF" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')"
      echo "links:"; echo "$libs" | sed 's/^/  /'
      ! echo "$libs" | grep -Ev '^(libc\.so|libm\.so|libmvec\.so|libpthread\.so|libdl\.so|librt\.so|ld-linux)' | grep -q . \
        || die "links a non-system library"
    fi ;;
  *windows*)
    od="$(command -v x86_64-w64-mingw32-objdump || command -v objdump || true)"
    if [[ -n "$od" ]]; then
      libs="$("$od" -p "$FF" | sed -n 's/.*DLL Name: //p')"
      echo "links:"; echo "$libs" | sed 's/^/  /'
      # Windows system DLLs only (no MinGW runtime DLLs: it is linked -static).
      ! echo "$libs" | grep -Eiq '^(libgcc|libstdc|libwinpthread|libmp3lame|libvpx|libopus|zlib)' || die "links a non-system DLL"
    fi ;;
esac
echo "check passed"

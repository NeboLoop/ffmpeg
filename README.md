# ffmpeg for Nebo Media: the GPL source

Nebo Media (a plugin for [Nebo](https://neboai.com)) carries its own build of
FFmpeg's `ffmpeg` and `ffprobe` programs and runs them as separate programs.
That build is licensed under the **GNU General Public License, version 2 or
later** (it includes x264, x265, vid.stab and Rubber Band); it contains
nothing non-free. This repository is its complete corresponding source.
Nebo Media's own code is not part of it.

## What is here

| Path | What |
|------|------|
| `scripts/build-ffmpeg.sh` | Builds `ffmpeg` and `ffprobe` for one platform from the pinned upstream sources (`scripts/build-ffmpeg.sh <rust-target-triple>`) |
| `scripts/check-ffmpeg.sh` | Checks a build: GPL v2 or later, never non-free, every component present, links only the operating system |
| `SOURCES.md` | Every upstream release tarball the build uses, with its URL and sha256 (all unmodified) |
| `buildinfo/<platform>.txt` | Each released platform's exact configure line |
| `LICENSE`, `LICENSES/` | The GPL v2 text and the licences of every library in the build |

Each Nebo Media release has a GitHub release here tagged `nebo-media-<version>`
whose asset `nebo-media-ffmpeg-source-<version>.tar.gz` holds every upstream
tarball, the scripts and the configure lines for that release.

## Building it yourself

The scripts build on the platform they target (Windows is cross-built on
Linux with mingw-w64). They need a C toolchain, pkg-config, nasm (x86_64),
meson, ninja, cmake and autotools. Put the tarballs in `build/downloads/`
(or let the script download them), then run
`scripts/build-ffmpeg.sh aarch64-apple-darwin` (or another triple listed in
the script). The result is written to `vendor/<triple>/`.

To use your own build with Nebo Media, put `ffmpeg` and `ffprobe` in one
folder and set `NEBO_MEDIA_FFMPEG_DIR` to that folder.

## Licence and patents

FFmpeg and the GPL libraries are GPL v2 or later; the other libraries are
under the licences in `LICENSES/`. Patent pools exist for H.264 and HEVC
separately from any software licence; AV1 (AOMedia Patent License 1.0) and VP9
are royalty-free.

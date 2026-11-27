#!/usr/bin/env bash
# Pinned LGPL FFmpeg subset: local MOV/FLAC only, no network or executable tools.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="${PLATFORM:-ios}"
case "$PLATFORM" in
  ios) SDK=iphoneos; HOSTED_ARCH=arm64; TRIPLE=arm64-apple-ios16.0 ;;
  simulator) SDK=iphonesimulator; HOSTED_ARCH="$(uname -m)"; TRIPLE="$HOSTED_ARCH-apple-ios17.0-simulator" ;;
  macos) SDK=macosx; HOSTED_ARCH="$(uname -m)"; TRIPLE="$HOSTED_ARCH-apple-macos13.0" ;;
  *) echo "Unsupported hosted-media platform" >&2; exit 1 ;;
esac
BASE="$HERE/build"
SOURCE="$BASE/ffmpeg-9.0.2"
OUT="$BASE/$PLATFORM"
mkdir -p "$BASE" "$OUT"
ARCHIVE="$BASE/ffmpeg-9.0.2.tar.xz"
if [ ! -f "$ARCHIVE" ]; then
  curl -fL --connect-timeout 20 --max-time 180 https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz -o "$ARCHIVE.partial"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
echo "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e  $ARCHIVE" | shasum -a 256 -c - >/dev/null
if [ ! -f "$SOURCE/configure" ]; then tar -xJf "$ARCHIVE" -C "$BASE"; fi
if [ ! -f "$OUT/config.h" ]; then
  cd "$OUT"
  "$SOURCE/configure" --prefix="$OUT/install" --arch="$HOSTED_ARCH" --target-os=darwin --enable-cross-compile \
    --cc="$(xcrun --sdk "$SDK" --find clang)" --sysroot="$(xcrun --sdk "$SDK" --show-sdk-path)" \
    --extra-cflags="-target $TRIPLE -O2 -fvisibility=hidden" --extra-ldflags="-target $TRIPLE" \
    --disable-everything --disable-autodetect --disable-network --disable-programs --disable-doc \
    --disable-shared --enable-static --disable-debug --disable-asm --disable-avdevice --disable-avfilter \
    --disable-swscale --disable-swresample --enable-demuxer=mov --enable-muxer=flac \
    --enable-parser=flac --enable-decoder=flac --enable-protocol=file --enable-zlib > configure.log 2>&1
fi
# Theos uses GNU make 4.x and exports flags that macOS's make 3.81 misreads
# (notably -Otarget, which can turn into touch mode). This is an independent
# build: do not inherit its jobserver, options, command-line overrides or level.
HOSTED_MAKE=make
if command -v gmake >/dev/null 2>&1; then HOSTED_MAKE=gmake; fi
env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES -u MAKELEVEL "$HOSTED_MAKE" -C "$OUT" -j4 > "$OUT/make.log" 2>&1
env -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES -u MAKELEVEL "$HOSTED_MAKE" -C "$OUT" install > "$OUT/install.log" 2>&1
for archive in libavformat.a libavcodec.a libavutil.a; do
  test -s "$OUT/install/lib/$archive" || { echo "Missing hosted-media archive after install: $archive" >&2; exit 1; }
done
echo "$OUT/install"

#!/usr/bin/env bash
# Build the FFmpeg audio decoders (LGPL only, shared libraries, 16 KB pages)
# and the Media3 JNI wrapper for Android. This script is the source of truth
# for the prebuilt .so files in ffmpeg-decoder/src/main/jniLibs/.
#
# Usage:  bash tools/ffmpeg/build.sh
# Output: ffmpeg-decoder/src/main/jniLibs/<abi>/{libavutil,libswresample,libavcodec,libffmpegJNI}.so
#         ffmpeg-decoder/native/BUILD-INFO.txt
#         tools/ffmpeg/work/dist/   (LGPL source package, not committed)
set -euo pipefail

# ---- Inputs (override with environment variables) ----
ANDROID_SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
NDK_VERSION="${NDK_VERSION:-30.0.16248370}"
FFMPEG_TAG="${FFMPEG_TAG:-n7.1.5}"
API="${API:-28}"
ABIS="${ABIS:-armeabi-v7a arm64-v8a}"
DECODERS="${DECODERS:-ac3 eac3 dca mp3 truehd mlp}"
CMAKE_VERSION="${CMAKE_VERSION:-3.22.1}"
MEDIA3_TAG="1.11.1"
# Fingerprint of the FFmpeg release signing key.
FFMPEG_KEY_FPR="FCF986EA15E6E293A5644F10B4322F04D67658D8"

FFMPEG_VERSION="${FFMPEG_TAG#n}"
# SHA-256 of the release tarball. Add a line for each version that you use.
case "$FFMPEG_VERSION" in
  7.1.5) FFMPEG_SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f" ;;
  *)     FFMPEG_SHA256="${FFMPEG_SHA256:-}" ;;
esac
if [[ -z "$FFMPEG_SHA256" ]]; then
  echo "ERROR: no SHA-256 known for FFmpeg $FFMPEG_VERSION. Set FFMPEG_SHA256." >&2
  exit 1
fi

# ---- Paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="$SCRIPT_DIR/work"
SRC="$WORK/src"
OUT="$WORK/out"
DIST="$WORK/dist"
MODULE="$REPO_ROOT/ffmpeg-decoder"
NATIVE="$MODULE/native"
JNILIBS="$MODULE/src/main/jniLibs"
TARBALL="ffmpeg-$FFMPEG_VERSION.tar.xz"

NDK="$ANDROID_SDK/ndk/$NDK_VERSION"
HOST_TAG="darwin-x86_64"   # The NDK uses this folder name also on Apple Silicon.
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CMAKE_BIN="$ANDROID_SDK/cmake/$CMAKE_VERSION/bin"
SO_NAMES="libavutil.so libswresample.so libavcodec.so libffmpegJNI.so"

# ---- Checks ----
[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: macOS host required." >&2; exit 1; }
case "$(uname -m)" in
  arm64|x86_64) ;;
  *) echo "ERROR: unexpected host CPU $(uname -m)." >&2; exit 1 ;;
esac
[[ -d "$NDK" ]] || { echo "ERROR: NDK not found: $NDK" >&2; exit 1; }
NDK_MAJOR="${NDK_VERSION%%.*}"
if (( NDK_MAJOR < 28 )); then
  echo "ERROR: NDK 28 or newer is required (16 KB pages). Found $NDK_VERSION." >&2
  exit 1
fi
[[ -x "$TC/llvm-strip" ]] || { echo "ERROR: NDK toolchain not found: $TC" >&2; exit 1; }
[[ -x "$CMAKE_BIN/cmake" && -x "$CMAKE_BIN/ninja" ]] \
  || { echo "ERROR: CMake $CMAKE_VERSION with ninja not found in $CMAKE_BIN" >&2; exit 1; }
for tool in curl shasum xz tar make; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is missing." >&2; exit 1; }
done

# ---- Clean the build folders. The downloaded tarball stays. ----
mkdir -p "$WORK"
rm -rf "${SRC:?}" "${OUT:?}" "${DIST:?}"
rm -rf "${WORK:?}"/build-* "${WORK:?}"/*-jni
rm -f "${WORK:?}"/*-configure.log "${WORK:?}"/*-configure-cmd.txt "${WORK:?}"/*-make.log "${WORK:?}"/*-jni.log

# ---- Download and check the tarball ----
if [[ ! -f "$WORK/$TARBALL" ]]; then
  curl -fsSL -o "$WORK/$TARBALL" "https://ffmpeg.org/releases/$TARBALL"
fi
if [[ ! -f "$WORK/$TARBALL.asc" ]]; then
  curl -fsSL -o "$WORK/$TARBALL.asc" "https://ffmpeg.org/releases/$TARBALL.asc"
fi
ACTUAL_SHA256="$(shasum -a 256 "$WORK/$TARBALL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$FFMPEG_SHA256" ]]; then
  echo "ERROR: SHA-256 of $TARBALL does not match." >&2
  echo "  expected $FFMPEG_SHA256" >&2
  echo "  actual   $ACTUAL_SHA256" >&2
  exit 1
fi
GPG_STATUS="not checked (gpg or the FFmpeg release key is not available)"
if command -v gpg >/dev/null && gpg --list-keys "$FFMPEG_KEY_FPR" >/dev/null 2>&1; then
  gpg --verify "$WORK/$TARBALL.asc" "$WORK/$TARBALL"
  GPG_STATUS="verified with key $FFMPEG_KEY_FPR"
fi
echo "Tarball SHA-256 OK. GPG: $GPG_STATUS"

mkdir -p "$SRC"
tar -xJf "$WORK/$TARBALL" -C "$SRC" --strip-components=1

# ---- Build one ABI ----
build_abi() {
  local abi="$1" arch cpu triple extra_cflags="" extra_ldflags=""
  case "$abi" in
    arm64-v8a)
      arch=aarch64; cpu=armv8-a; triple=aarch64-linux-android ;;
    armeabi-v7a)
      arch=arm; cpu=armv7-a; triple=armv7a-linux-androideabi
      extra_cflags="-march=armv7-a -mfloat-abi=softfp -mfpu=neon"
      extra_ldflags="-Wl,--fix-cortex-a8" ;;
    *) echo "ERROR: unsupported ABI $abi" >&2; exit 1 ;;
  esac

  local build_dir="$WORK/build-$abi" prefix="$OUT/$abi"
  local decoder_list
  decoder_list="$(echo "$DECODERS" | tr ' ' ',')"
  mkdir -p "$build_dir" "$prefix"

  local -a args=(
    "$SRC/configure"
    "--prefix=$prefix"
    --target-os=android --enable-cross-compile
    "--arch=$arch" "--cpu=$cpu"
    "--cc=$TC/$triple$API-clang" "--cxx=$TC/$triple$API-clang++"
    "--nm=$TC/llvm-nm" "--ar=$TC/llvm-ar" "--ranlib=$TC/llvm-ranlib" "--strip=$TC/llvm-strip"
    --enable-shared --disable-static --enable-pic
    --disable-everything --disable-autodetect
    --disable-programs --disable-doc --disable-network
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-postproc
    --disable-symver --disable-v4l2-m2m --disable-vulkan --disable-mediacodec --disable-debug
    --enable-avcodec --enable-avutil --enable-swresample
    "--enable-decoder=$decoder_list"
    "--extra-cflags=-O2 -fPIC $extra_cflags"
    "--extra-ldflags=-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 $extra_ldflags"
  )
  # Save the configure command for verify-so.sh and BUILD-INFO.txt.
  printf '%s ' "${args[@]}" > "$WORK/$abi-configure-cmd.txt"
  echo >> "$WORK/$abi-configure-cmd.txt"

  echo "[$abi] configure"
  if ! (cd "$build_dir" && "${args[@]}") > "$WORK/$abi-configure.log" 2>&1; then
    tail -n 30 "$WORK/$abi-configure.log" >&2
    echo "ERROR: configure failed for $abi. See $WORK/$abi-configure.log" >&2
    exit 1
  fi

  echo "[$abi] make"
  if ! (cd "$build_dir" && make -j"$(sysctl -n hw.ncpu)" && make install) > "$WORK/$abi-make.log" 2>&1; then
    tail -n 30 "$WORK/$abi-make.log" >&2
    echo "ERROR: make failed for $abi. See $WORK/$abi-make.log" >&2
    exit 1
  fi

  echo "[$abi] JNI wrapper"
  if ! {
    "$CMAKE_BIN/cmake" -S "$NATIVE" -B "$WORK/$abi-jni" -G Ninja \
      "-DCMAKE_MAKE_PROGRAM=$CMAKE_BIN/ninja" \
      "-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake" \
      "-DANDROID_ABI=$abi" "-DANDROID_PLATFORM=android-$API" \
      -DANDROID_STL=c++_static -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
      "-DFFMPEG_PREFIX=$prefix" -DCMAKE_BUILD_TYPE=Release
    "$CMAKE_BIN/cmake" --build "$WORK/$abi-jni"
  } > "$WORK/$abi-jni.log" 2>&1; then
    tail -n 30 "$WORK/$abi-jni.log" >&2
    echo "ERROR: JNI build failed for $abi. See $WORK/$abi-jni.log" >&2
    exit 1
  fi

  echo "[$abi] strip and copy"
  mkdir -p "$JNILIBS/$abi"
  rm -f "${JNILIBS:?}/$abi"/*.so
  local name
  for name in libavutil.so libswresample.so libavcodec.so; do
    cp "$prefix/lib/$name" "$JNILIBS/$abi/$name"
  done
  cp "$WORK/$abi-jni/libffmpegJNI.so" "$JNILIBS/$abi/libffmpegJNI.so"
  for name in $SO_NAMES; do
    "$TC/llvm-strip" --strip-unneeded "$JNILIBS/$abi/$name"
  done
}

for abi in $ABIS; do
  build_abi "$abi"
done

# ---- BUILD-INFO.txt ----
INFO="$NATIVE/BUILD-INFO.txt"
{
  echo "FFmpeg native libraries for the Media3 FFmpeg decoder module"
  echo "Generated by tools/ffmpeg/build.sh. Do not edit by hand."
  echo
  echo "Date (UTC):     $(date -u +%Y-%m-%d)"
  echo "FFmpeg tag:     $FFMPEG_TAG"
  echo "Tarball:        $TARBALL"
  echo "Tarball SHA256: $ACTUAL_SHA256"
  echo "GPG signature:  $GPG_STATUS"
  echo "Media3 tag:     $MEDIA3_TAG (ffmpeg_jni.cc unchanged)"
  echo "NDK:            $NDK_VERSION"
  echo "Android API:    $API"
  echo "ABIs:           $ABIS"
  echo "Decoders:       $DECODERS"
  echo "License:        LGPL version 2.1 or later (no --enable-gpl, --enable-nonfree, --enable-version3)"
  echo
  for abi in $ABIS; do
    echo "== $abi =="
    echo "configure (<src> = unpacked tarball, <out> = install folder, <ndk-bin> = NDK toolchain bin folder):"
    sed -e "s#$SRC#<src>#g" -e "s#$OUT#<out>#g" -e "s#$TC#<ndk-bin>#g" "$WORK/$abi-configure-cmd.txt"
    echo "files (stripped):"
    for name in $SO_NAMES; do
      f="$JNILIBS/$abi/$name"
      printf '  %-20s %9d bytes  sha256 %s\n' "$name" "$(wc -c < "$f" | tr -d ' ')" "$(shasum -a 256 "$f" | awk '{print $1}')"
    done
    echo
  done
} > "$INFO"

# ---- LGPL source package (not committed) ----
mkdir -p "$DIST"
cp "$WORK/$TARBALL" "$DIST/ffmpeg-$FFMPEG_VERSION-lgpl-source.tar.xz"
: > "$DIST/changes.diff"   # The FFmpeg sources are not changed. The file stays empty.
cp "$INFO" "$DIST/BUILD-INFO.txt"
cp "$SCRIPT_DIR/build.sh" "$SCRIPT_DIR/verify-so.sh" "$DIST/"
cp "$NATIVE/ffmpeg_jni.cc" "$NATIVE/CMakeLists.txt" "$DIST/"

echo "Done. Run: bash tools/ffmpeg/verify-so.sh ffmpeg-decoder/src/main/jniLibs tools/ffmpeg/work"

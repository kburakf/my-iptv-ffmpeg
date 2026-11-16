#!/usr/bin/env bash
# Check the FFmpeg .so files for 16 KB alignment, LGPL licensing and linking rules.
#
# Usage: bash tools/ffmpeg/verify-so.sh <jniLibs-dir | apk> [work-dir]
#   <jniLibs-dir>  folder with <abi>/*.so, for example ffmpeg-decoder/src/main/jniLibs
#   <apk>          APK file (also checks zipalign and the ABI folders)
#   [work-dir]     build work folder (tools/ffmpeg/work). Enables the configure and config.h checks.
# Output: one line per check, "OK" or "FAIL <reason>". Exit code 1 if any check fails.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <jniLibs-dir | apk> [work-dir]" >&2
  exit 2
fi
INPUT="$1"
WORK_ARG="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
NDK_VERSION="${NDK_VERSION:-30.0.16248370}"
BUILD_TOOLS="${BUILD_TOOLS:-37.0.0}"
TC="$ANDROID_SDK/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/darwin-x86_64/bin"
READELF="$TC/llvm-readelf"
ZIPALIGN="$ANDROID_SDK/build-tools/$BUILD_TOOLS/zipalign"
[[ -x "$READELF" ]] || { echo "ERROR: llvm-readelf not found: $READELF" >&2; exit 2; }

SO_NAMES="libavutil.so libswresample.so libavcodec.so libffmpegJNI.so"
ALLOWED_NEEDED=" libc.so libm.so libdl.so liblog.so libandroid.so libavcodec.so libavutil.so libswresample.so "
FAILS=0

fail() { echo "FAIL $1: $2"; FAILS=$((FAILS + 1)); }

join() { local IFS=';'; echo "$*"; }

# check_so <label> <file> <expected-soname>
check_so() {
  local label="$1" file="$2" name="$3" problems=() dyn prog
  # 1. Every LOAD segment has Align 0x4000.
  prog="$("$READELF" -lW "$file")"
  local load_count bad_load
  load_count="$(awk '$1 == "LOAD" {n++} END {print n + 0}' <<<"$prog")"
  bad_load="$(awk '$1 == "LOAD" && $NF != "0x4000" {n++} END {print n + 0}' <<<"$prog")"
  [[ "$load_count" -gt 0 ]] || problems+=("no LOAD segment")
  [[ "$bad_load" -eq 0 ]] || problems+=("$bad_load LOAD segment(s) without Align 0x4000")
  # 2. Dynamic section: no TEXTREL, correct SONAME and NEEDED.
  dyn="$("$READELF" -dW "$file")"
  if grep -q "TEXTREL" <<<"$dyn"; then problems+=("TEXTREL found"); fi
  local soname needed n
  soname="$(sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p' <<<"$dyn")"
  [[ "$soname" == "$name" ]] || problems+=("SONAME is '$soname', expected '$name'")
  needed="$(sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' <<<"$dyn")"
  for n in $needed; do
    [[ "$ALLOWED_NEEDED" == *" $n "* ]] || problems+=("unexpected NEEDED $n")
  done
  if [[ "$name" == "libffmpegJNI.so" ]]; then
    for n in libavcodec.so libavutil.so libswresample.so; do
      grep -qx "$n" <<<"$needed" || problems+=("missing NEEDED $n")
    done
  fi
  # 4. License text in libavcodec.
  if [[ "$name" == "libavcodec.so" ]]; then
    grep -aqF "LGPL version 2.1 or later" "$file" || problems+=("LGPL string not found")
    if grep -aqE -e "--enable-(gpl|nonfree|version3)" "$file"; then
      problems+=("GPL option in the embedded configuration string")
    fi
  fi
  if [[ ${#problems[@]} -eq 0 ]]; then
    echo "OK   $label"
  else
    fail "$label" "$(join "${problems[@]}")"
  fi
}

# check_work <abi>: configure log, configure command and config.h (plan D10).
check_work() {
  local abi="$1" w="$WORK_ARG" problems=()
  local log="$w/$abi-configure.log" cmd="$w/$abi-configure-cmd.txt" cfg="$w/build-$abi/config.h"
  if [[ ! -f "$log" || ! -f "$cmd" || ! -f "$cfg" ]]; then
    fail "$abi/configure" "log, command or config.h missing in $w"
    return
  fi
  grep -qF "License: LGPL version 2.1 or later" "$log" || problems+=("configure did not print the LGPL license")
  if grep -qE -e "--enable-(gpl|nonfree|version3)" "$cmd"; then problems+=("GPL option in the configure line"); fi
  grep -qF -e "--disable-autodetect" "$cmd" || problems+=("--disable-autodetect missing")
  grep -qE '^#define CONFIG_GPL 0$' "$cfg" || problems+=("CONFIG_GPL is not 0")
  grep -qE '^#define CONFIG_NONFREE 0$' "$cfg" || problems+=("CONFIG_NONFREE is not 0")
  grep -qE '^#define CONFIG_VERSION3 0$' "$cfg" || problems+=("CONFIG_VERSION3 is not 0")
  grep -qF '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$cfg" || problems+=("FFMPEG_LICENSE is not LGPL 2.1+")
  if [[ ${#problems[@]} -eq 0 ]]; then
    echo "OK   $abi/configure (log, command, config.h)"
  else
    fail "$abi/configure" "$(join "${problems[@]}")"
  fi
}

EXTRACT_DIR=""
cleanup() { if [[ -n "$EXTRACT_DIR" ]]; then rm -rf "${EXTRACT_DIR:?}"; fi; }
trap cleanup EXIT

if [[ -d "$INPUT" ]]; then
  ROOT="$INPUT"
  ABIS="$(cd "$ROOT" && ls -d */ 2>/dev/null | tr -d '/' | tr '\n' ' ')"
elif [[ -f "$INPUT" ]]; then
  [[ -x "$ZIPALIGN" ]] || { echo "ERROR: zipalign not found: $ZIPALIGN" >&2; exit 2; }
  if "$ZIPALIGN" -c -P 16 -v 4 "$INPUT" | tail -n 1 | grep -q "Verification successful"; then
    echo "OK   apk zipalign -P 16"
  else
    fail "apk" "zipalign -P 16 check failed"
  fi
  EXTRACT_PARENT="${WORK_ARG:-$SCRIPT_DIR/work}"
  mkdir -p "$EXTRACT_PARENT"
  EXTRACT_DIR="$(mktemp -d "$EXTRACT_PARENT/verify-apk.XXXXXX")"
  unzip -q "$INPUT" 'lib/*' -d "$EXTRACT_DIR"
  ROOT="$EXTRACT_DIR/lib"
  ABIS="$(cd "$ROOT" && ls -d */ | tr -d '/' | sort | tr '\n' ' ')"
  if [[ "$ABIS" == "arm64-v8a armeabi-v7a " ]]; then
    echo "OK   apk ABI folders: $ABIS"
  else
    fail "apk" "ABI folders are '$ABIS', expected 'arm64-v8a armeabi-v7a'"
  fi
else
  echo "ERROR: $INPUT is not a folder or a file." >&2
  exit 2
fi

[[ -n "$ABIS" ]] || { echo "ERROR: no ABI folder in $INPUT" >&2; exit 2; }

for abi in $ABIS; do
  for name in $SO_NAMES; do
    if [[ -f "$ROOT/$abi/$name" ]]; then
      check_so "$abi/$name" "$ROOT/$abi/$name" "$name"
    else
      fail "$abi/$name" "file missing"
    fi
  done
  if [[ -d "$INPUT" ]]; then
    count="$(find "$ROOT/$abi" -maxdepth 1 -name '*.so' | wc -l | tr -d ' ')"
    [[ "$count" -eq 4 ]] || fail "$abi" "expected 4 .so files, found $count"
    [[ -z "$WORK_ARG" ]] || check_work "$abi"
  fi
done

if [[ "$FAILS" -gt 0 ]]; then
  echo "RESULT: $FAILS check(s) failed."
  exit 1
fi
echo "RESULT: all checks OK."

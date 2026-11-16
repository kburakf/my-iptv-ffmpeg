# FFmpeg source for the my-iptv Android TV app

This repository holds the complete source for the FFmpeg libraries that the my-iptv Android TV app contains.
The app uses FFmpeg as shared libraries under the GNU Lesser General Public License, version 2.1 or later (LGPL).
The full license text is in [LICENSE](LICENSE).

## Releases

Each app release that contains new FFmpeg libraries has 1 folder in `releases/`.
We keep each folder for 3 years or more.

| Folder | FFmpeg | Media3 | ABIs | Decoders |
|---|---|---|---|---|
| [releases/2026-11-16-n7.1.5](releases/2026-11-16-n7.1.5) | n7.1.5 | 1.11.1 | armeabi-v7a, arm64-v8a | ac3, eac3, dca, mp3, truehd, mlp |

## Content of a release folder

- `ffmpeg-<version>-lgpl-source.tar.xz`: the official FFmpeg release tarball from ffmpeg.org. The SHA-256 is in `BUILD-INFO.txt`.
- `changes.diff`: our changes to the FFmpeg source. An empty file means: no changes.
- `BUILD-INFO.txt`: the full configure line, the NDK version, the API level, and the size and SHA-256 of each library.
- `build.sh`: the script that builds the libraries.
- `verify-so.sh`: the script that checks the libraries (16 KB page alignment, no GPL flags).
- `ffmpeg_jni.cc`, `CMakeLists.txt`: the JNI wrapper of the AndroidX Media3 FFmpeg decoder module, unchanged (Apache License 2.0, Copyright The Android Open Source Project).

## Libraries in the app

- `libavcodec.so`, `libavutil.so`, `libswresample.so` (FFmpeg, LGPL v2.1 or later).
- `libffmpegJNI.so` (Media3 JNI wrapper, Apache License 2.0).

The libraries are shared. The build uses no `--enable-gpl`, `--enable-nonfree` or `--enable-version3` flag.

## Build the libraries again

1. Install the Android SDK, NDK `30.0.16248370`, and CMake `3.22.1` from the SDK manager.
2. Make an empty folder `<root>` and put the files of 1 release folder into it like this:
   - `build.sh`, `verify-so.sh` → `<root>/tools/ffmpeg/`
   - `ffmpeg-7.1.5-lgpl-source.tar.xz` → `<root>/tools/ffmpeg/work/ffmpeg-7.1.5.tar.xz`
   - `ffmpeg_jni.cc`, `CMakeLists.txt` → `<root>/ffmpeg-decoder/native/`
3. Run `bash tools/ffmpeg/build.sh` in `<root>`. The libraries go to `<root>/ffmpeg-decoder/src/main/jniLibs/<abi>/`.
4. Run `bash tools/ffmpeg/verify-so.sh ffmpeg-decoder/src/main/jniLibs tools/ffmpeg/work`. It must print `RESULT: all checks OK.`.

## Replace the libraries in the app

The LGPL gives you the right to use a changed version of these libraries with the app.
Build your version with the same ABI and the same exported symbols, then put the `.so` files into the APK in place of the old ones.
A changed APK must be signed again with your own key.

## Contact

Open an issue in this repository for questions about this source package.

FFmpeg is a trademark of Fabrice Bellard, the originator of the FFmpeg project.

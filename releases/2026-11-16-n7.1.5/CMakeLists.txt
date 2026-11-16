#
# Copyright 2021 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Changed from the upstream file (androidx/media tag 1.11.1):
# - The FFmpeg libraries are SHARED imported libraries (libavcodec.so and others).
# - The FFmpeg install folder comes from -DFFMPEG_PREFIX (see tools/ffmpeg/build.sh).
# - The link options set 16 KB page alignment.
cmake_minimum_required(VERSION 3.21.0 FATAL_ERROR)

# Enable C++11 features.
set(CMAKE_CXX_STANDARD 11)

project(libffmpegJNI C CXX)

if(NOT DEFINED FFMPEG_PREFIX)
    message(FATAL_ERROR "Set -DFFMPEG_PREFIX to the FFmpeg install folder.")
endif()

foreach(ffmpeg_lib avutil swresample avcodec)
    add_library(
            ${ffmpeg_lib}
            SHARED
            IMPORTED)
    set_target_properties(
            ${ffmpeg_lib} PROPERTIES
            IMPORTED_LOCATION
            ${FFMPEG_PREFIX}/lib/lib${ffmpeg_lib}.so)
endforeach()

include_directories(${FFMPEG_PREFIX}/include)
find_library(android_log_lib log)

add_library(ffmpegJNI
            SHARED
            ffmpeg_jni.cc)

set_target_properties(ffmpegJNI PROPERTIES
                      CXX_VISIBILITY_PRESET hidden
                      VISIBILITY_INLINES_HIDDEN ON)

target_link_libraries(ffmpegJNI
                      PRIVATE android
                      PRIVATE swresample
                      PRIVATE avcodec
                      PRIVATE avutil
                      PRIVATE ${android_log_lib})

# Align the segments to 16 KB pages.
target_link_options(ffmpegJNI PRIVATE
                    "-Wl,-z,max-page-size=16384"
                    "-Wl,-z,common-page-size=16384")

# Additional flags needed for "arm64-v8a" from NDK 23.1.7779620 and above.
# See https://github.com/google/ExoPlayer/issues/9933#issuecomment-1029775358.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    target_link_options(ffmpegJNI PRIVATE "-Wl,-Bsymbolic")
endif()


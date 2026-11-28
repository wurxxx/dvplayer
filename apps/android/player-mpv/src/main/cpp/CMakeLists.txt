cmake_minimum_required(VERSION 3.22)
project(dvplayer_mpv CXX)

# libmpv 的 .so 由 scripts/android/build-mpv.sh 产出，不在仓库里；头文件随仓库走
# （include/mpv 是 mpv 0.42.0 的 client/render/render_gl，LGPL-2.1+）。
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(MPV_ARCH arm64)
elseif(ANDROID_ABI STREQUAL "x86_64")
    set(MPV_ARCH x86_64)
else()
    message(FATAL_ERROR "不支持的 ABI：${ANDROID_ABI}")
endif()

set(MPV_PREFIX "${MPV_ROOT}/${MPV_ARCH}/prefix")
if(NOT EXISTS "${MPV_PREFIX}/lib/libmpv.so")
    message(FATAL_ERROR "找不到 ${MPV_PREFIX}/lib/libmpv.so，先跑 scripts/android/build-mpv.sh")
endif()

add_library(mpv SHARED IMPORTED)
set_target_properties(mpv PROPERTIES IMPORTED_LOCATION "${MPV_PREFIX}/lib/libmpv.so")

add_library(dvplayer_mpv SHARED mpv_gl.cpp)

target_include_directories(dvplayer_mpv PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_options(dvplayer_mpv PRIVATE -Wall -Wextra -Wno-unused-parameter)
target_link_libraries(dvplayer_mpv mpv EGL GLESv2 android log)

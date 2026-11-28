#!/usr/bin/env bash
# Android / Android TV 构建环境（A0）。
#
# 桌面端的 scripts/env.sh 只准备 macOS 原生栈（prefix/ 里的 mpv 等）；
# Android 是另一套：JDK 17（桌面用 11）、SDK 36、NDK r28、cargo-ndk、meson/ninja。
#
#   source scripts/android/env.sh
#
# 所有变量都带默认值，已经显式设置过的不覆盖。

DVPLAYER_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
export DVPLAYER_ROOT

# ---- Android SDK / NDK
export ANDROID_HOME=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/Volumes/data/dev/Android/sdk}}
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}
export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
export NDK_HOME=$ANDROID_NDK_HOME

# ---- Gradle 依赖镜像
# 国内直连 Maven Central 只有几百 KB/s；阿里云镜像能到 10MB/s 以上。
# 想强制走官方仓库就 `DVPLAYER_MAVEN_MIRROR= source scripts/android/env.sh`。
export DVPLAYER_MAVEN_MIRROR=${DVPLAYER_MAVEN_MIRROR-https://maven.aliyun.com/repository}

# ---- GitHub 下载镜像
# github.com 的 Release 资产在这台机器上经常几十 KB/s 或直接超时。
# 构建脚本只对 github.com 的 URL 套这个前缀；CI 上设空串直连。
export DVPLAYER_GH_PROXY=${DVPLAYER_GH_PROXY-https://v4.gh-proxy.com}

# ---- JDK 17（AGP 8 要求 17；本机默认 JAVA_HOME 为空）
if [ -z "${JAVA_HOME:-}" ] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -q 'version "17'; then
    _jdk17=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
    if [ -n "$_jdk17" ]; then
        export JAVA_HOME=$_jdk17
    fi
    unset _jdk17
fi

# ---- PATH：JDK、cargo、pip --user 的 meson/ninja、SDK 工具
for _dir in \
    "${JAVA_HOME:-}/bin" \
    "$HOME/.cargo/bin" \
    "$ANDROID_HOME/platform-tools" \
    "$ANDROID_HOME/emulator" \
    "$ANDROID_HOME/cmdline-tools/latest/bin"; do
    [ -n "$_dir" ] && [ -d "$_dir" ] || continue
    case ":$PATH:" in
        *":$_dir:"*) ;;
        *) PATH="$_dir:$PATH" ;;
    esac
done
for _dir in "$HOME"/Library/Python/*/bin "$HOME"/.local/bin; do
    [ -n "$_dir" ] && [ -d "$_dir" ] || continue
    case ":$PATH:" in
        *":$_dir:"*) ;;
        *) PATH="$_dir:$PATH" ;;
    esac
done
unset _dir
export PATH

# 被直接执行（而不是 source）时，把关键路径打出来，方便排查。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    echo "JAVA_HOME=$JAVA_HOME"
    echo "ANDROID_HOME=$ANDROID_HOME"
    echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
    command -v java cargo cargo-ndk meson ninja sdkmanager adb 2>/dev/null | sed 's/^/  /'
fi

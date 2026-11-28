#!/bin/sh
# 发布前校验共享核心版本。
#
# 共享核心（core/Cargo.toml 的 [workspace.package] version）独立演进：应用版本
# 只用于安装包 / 关于页，核心版本由 core/ 自己的改动决定。自上一个发布 tag 起
# core/ 有任何改动（代码、依赖、成员）时，发布前必须提升核心版本，否则会复现
# 「应用 0.1.7 了，关于页里共享核心还是 0.1.4」。
#
#   sh scripts/check-core-version.sh              # 和上一个 v* tag 比
#   sh scripts/check-core-version.sh v0.1.6       # 和指定 tag 比（排查用）
#
# 退出码：0 通过（含无需提升）；1 需要提升；2 环境 / 文件读不到。
#
# 只校验、不改文件：版本号由发布者改一次再提交。多端 CI 并行时每个 job
# 读的是同一份 core/Cargo.toml，不会各自累加版本。
set -eu

tag=${1:-}

if [ -z "$tag" ]; then
    tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)
    if [ -z "$tag" ]; then
        echo "没有 v* tag，跳过核心版本校验。"
        exit 0
    fi
    # 打 tag 的那次 CI 里 HEAD 就是 tag 本身，要和它的前一个 tag 比。
    if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$tag^{commit}")" ]; then
        tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$tag^" 2>/dev/null || true)
        if [ -z "$tag" ]; then
            echo "只有 $tag 一个 v* tag，跳过核心版本校验。"
            exit 0
        fi
    fi
fi

# 从 core/Cargo.toml 的 [workspace.package] 段里取 version。
core_version() {
    # $1 为空：读工作区文件；否则读该 ref 里的版本。
    if [ -z "$1" ]; then
        cat core/Cargo.toml
    else
        git show "$1:core/Cargo.toml" 2>/dev/null
    fi | awk '
        /^\[workspace\.package\]/ { pkg = 1; next }
        /^\[/ { pkg = 0 }
        pkg && $1 == "version" {
            value = $0
            sub(/^[^"]*"/, "", value)
            sub(/".*$/, "", value)
            print value
            exit
        }'
}

# $1 是否大于 $2（按点分数字比较）。
version_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, A, "."); nb = split(b, B, ".")
        n = (na > nb ? na : nb)
        for (i = 1; i <= n; i++) {
            x = (i <= na ? A[i] : 0) + 0
            y = (i <= nb ? B[i] : 0) + 0
            if (x > y) exit 0
            if (x < y) exit 1
        }
        exit 1
    }'
}

old=$(core_version "$tag")
[ -n "$old" ] || { echo "读不到 $tag 的 core/Cargo.toml 版本。" >&2; exit 2; }
new=$(core_version "")
[ -n "$new" ] || { echo "读不到 core/Cargo.toml 的版本。" >&2; exit 2; }

changed=$(git diff --name-only "$tag" -- core)
if [ -z "$changed" ]; then
    echo "core/ 自 ${tag} 起没有改动，核心版本保持 ${new}。"
    exit 0
fi

if version_gt "$new" "$old"; then
    echo "core/ 自 ${tag} 起有改动，核心版本 ${old} → ${new}，通过。"
    exit 0
fi

cat >&2 <<EOF
错误：core/ 自 ${tag} 起有改动，但共享核心版本仍是 ${new}（基线 ${old}）。

共享核心版本独立于应用版本，核心代码 / 依赖 / 成员有改动时，发布前必须提升：

  core/Cargo.toml  [workspace.package] version = "<比 ${old} 大的版本>"

然后重编三端核心（macOS dylib、Windows dll、Android .so），再提交、打 tag。
应用版本（Info.plist / DvPlayer.csproj）照旧单独改。
EOF
exit 1

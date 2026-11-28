#!/usr/bin/env bash
# 在 macOS 上开一个只给局域网用的 NFSv3 导出（A9 真机对照用）。
#
# 需要 sudo（改 /etc/exports、启停 nfsd），所以不在自动化里跑，手动执行：
#
#   tests/android/nfs-export.sh create      # 建导出并把客户端地址打出来
#   tests/android/nfs-export.sh remove      # 撤掉导出、恢复 /etc/exports
#
# 默认导出目录：/Volumes/data/tmp/dvplayer-nfs（可用 EXPORT_DIR 覆盖）。
# 只放行当前网段，`-mapall` 映射到当前用户：客户端用匿名 uid 也能读。
set -u

EXPORT_DIR="${EXPORT_DIR:-/Volumes/data/tmp/dvplayer-nfs}"
EXPORTS=/etc/exports
BACKUP=/etc/exports.dvplayer-backup

lan_ip() {
    for iface in en0 en1 en2; do
        ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
        if [ -n "$ip" ]; then
            echo "$ip"
            return
        fi
    done
    echo "127.0.0.1"
}

# 用临时文件读写，避免 grep 与 tee 同时动同一个文件。
rewrite_exports() { # $1 = 要删掉的行前缀（可空）
    local drop="${1:-}"
    local tmp
    tmp=$(mktemp)
    if [ -f "$EXPORTS" ]; then
        if [ -n "$drop" ]; then
            grep -vF "$drop" "$EXPORTS" >"$tmp" || true
        else
            cat "$EXPORTS" >"$tmp"
        fi
    fi
    if [ -n "${ADD_LINE:-}" ]; then
        echo "$ADD_LINE" >>"$tmp"
    fi
    sudo cp "$tmp" "$EXPORTS"
    rm -f "$tmp"
}

case "${1:-}" in
create)
    mkdir -p "$EXPORT_DIR"
    if [ -z "$(ls -A "$EXPORT_DIR" 2>/dev/null)" ]; then
        echo "导出目录是空的；放点东西再测播放，例如："
        echo "  cp samples/p5.mkv \"$EXPORT_DIR/\""
    fi
    if [ -f "$EXPORTS" ] && [ ! -f "$BACKUP" ]; then
        sudo cp "$EXPORTS" "$BACKUP"
    fi
    ADD_LINE="$EXPORT_DIR -alldirs -mapall=$(id -u):$(id -g) -network $(lan_ip | cut -d. -f1-3).0.0 -mask 255.255.255.0"
    rewrite_exports "$EXPORT_DIR "
    sudo nfsd enable || true
    sudo nfsd restart || sudo nfsd update
    echo "导出目录：$EXPORT_DIR"
    echo "客户端地址：nfs://$(lan_ip)$EXPORT_DIR"
    echo "-- showmount -e localhost --"
    showmount -e localhost 2>/dev/null || echo "（showmount 不可用，直接看 /etc/exports）"
    ;;
remove)
    if [ -f "$BACKUP" ]; then
        sudo cp "$BACKUP" "$EXPORTS"
        sudo rm -f "$BACKUP"
    else
        ADD_LINE=""
        rewrite_exports "$EXPORT_DIR "
    fi
    sudo nfsd restart || true
    echo "已从 $EXPORTS 撤掉 $EXPORT_DIR（目录本身保留）"
    ;;
*)
    echo "用法：$0 create|remove"
    exit 2
    ;;
esac

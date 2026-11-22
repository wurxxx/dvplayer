#!/usr/bin/env bash
# 在 NAS 上扫描 Dolby Vision 片源，挑出 Profile 7（双层）。
# 用法: nas-scan-dv.sh [额外要探的文件...]
# 需要环境变量：NAS_USER、NAS_PASS
set -euo pipefail

: "${NAS_USER:?NAS_USER is required}"
: "${NAS_PASS:?NAS_PASS is required}"

HOST=10.0.0.100
ROOT_DIR=${NAS_SCAN_DIR:-/vol1/1000/影视}
MAX_FILES=${NAS_SCAN_MAX:-300}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$NAS_PASS"
EOF
chmod 700 "$TMP/askpass"

# ssh 会把后面的所有参数用空格拼成一条命令再交给远端 shell 解析：
# 带空格 / 引号的文件名会被拆开，甚至被当成命令执行。手动套 POSIX 单引号。
quote() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

ssh_run() {
  SSH_ASKPASS="$TMP/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=8 \
        -o NumberOfPasswordPrompts=1 \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$NAS_USER@$HOST" "$@"
}

cat > "$TMP/scan.sh" <<'EOS'
set -u
ROOT_DIR=$1
MAX_FILES=$2
MODE=$3
shift 3

probe() {
  f=$1
  out=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data \
        -of default=nw=1 "$f" 2>/dev/null | tr '\n' ' ')
  case "$out" in
    *dv_profile*)
      prof=$(printf '%s' "$out" | sed -n 's/.*dv_profile=\([0-9]*\).*/\1/p')
      el=$(printf '%s' "$out" | sed -n 's/.*el_present_flag=\([0-9]*\).*/\1/p')
      bl=$(printf '%s' "$out" | sed -n 's/.*bl_present_flag=\([0-9]*\).*/\1/p')
      compat=$(printf '%s' "$out" | sed -n 's/.*dv_bl_signal_compatibility_id=\([0-9]*\).*/\1/p')
      pix=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f" 2>/dev/null)
      tracks=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$f" 2>/dev/null | wc -l | tr -d ' ')
      printf 'DV  p=%s el=%s bl=%s compat=%s pix=%s vtracks=%s  %s\n' \
        "${prof:--}" "${el:--}" "${bl:--}" "${compat:--}" "${pix:--}" "$tracks" "$f"
      ;;
  esac
}

# 1) 显式指定的文件（远端 set -u：没有额外参数时 "$@" 在旧 bash 下会报 unbound）
for f in ${1+"$@"}; do
  [ -f "$f" ] || { echo "MISSING  $f"; continue; }
  echo "== 指定文件 =="
  ls -l "$f"
  echo
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt \
    -show_entries stream_side_data -of default=nw=1 "$f"
  echo
done

# 2) 目录扫描：只挑 8GB 以上、2160p/UHD 的片源（双层 DV 只出现在 4K 盘源里）
echo
echo "== 扫描 $ROOT_DIR（最多 $MAX_FILES 个）=="
n=0
find "$ROOT_DIR" -type f \
  \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m2ts' \) \
  -size +8G 2>/dev/null \
| grep -iE '2160p|UHD|4K|DoVi|DV\.|\.DV\.' \
| grep -ivE '720p|1080p|1080i' \
| sort > /tmp/dvscan.$$
total=$(wc -l < /tmp/dvscan.$$ | tr -d ' ')
echo "候选文件: $total"

if [ "${MODE:-dv}" = "multi" ]; then
  # 双轨 P7（BL/EL 各一条轨）在容器里可能没有 DOVI 记录，只能按轨数找
  echo "模式: 查找多视频轨文件"
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -gt "$MAX_FILES" ] && break
    info=$(ffprobe -v error -select_streams v \
             -show_entries stream=codec_name,width,height -of csv=p=0 "$f" 2>/dev/null)
    cnt=$(printf '%s\n' "$info" | grep -c . || true)
    if [ "$cnt" -gt 1 ]; then
      printf 'MULTI vtracks=%s  %s\n' "$cnt" "$f"
      printf '%s\n' "$info" | sed 's/^/      /'
    fi
  done < /tmp/dvscan.$$
  rm -f /tmp/dvscan.$$
  echo "扫完: 检查了 $n 个文件"
  exit 0
fi

while IFS= read -r f; do
  n=$((n + 1))
  [ "$n" -gt "$MAX_FILES" ] && { echo "达到上限 $MAX_FILES，停止"; break; }
  printf '[%d/%d] %s\n' "$n" "$MAX_FILES" "$(basename "$f")" >&2
  probe "$f"
done < /tmp/dvscan.$$
rm -f /tmp/dvscan.$$
echo "扫完: 探测了 $n 个文件"
EOS

remote_cmd="bash -s"
for arg in "$ROOT_DIR" "$MAX_FILES" "${NAS_SCAN_MODE:-dv}" "$@"; do
  remote_cmd+=" $(quote "$arg")"
done
ssh_run "$remote_cmd" < "$TMP/scan.sh"

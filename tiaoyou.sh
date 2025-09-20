#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# BBR+fq TCP 调优 + 冲突清理（智能版：自动识别SSH客户端IP）
# - 新增：优先自动从SSH连接中获取客户端IP进行RTT测试，失败则回退到手动输入
# - 计算：BDP(bytes)=Mbps*125*ms；max = min(2*BDP, 3%RAM, 64MB)；向下桶化至 {4,8,16,32,64}MB
# - 写入：/etc/sysctl.d/999-net-bbr-fq.conf
# - 清理：备份并注释 /etc/sysctl.conf 的冲突键；备份并移除 /etc/sysctl.d/*.conf 中含冲突键的旧文件
# - 其他目录（/usr/lib|/lib|/usr/local/lib|/run/sysctl.d）：仅提示不改
# =========================================================

note() { echo -e "\033[1;34m[i]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
bad()  { echo -e "\033[1;31m[!!]\033[0m $*"; }

# --- 自动检测函数 ---
get_mem_gib() {
  local mem_bytes
  mem_bytes=$(free -b | awk '/^Mem:/ {print $2}')
  awk -v bytes="$mem_bytes" 'BEGIN {printf "%.2f", bytes / 1024^3}'
}

get_rtt_ms() {
  local ping_target=""
  local ping_desc=""

  # --- MODIFIED: Smart RTT detection ---
  # 1. 优先尝试从 SSH 环境变量中自动获取客户端 IP
  if [ -n "$SSH_CONNECTION" ]; then
    ping_target=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    ping_desc="SSH 客户端 ${ping_target}"
    note "成功从 SSH 连接中自动检测到客户端 IP: ${ping_target}"
  else
    # 2. 如果 SSH 变量不存在（例如在VNC或物理终端运行），则回退到手动输入
    note "未检测到 SSH 连接环境，需要您提供一个客户机IP。"
    local client_ip
    read -r -p "请输入一个代表性客户机IP进行ping测试 (直接回车则ping 1.1.1.1): " client_ip
    if [ -n "$client_ip" ]; then
      ping_target="$client_ip"
      ping_desc="客户机IP ${ping_target}"
    fi
  fi
  
  # 3. 如果以上两种方式都没有获得IP，则使用最终的公共地址
  if [ -z "$ping_target" ]; then
    ping_target="1.1.1.1"
    ping_desc="公共地址 ${ping_target} (通用网络)"
    note "未提供IP，将使用 ${ping_desc} 进行测试。"
  fi

  note "正在通过 ping ${ping_desc} 测试网络延迟..."
  local ping_result
  ping_result=$(ping -c 4 -W 2 "$ping_target" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
  
  if [[ "$ping_result" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    ok "检测到平均 RTT: ${ping_result} ms"
    printf "%.0f" "$ping_result"
  else
    warn "Ping ${ping_target} 失败，无法检测 RTT。将使用默认值 150 ms。"
    echo "150"
  fi
}

# --- 使用自动检测的值作为默认值 ---
DEFAULT_MEM_G=$(get_mem_gib)
DEFAULT_RTT_MS=$(get_rtt_ms)
DEFAULT_BW_Mbps=1000

read -r -p "内存大小 (GiB) [自动检测: ${DEFAULT_MEM_G}] : " MEM_G_INPUT
read -r -p "带宽 (Mbps) [默认: ${DEFAULT_BW_Mbps}] : " BW_Mbps_INPUT
read -r -p "往返延迟 RTT (ms) [自动检测: ${DEFAULT_RTT_MS}] : " RTT_ms_INPUT

MEM_G="${MEM_G_INPUT:-$DEFAULT_MEM_G}"
BW_Mbps="${BW_Mbps_INPUT:-$DEFAULT_BW_Mbps}"
RTT_ms="${RTT_ms_INPUT:-$DEFAULT_RTT_MS}"

is_num() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_num "$MEM_G"    || MEM_G="$DEFAULT_MEM_G"
is_int "$BW_Mbps" || BW_Mbps="$DEFAULT_BW_Mbps"
is_num "$RTT_ms"  || RTT_ms="$DEFAULT_RTT_MS"

SYSCTL_TARGET="/etc/sysctl.d/999-net-bbr-fq.conf"
KEY_REGEX='^(net\.core\.default_qdisc|net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.rmem_default|net\.core\.wmem_default|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.ipv4\.tcp_congestion_control)[[:space:]]*='

require_root() { if [ "${EUID:-$(id -u)}" -ne 0 ]; then bad "请以 root 运行"; exit 1; fi; }
default_iface(){ ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true; }

# ---- 计算（逐步校验）----
BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
TWO_BDP=$(( BDP_BYTES*2 ))
RAM3_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{ printf "%.0f", m*0.03 }')
CAP64=$(( 64*1024*1024 ))
MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM3_BYTES" -v c="$CAP64" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

bucket_le_mb() {
  local mb="${1:-0}"
  if   [ "$mb" -ge 64 ]; then echo 64
  elif [ "$mb" -ge 32 ]; then echo 32
  elif [ "$mb" -ge 16 ]; then echo 16
  elif [ "$mb" -ge  8 ]; then echo 8
  elif [ "$mb" -ge  4 ]; then echo 4
  else echo 4
  fi
}
MAX_MB_NUM=$(( MAX_NUM_BYTES/1024/1024 ))
MAX_MB=$(bucket_le_mb "$MAX_MB_NUM")
MAX_BYTES=$(( MAX_MB*1024*1024 ))

if [ "$MAX_MB" -ge 32 ]; then
  DEF_R=262144; DEF_W=524288
elif [ "$MAX_MB" -ge 8 ]; then
  DEF_R=131072; DEF_W=262144
else
  DEF_R=131072; DEF_W=131072
fi

TCP_RMEM_MIN=4096; TCP_RMEM_DEF=87380; TCP_RMEM_MAX=$MAX_BYTES
TCP_WMEM_MIN=4_REPLACED_096; TCP_WMEM_DEF=65536; TCP_WMEM_MAX=$MAX_BYTES

# ---- 冲突清理 ----
comment_conflicts_in_sysctl_conf() {
  local f="/etc/sysctl.conf"
  [ -f "$f" ] || { ok "/etc/sysctl.conf 不存在"; return 0; }
  if grep -Eq "$KEY_REGEX" "$f"; then
    local backup_file="${f}.bak.$(date +%Y%m%d-%H%M%S)"
    note "发现冲突，备份 /etc/sysctl.conf 至 ${backup_file}"
    cp -a "$f" "$backup_file"
    
    note "注释 /etc/sysctl.conf 中的冲突键"
    awk -v re="$KEY_REGEX" '
      $0 ~ re && $0 !~ /^[[:space:]]*#/ { print "# " $0; next }
      { print $0 }
    ' "$f" > "${f}.tmp.$$"
    install -m 0644 "${f}.tmp.$$" "$f"
    rm -f "${f}.tmp.$$"
    ok "已注释掉冲突键"
  else
    ok "/etc/sysctl.conf 无冲突键"
  fi
}

delete_conflict_files_in_dir() {
  local dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  shopt -s nullglob
  local moved=0
  local backup_suffix=".bak.$(date +%Y%m%d-%H%M%S)"
  for f in "$dir"/*.conf; do
    [ "$(readlink -f "$f")" = "$(readlink -f "$SYSCTL_TARGET")" ] && continue
    if grep -Eq "$KEY_REGEX" "$f"; then
      local backup_file="${f}${backup_suffix}"
      mv -- "$f" "$backup_file"
      note "已备份并移除冲突文件: $f -> $backup_file"
      moved=1
    fi
  done
  shopt -u nullglob
  [ "$moved" -eq 1 ] && ok "$dir 中的冲突文件已处理" || ok "$dir 无需处理"
}

scan_conflicts_ro() {
  local dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  if grep -RIlEq "$KEY_REGEX" "$dir" 2>/dev/null; then
    warn "发现潜在冲突（只提示不改）：$dir"
    grep -RhnE "$KEY_REGEX" "$dir" 2>/dev/null || true
  else
    ok "$dir 未发现冲突"
  fi
}

require_root
note "步骤A：备份并注释 /etc/sysctl.conf 冲突键"
comment_conflicts_in_sysctl_conf

note "步骤B：备份并移除 /etc/sysctl.d 下含冲突键的旧文件"
delete_conflict_files_in_dir "/etc/sysctl.d"

note "步骤C：扫描其他目录（只读提示，不改）"
/usr/bin/true
scan_conflicts_ro "/usr/local/lib/sysctl.d"
scan_conflicts_ro "/usr/lib/sysctl.d"
scan_conflicts_ro "/lib/sysctl.d"
scan_conflicts_ro "/run/sysctl.d"

# ---- 启用 BBR 模块（若为内置则无影响）----
if command -v modprobe >/dev/null 2>&1; then modprobe tcp_bbr 2>/dev/null || true; fi

# ---- 写入并应用 ----
tmpf="$(mktemp)"
cat >"$tmpf" <<EOF
# Auto-generated by net-tcp-tune (smart-detect + backup-conflicts)
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB)
# Caps: min(2*BDP, 3%RAM, 64MB) -> Bucket ${MAX_MB} MB

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}

net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
EOF
install -m 0644 "$tmpf" "$SYSCTL_TARGET"
rm -f "$tmpf"

sysctl --system >/dev/null

IFACE="$(default_iface)"
if command -v tc >/dev/null 2>&1 && [ -n "${IFACE:-}" ]; then
  tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
fi

echo "==== RESULT ===="
echo "最终使用值 -> 内存: ${MEM_G} GiB, 带宽: ${BW_Mbps} Mbps, RTT: ${RTT_ms} ms"
echo "计算出的桶值: ${MAX_MB} MB"
sysctl -n net.ipv4.tcp_congestion_control
sysctl -n net.core.default_qdisc
sysctl -n net.core.rmem_max
sysctl -n net.core.wmem_max
sysctl -n net.ipv4.tcp_rmem
sysctl -n net.ipv4.tcp_wmem
if command -v tc >/dev/null 2>&1 && [ -n "${IFACE:-}" ]; then
  echo "qdisc on ${IFACE}:"; tc qdisc show dev "$IFACE" || true
fi
echo "==============="

note "复核：查看加载顺序及最终值来源（只读）"
sysctl --system 2>&1 | grep -nE --color=never 'Applying|net\.core\.(rmem|wmem)|net\.core\.default_qdisc|net\.ipv4\.tcp_(rmem|wmem)|tcp_congestion_control' || true

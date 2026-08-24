#!/system/bin/sh
# ============================================================
# BoxFix v10 自适应协调器 + 故障自动降级
#
# 相比 v9 的改进：
#   1. 【修复重启 Box 问题】等待 sys.boot_completed 后再进入主循环，
#      避免开机时 Box 尚未完成自身启动就被 BoxFix 干扰重启
#   2. 每次启动先等待 Box 代理可达（最多 10 分钟），不再立即降级，
#      避免 Box 启动慢时被误降级
#   3. 仅在配置真正变化时才重启 Box（减少无谓重启）
#   4. 集成 aghctl 统一管理，状态写入 state 目录供 Web 面板读取
#   5. 降级恢复后做一次完整同步（不再依赖连续检测）
#
#  - Box 存在   -> AGH 作为广告过滤上游（不劫持 53），mihomo nameserver 自动同步到 AGH 实际 DNS 端口
#                  random 模式随机端口、fixed 模式固定 5591，两者均自动同步
#  - Box 不存在 -> AGH 随机端口独立模式，iptables 劫持 53 做广告过滤
#  - 分流原则   -> 域名规则命中走对应策略，cn_ip/private_ip 兜底国内直连，最后 MATCH 走代理
#  - 默认修正   -> 强制开启 IPv6（解决 IPv6 关闭导致的 Google 等连接失败）；确保 cn_ip 直连兜底存在
# 安装顺序无关，独立使用兼容，全程无需用户干预
CFG="/data/adb/box/mihomo/config.yaml"
BOX_DIR="/data/adb/box"
RESTART_CMD="/data/adb/box/scripts/box.service restart"
LOG="/data/adb/agh/agh.log"
MODE_FILE="/data/adb/agh/.port_mode"
SCRIPT_DIR="/data/adb/agh/scripts"
BIN_DIR="/data/adb/agh/bin"
MARK="/data/adb/box/mihomo/.agh_fixed_v9"
DEGRADED_FLAG="/data/adb/box/mihomo/.degraded"
YAML="$BIN_DIR/AdGuardHome.yaml"
STATE_DIR="/data/adb/agh/state"
CTL="$SCRIPT_DIR/aghctl"

mkdir -p "$STATE_DIR"

# 防止重复启动（基于进程名匹配，避免 -f 全路径误匹配 shell/调试进程）
[ "$(pgrep -f "scripts/BoxFix.sh" | wc -l)" -gt 2 ] && exit

log() { echo "$(date '+%F %T') [BoxFix] $*" >> "$LOG"; }

# 等待系统完全开机（最多 5 分钟）
wait_for_boot() {
  local i=0
  while [ "$(getprop sys.boot_completed)" != "1" ]; do
    i=$((i + 1))
    if [ $i -ge 150 ]; then
      log "警告：5 分钟未等到开机完成，继续执行"
      return
    fi
    sleep 2
  done
  log "系统开机完成"
}

# 等待 Box 代理可达（最多 10 分钟，期间仅记录不降级）
wait_for_proxy() {
  local i=0
  while [ $i -lt 200 ]; do
    if proxy_reachable; then
      [ $i -gt 0 ] && log "代理在第 ${i} 次检测时可达"
      return 0
    fi
    i=$((i + 1))
    [ $((i % 10)) -eq 0 ] && log "等待代理启动... (${i}/200)"
    sleep 3
  done
  log "10 分钟内代理始终不可达，交由主循环降级"
  return 1
}

# Box 是否已安装（存在运行目录与 mihomo 配置）
box_installed() {
  [ -d "$BOX_DIR" ] && [ -f "$CFG" ]
}

# 检查代理是否可用（mihomo 进程存活 + DNS 监听端口可达）
proxy_reachable() {
  pgrep -f "mihomo" >/dev/null 2>&1 || return 1
  timeout 2 sh -c 'echo > /dev/tcp/127.0.0.1/1053' >/dev/null 2>&1 && return 0
  timeout 2 ss -tln 2>/dev/null | grep -q ":1053 " && return 0
  return 1
}

# 读取 AGH 实际 DNS 端口（yaml 优先，config.prop 兜底）
get_agh_port() {
  local p
  p=$(awk '/^[[:space:]]*dns:/{f=1;next} f&&/^[[:space:]]*port:/{gsub(/[^0-9]/,"",$NF);print $NF;exit}' "$YAML" 2>/dev/null)
  [ -z "$p" ] && p=$(sed -n 's/^redir_port=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
  echo "$p"
}

# 判断 mihomo 配置是否已同步到指定端口（且 tun 开启，未被降级）
is_synced() {
  local PORT="$1"
  [ -f "$CFG" ] || return 1
  [ -n "$PORT" ] || return 1
  grep -q '^[[:space:]]*enhanced-mode:[[:space:]]*fake-ip' "$CFG" || return 1
  grep -q "127\.0\.0\.1:$PORT" "$CFG" || return 1
  # tun.enable 是否为 true（用临时文件避免 process substitution 兼容性问题）
  sed -n '/^tun:/,/^[^ ]/p' "$CFG" > /tmp/.boxfix_tun_check 2>/dev/null
  grep -q '^[[:space:]]*enable:[[:space:]]*true' /tmp/.boxfix_tun_check || return 1
  rm -f /tmp/.boxfix_tun_check
  # cn_ip 国内 IP 直连兜底必须存在（保证本地连接优先直连，不绕代理）
  grep -q 'RULE-SET,cn_ip' "$CFG" || return 1
  # IPv6 是否已开启（顶层 ipv6 与 dns.ipv6 均需为 true）
  sed -n '/^dns:/,/^[^ ]/p' "$CFG" > /tmp/.boxfix_dns_check 2>/dev/null
  grep -q '^[[:space:]]*ipv6:[[:space:]]*true' "$CFG" && grep -q '^[[:space:]]*ipv6:[[:space:]]*true' /tmp/.boxfix_dns_check || return 1
  rm -f /tmp/.boxfix_dns_check
  return 0
}

# 检查配置是否需要写入（避免无谓重启 Box）
needs_sync() {
  local PORT="$1"
  # 快速检查关键项是否已同步；若已同步且无降级标记则无需动作
  if is_synced "$PORT" && [ ! -f "$DEGRADED_FLAG" ]; then
    return 1
  fi
  return 0
}

# 同步 mihomo 配置：fake-ip + DNS 上游指向 AGH 实际端口
sync_mihomo() {
  local PORT="$1"
  [ -f "$CFG" ] || { log "未找到 $CFG，跳过同步"; return 0; }
  [ -n "$PORT" ] || { log "AGH 端口未知，跳过同步"; return 0; }
  mkdir -p "$(dirname "$CFG")"
  [ -f "$CFG.aghbak" ] || cp -f "$CFG" "$CFG.aghbak"
  log "同步 mihomo DNS 上游到 127.0.0.1:$PORT ..."

  # 智能 DNS 模式：fake-ip + 原版 fake-ip-filter（国内域名自动跳过 fake-ip 走 fast path）
  sed -i 's/^\([[:space:]]*enhanced-mode:\).*/\1 fake-ip/' "$CFG"

  # 同步所有 nameserver/nameserver-policy 中指向本地 AGH 的端口
  sed -i "s/^\([[:space:]]*-[[:space:]]*\)127\.0\.0\.1:[0-9]*/\1127.0.0.1:$PORT/" "$CFG"

  # 确保 nameserver 存在
  if ! grep -q '^[[:space:]]*nameserver:' "$CFG"; then
    awk -v port="$PORT" '/^dns:/{print; print "  nameserver:"; print "    - 127.0.0.1:" port; next}1' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  fi

  # 开启 tun
  sed -i '/^tun:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 true/;}' "$CFG"

  # 开启 sniffer
  sed -i '/^sniffer:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 true/;}' "$CFG"

  # 确保 cn_ip 国内 IP 直连兜底存在（若被误删则加回，保证本地连接优先直连不绕代理）
  if ! grep -q 'RULE-SET,cn_ip' "$CFG"; then
    sed -i 's/^\([[:space:]]*-[[:space:]]*\)RULE-SET,cn_domain,国内直连/\1RULE-SET,cn_domain,国内直连\n\1RULE-SET,cn_ip,国内直连/' "$CFG"
    grep -q 'RULE-SET,cn_ip' "$CFG" || sed -i 's/^\([[:space:]]*\)- MATCH,/\1- RULE-SET,cn_ip,国内直连\n\1- MATCH,/' "$CFG"
    log "cn_ip 国内直连兜底已恢复"
  fi

  # 强制开启 IPv6（顶层 + dns 块），解决 IPv6 关闭导致的 Google 等连接失败
  if grep -q '^ipv6:' "$CFG"; then
    sed -i 's/^ipv6:.*/ipv6: true/' "$CFG"
  else
    sed -i '/^mode:/a\ipv6: true' "$CFG"
  fi
  if sed -n '/^dns:/,/^[^ ]/p' "$CFG" | grep -q '^[[:space:]]*ipv6:'; then
    sed -i '/^dns:/,/^[^ ]/s/^\([[:space:]]*ipv6:\).*/\1 true/' "$CFG"
  else
    sed -i '/^dns:/a\  ipv6: true' "$CFG"
  fi

  # 删除 Local_DNS_Forward 代理节点
  awk 'BEGIN{skip=0} /^[[:space:]]*-[[:space:]]*name:[[:space:]]*Local_DNS_Forward/{skip=1;next} skip && /^[[:space:]]*-[[:space:]]*name:/{skip=0} !skip' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

  rm -f "$DEGRADED_FLAG"
  touch "$MARK"
  log "配置同步完成，重启 Box ..."
  $RESTART_CMD
  log "Box 服务已重启"
}

# 降级到直连模式（代理/网络故障时，确保国内网络可用）
degrade_to_direct() {
  log "检测到网络故障，降级到直连模式..."
  [ -f "$CFG" ] || { log "未找到 $CFG，跳过降级"; return 1; }
  cp -f "$CFG" "$CFG.degbak"
  sed -i '/^tun:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 false/;}' "$CFG"
  sed -i 's/^\([[:space:]]*enhanced-mode:\).*/\1 redir-host/' "$CFG"
  touch "$DEGRADED_FLAG"
  $RESTART_CMD
  log "已降级到直连模式"
}

# 重启 AGH 进程
restart_agh() {
  pkill -9 "AdGuardHome"; sleep 1
  export SSL_CERT_DIR="/system/etc/security/cacerts/"
  "$BIN_DIR/AdGuardHome" --no-check-update &
}

# 清理独立模式的劫持规则与守护脚本
cleanup_standalone() {
  pkill -9 "ProxyConfig"; pkill -9 "iptables.sh"
  iptables -w 2 -t nat -F ADGUARD 2>/dev/null; iptables -w 2 -t nat -X ADGUARD 2>/dev/null
  ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
}

# 切换到随机端口独立模式（未检测到 Box）
switch_to_standalone() {
  log "未检测到 Box，切换到独立模式"
  if [ ! -f "$MODE_FILE" ] || [ "$(cat "$MODE_FILE" 2>/dev/null)" != "fixed" ]; then
    echo "random" > "$MODE_FILE"
  fi
  R1=$((30000+RANDOM%35536)); R2=$((30000+RANDOM%35536))
  sed -i "s/^\([[:space:]]*port:\) [0-9]*/\1 $R1/; s/^\([[:space:]]*address:\) 127\.0\.0\.1:[0-9]*/\1 127.0.0.1:$R2/" "$YAML"
  sed -i "s/^redir_port=.*/redir_port=$R1/" "$SCRIPT_DIR/config.prop" || echo "redir_port=$R1" > "$SCRIPT_DIR/config.prop"
  restart_agh
  "$SCRIPT_DIR/iptables.sh" &
  "$SCRIPT_DIR/ProxyConfig.sh" &
  log "随机端口独立模式已生效"
}

current_mode() {
  [ -f "$MODE_FILE" ] && cat "$MODE_FILE" || echo "unknown"
}

# 写模式标记（供 Web 面板/aghproxy 读取）
write_state() {
  echo "box" > "$STATE_DIR/box_mode" 2>/dev/null || true
  [ -f "$DEGRADED_FLAG" ] && echo "degraded" > "$STATE_DIR/degraded" || echo "ok" > "$STATE_DIR/degraded" 2>/dev/null
}

# 启动 aghproxy（VPN 监控）—— 只启动一次
start_aghproxy() {
  if ! pgrep -f "aghproxy watch" >/dev/null 2>&1; then
    "$SCRIPT_DIR/aghproxy" watch >> "$LOG" 2>&1 &
    log "aghproxy 已启动"
  fi
}

# ═══════════════════════════════════════════════
# 主流程
# ═══════════════════════════════════════════════
log "BoxFix v10 启动"

# 确保管理脚本可执行
chmod 755 "$CTL" "$SCRIPT_DIR/aghproxy" "$SCRIPT_DIR/aghbridge" "$SCRIPT_DIR/aghappclean" 2>/dev/null

# 启动 VPN 监控
start_aghproxy

# 启动桥接器（Web 面板控制通道）
"$SCRIPT_DIR/aghbridge" start >> "$LOG" 2>&1

# 等待系统开机完成（关键修复：避免开机早期干扰 Box 启动）
wait_for_boot

# 状态跟踪
degraded=0
last_proxy_ok=1
check_count=0

if box_installed; then
  # 首次同步前先等待 Box 代理可达，避免 Box 未就绪就被重启
  if wait_for_proxy; then
    AGH_PORT=$(get_agh_port)
    log "代理已就绪，检查配置同步状态"
    if needs_sync "$AGH_PORT"; then
      sync_mihomo "$AGH_PORT"
    else
      log "配置已同步，无需重启 Box"
    fi
  fi
fi

while true; do
  MODE=$(current_mode)
  if box_installed; then
    cleanup_standalone
    AGH_PORT=$(get_agh_port)
    write_state

    # 检查代理健康
    if proxy_reachable; then
      if [ -f "$DEGRADED_FLAG" ]; then
        log "代理已恢复，重新同步配置"
        degraded=0
        needs_sync "$AGH_PORT" && sync_mihomo "$AGH_PORT"
      fi
      last_proxy_ok=1
      needs_sync "$AGH_PORT" && sync_mihomo "$AGH_PORT"
    else
      if [ "$last_proxy_ok" -eq 1 ]; then
        log "警告：代理不可达，开始监控"
        last_proxy_ok=0
      fi
      check_count=$((check_count + 1))

      # 连续失败 3 次后降级（避免误判）
      if [ $check_count -ge 3 ] && [ "$degraded" -eq 0 ]; then
        degrade_to_direct
        degraded=1
        check_count=0
        write_state
      fi
    fi
  else
    rm -f "$DEGRADED_FLAG" 2>/dev/null
    echo "standalone" > "$STATE_DIR/box_mode" 2>/dev/null
    [ "$MODE" != "random" ] && switch_to_standalone || {
      pgrep -f "iptables.sh" >/dev/null || "$SCRIPT_DIR/iptables.sh" &
      pgrep -f "ProxyConfig.sh" >/dev/null || "$SCRIPT_DIR/ProxyConfig.sh" &
    }
  fi
  sleep 30
done

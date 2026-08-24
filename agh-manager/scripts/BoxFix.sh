#!/system/bin/sh
# ============================================================
# BoxFix v11 自适应协调器 + 故障自动降级
#
# 相比 v10 的改进：
#   1. 【修复断网问题】移除 wait_for_proxy，启动后立即同步，
#      避免开机时因等待代理导致长时间无网络
#   2. 【修复断连问题】fallback_to_standalone 替代 degrade_to_direct，
#      Box 断连时启用 iptables 53 劫持到 AGH，保障国内网络可用
#   3. 主循环不再无条件清理 iptables 规则，避免规则窗口期
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
  sed -n '/^tun:/,/^[^ ]/p' "$CFG" > /tmp/.boxfix_tun_check 2>/dev/null
  grep -q '^[[:space:]]*enable:[[:space:]]*true' /tmp/.boxfix_tun_check || return 1
  rm -f /tmp/.boxfix_tun_check
  grep -q 'RULE-SET,cn_ip' "$CFG" || return 1
  sed -n '/^dns:/,/^[^ ]/p' "$CFG" > /tmp/.boxfix_dns_check 2>/dev/null
  grep -q '^[[:space:]]*ipv6:[[:space:]]*true' "$CFG" && grep -q '^[[:space:]]*ipv6:[[:space:]]*true' /tmp/.boxfix_dns_check || return 1
  rm -f /tmp/.boxfix_dns_check
  return 0
}

# 检查配置是否需要写入（避免无谓重启 Box）
needs_sync() {
  local PORT="$1"
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

  sed -i 's/^\([[:space:]]*enhanced-mode:\).*/\1 fake-ip/' "$CFG"
  sed -i "s/^\([[:space:]]*-[[:space:]]*\)127\.0\.0\.1:[0-9]*/\1127.0.0.1:$PORT/" "$CFG"

  if ! grep -q '^[[:space:]]*nameserver:' "$CFG"; then
    awk -v port="$PORT" '/^dns:/{print; print "  nameserver:"; print "    - 127.0.0.1:" port; next}1' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  fi

  sed -i '/^tun:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 true/;}' "$CFG"
  sed -i '/^sniffer:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 true/;}' "$CFG"

  if ! grep -q 'RULE-SET,cn_ip' "$CFG"; then
    sed -i 's/^\([[:space:]]*-[[:space:]]*\)RULE-SET,cn_domain,国内直连/\1RULE-SET,cn_domain,国内直连\n\1RULE-SET,cn_ip,国内直连/' "$CFG"
    grep -q 'RULE-SET,cn_ip' "$CFG" || sed -i 's/^\([[:space:]]*\)- MATCH,/\1- RULE-SET,cn_ip,国内直连\n\1- MATCH,/' "$CFG"
    log "cn_ip 国内直连兜底已恢复"
  fi

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

  awk 'BEGIN{skip=0} /^[[:space:]]*-[[:space:]]*name:[[:space:]]*Local_DNS_Forward/{skip=1;next} skip && /^[[:space:]]*-[[:space:]]*name:/{skip=0} !skip' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

  rm -f "$DEGRADED_FLAG"
  touch "$MARK"
  log "配置同步完成，重启 Box ..."
  $RESTART_CMD
  log "Box 服务已重启"
}

# 降级到独立模式（代理不可用时，用 AGH 直连 DNS 保障国内网络）
fallback_to_standalone() {
  local PORT="$1"
  log "代理不可达，切换到独立模式，DNS 由 AGH 直连 ..."
  [ -z "$PORT" ] && { log "AGH 端口未知，无法切换"; return 1; }

  iptables -w 2 -t nat -N ADGUARD 2>/dev/null
  iptables -w 2 -t nat -I OUTPUT -j ADGUARD 2>/dev/null
  iptables -w 2 -t nat -F ADGUARD
  iptables -w 2 -t nat -A ADGUARD -p udp --dport 53 -j REDIRECT --to-ports "$PORT"
  iptables -w 2 -t nat -A ADGUARD -p tcp --dport 53 -j REDIRECT --to-ports "$PORT"
  ip6tables -w 2 -A OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -w 2 -A OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null

  touch "$DEGRADED_FLAG"
  log "已切换到独立模式 (AGH 端口 $PORT)，国内网络应可用"
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
log "BoxFix v11 启动"

# 确保管理脚本可执行
chmod 755 "$CTL" "$SCRIPT_DIR/aghproxy" "$SCRIPT_DIR/aghbridge" "$SCRIPT_DIR/aghappclean" 2>/dev/null

# 启动 VPN 监控
start_aghproxy

# 启动桥接器（Web 面板控制通道）
"$SCRIPT_DIR/aghbridge" start >> "$LOG" 2>&1

# 等待系统开机完成（避免开机早期干扰 Box 启动）
wait_for_boot

# 状态跟踪
degraded=0
last_proxy_ok=1
check_count=0

# 初始同步：不等待代理，立即同步配置
if box_installed; then
  AGH_PORT=$(get_agh_port)
  log "检查初始配置同步状态"
  if needs_sync "$AGH_PORT"; then
    sync_mihomo "$AGH_PORT"
  else
    log "配置已同步"
  fi
fi

# 主循环
while true; do
  MODE=$(current_mode)
  if box_installed; then
    AGH_PORT=$(get_agh_port)
    write_state

    if proxy_reachable; then
      if [ -f "$DEGRADED_FLAG" ]; then
        log "代理已恢复，清理独立模式，切回 Box 模式"
        cleanup_standalone
        degraded=0
      fi
      last_proxy_ok=1
      needs_sync "$AGH_PORT" && sync_mihomo "$AGH_PORT"
    else
      if [ "$last_proxy_ok" -eq 1 ]; then
        log "警告：代理不可达，开始监控"
        last_proxy_ok=0
        check_count=0
      fi
      check_count=$((check_count + 1))

      if [ $check_count -ge 3 ] && [ "$degraded" -eq 0 ]; then
        fallback_to_standalone "$AGH_PORT"
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
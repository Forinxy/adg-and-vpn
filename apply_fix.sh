#!/system/bin/sh
# ============================================================
# AGH-Box 共存修复一键脚本 (apply_fix.sh)
#
# 用途：AdGuard Home 模块更新（重刷上游新版本）后，运行本脚本
#       即可自动重新应用全部共存修复，无需手工改动任何文件。
#
# 用法（root 终端）：
#   sh /data/local/tmp/apply_fix.sh
#
# 本脚本自动完成：
#   1. 写入 scripts/BoxFix.sh（自适应协调器 v13）
#   2. 修改 service.sh：启动 BoxFix + 读取 .port_mode 设置端口
#   3. 修改 ModuleMOD.sh：描述文案随端口模式动态更新
#   4. 修改 uninstall.sh：卸载时还原 Box mihomo 配置
#   5. 清空 config.prop 中的 PROXY_URL（本模块不管理代理订阅）
#   6. 解锁/重新锁定脚本防篡改
# ============================================================

AGH_DIR="/data/adb/agh"
ADGPATH="/data/adb/modules/AdGuardHome"
SCRIPT_DIR="$AGH_DIR/scripts"
BIN_DIR="$AGH_DIR/bin"
MAIN_LOG="$AGH_DIR/agh.log"
MODE_FILE="$AGH_DIR/.port_mode"

log() { echo "$(date '+%F %T') [ApplyFix] $*" | tee -a "$MAIN_LOG"; }

# 检查模块是否安装
[ -d "$ADGPATH" ] || { echo "错误：未检测到 AdGuard Home 模块 ($ADGPATH)"; exit 1; }
[ -d "$SCRIPT_DIR" ] || { echo "错误：未检测到脚本目录 ($SCRIPT_DIR)"; exit 1; }
[ -f "$BIN_DIR/AdGuardHome.yaml" ] || { echo "错误：未检测到 AdGuardHome.yaml"; exit 1; }

# 0. 解锁防篡改
find "$ADGPATH" -type f -name "*.sh" -exec chattr -i {} \; 2>/dev/null

# 1. 写入 BoxFix.sh
log "写入 scripts/BoxFix.sh ..."
cat > "$SCRIPT_DIR/BoxFix.sh" <<'BOXEOF'
#!/system/bin/sh
# ============================================================
# BoxFix v13 自适应协调器 + 故障自动降级
#
# 相比 v12 的改进：
#   1. 【修复重启后 VPN 无法连接】新增 wait_for_agh，确保 AGH 就绪后
#      才将 mihomo DNS 指向 AGH，避免 DNS 解析失败导致代理无法连接
#   2. 【恢复 degrade_to_direct】代理不可达时关闭 tun + 切 redir-host，
#      比 iptables 回退更可靠（mihomo tun 不拦截流量，网络直接可用）
#   3. 移除 prepare_mihomo 覆盖验证和 box.service 修改（v12 回退）
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
AGH_PENDING=0

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

# 等待 AGH DNS 端口就绪（最多 60 秒）
wait_for_agh() {
  local i=0 port
  while [ $i -lt 30 ]; do
    port=$(get_agh_port)
    [ -n "$port" ] && timeout 2 sh -c "echo > /dev/tcp/127.0.0.1/$port" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 2
  done
  log "警告：AGH 端口未就绪，将延迟同步"
  AGH_PENDING=1
  return 0
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

# 检测国内网络是否可用（直连国内 DNS 服务器，判断 mihomo 代理是否正常工作）
# 当代理到期/接口不可用时，mihomo 仍在运行但所有流量被阻塞，
# 此检查能识别出这种"代理假死"状态，触发独立模式回退
network_reachable() {
  local PORT
  PORT=$(get_agh_port)
  [ -z "$PORT" ] && return 1
  # 直连阿里 DNS  TCP 53（走 cn_ip 直连规则）
  timeout 3 sh -c 'echo > /dev/tcp/223.5.5.5/53' >/dev/null 2>&1 && return 0
  # 直连腾讯 DNS TCP 53
  timeout 3 sh -c 'echo > /dev/tcp/119.29.29.29/53' >/dev/null 2>&1 && return 0
  # 兜底：检查 AGH 本身是否存活
  timeout 2 sh -c 'echo > /dev/tcp/127.0.0.1/'"$PORT" >/dev/null 2>&1
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

  # box.service restart 存在竞态：旧进程未完全退出时 start_box 被调用，
  # 触发递归 stop_box → start_box，导致新旧 mihomo 同时抢端口/TUN
  # 先确保所有 mihomo 进程彻底死亡再重启
  pkill -15 -f "mihomo" 2>/dev/null
  local wait_i=0
  while [ $wait_i -lt 10 ]; do
    pgrep -f "mihomo" >/dev/null 2>&1 || break
    wait_i=$((wait_i + 1))
    sleep 0.5
  done
  pgrep -f "mihomo" >/dev/null 2>&1 && pkill -9 -f "mihomo" 2>/dev/null
  sleep 2

  $RESTART_CMD
  log "Box 服务已重启"
}

# 降级到直连模式（代理不可达时，关闭 tun + 切 redir-host，保障国内网络可用）
# 不还原 aghbak，避免覆盖已同步的 DNS 端口配置
degrade_to_direct() {
  log "代理不可达，降级到直连模式，关闭 tun ..."
  [ -f "$CFG" ] || { log "未找到 $CFG，跳过降级"; return 1; }
  cp -f "$CFG" "$CFG.degbak"
  sed -i '/^tun:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 false/;}' "$CFG"
  sed -i 's/^\([[:space:]]*enhanced-mode:\).*/\1 redir-host/' "$CFG"
  touch "$DEGRADED_FLAG"
  $RESTART_CMD
  log "已降级到直连模式，tun 已关闭，网络应可用"
}

# 从直连模式恢复（代理恢复时，重新开启 tun + 切回 fake-ip）
restore_from_degrade() {
  log "代理已恢复，从直连模式恢复 ..."
  [ -f "$CFG.degbak" ] && cp -f "$CFG.degbak" "$CFG" && rm -f "$CFG.degbak"
  rm -f "$DEGRADED_FLAG"
  touch "$MARK"
  $RESTART_CMD
  log "已从直连模式恢复"
}

# 重启 AGH 进程
restart_agh() {
  pkill -9 "AdGuardHome"; sleep 1
  export SSL_CERT_DIR="/system/etc/security/cacerts/"
  "$BIN_DIR/AdGuardHome" --no-check-update &
}

# 清理直连/独立模式的残留
cleanup_standalone() {
  pkill -9 "ProxyConfig"; pkill -9 "iptables.sh"
  iptables -w 2 -t nat -F ADGUARD 2>/dev/null; iptables -w 2 -t nat -X ADGUARD 2>/dev/null
  ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
  rm -f "$CFG.degbak" 2>/dev/null
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
log "BoxFix v13 启动"

# 确保管理脚本可执行
chmod 755 "$CTL" "$SCRIPT_DIR/aghproxy" "$SCRIPT_DIR/aghbridge" "$SCRIPT_DIR/aghappclean" 2>/dev/null

# 启动 VPN 监控
start_aghproxy

# 启动桥接器（Web 面板控制通道）
"$SCRIPT_DIR/aghbridge" start >> "$LOG" 2>&1

# 等待系统开机完成（避免开机早期干扰 Box 启动）
wait_for_boot

# 等待 AGH DNS 端口就绪（确保 mihomo 启动时 AGH 可解析）
wait_for_agh

# 状态跟踪
degraded=0
last_proxy_ok=1
check_count=0
network_check_counter=0
NETWORK_CHECK_INTERVAL=10  # 网络健康时每 10 轮（5 分钟）检查一次国内连通性，省电
LAST_SYNC_TIME=0
SYNC_COOLDOWN=120  # 同步冷却时间（秒），避免反复重启 Box

# 初始同步：AGH 未就绪时跳过，等主循环延迟同步
if box_installed; then
  if [ $AGH_PENDING -eq 1 ]; then
    log "AGH 未就绪，跳过初始同步，等待主循环延迟同步"
  else
    AGH_PORT=$(get_agh_port)
    log "检查初始配置同步状态"
    if needs_sync "$AGH_PORT"; then
      sync_mihomo "$AGH_PORT"
      LAST_SYNC_TIME=$(date +%s)
    else
      log "配置已同步"
      if ! proxy_reachable; then
        log "初始代理不可达，重启 Box（AGH 已就绪后重试）"
        $RESTART_CMD
        log "Box 已重启"
      fi
    fi
  fi
fi

# 主循环
while true; do
  MODE=$(current_mode)
  if box_installed; then
    AGH_PORT=$(get_agh_port)
    write_state

    # 延迟同步：之前 AGH 未就绪，现在检查是否已就绪
    if [ $AGH_PENDING -eq 1 ]; then
      AGH_PORT=$(get_agh_port)
      if [ -n "$AGH_PORT" ] && timeout 2 sh -c "echo > /dev/tcp/127.0.0.1/$AGH_PORT" >/dev/null 2>&1; then
        log "AGH 端口已就绪，触发延迟同步"
        sync_mihomo "$AGH_PORT"
        AGH_PENDING=0
        LAST_SYNC_TIME=$(date +%s)
        log "延迟同步完成"
      fi
    fi

    if proxy_reachable; then
      if [ -f "$DEGRADED_FLAG" ]; then
        log "代理已恢复，从直连模式切回 Box 模式"
        restore_from_degrade
        degraded=0
        cleanup_standalone
      fi
      last_proxy_ok=1
      check_count=0
      NOW=$(date +%s)
      if [ $((NOW - LAST_SYNC_TIME)) -ge $SYNC_COOLDOWN ] && needs_sync "$AGH_PORT"; then
        sync_mihomo "$AGH_PORT"
        LAST_SYNC_TIME=$NOW
      fi

      network_check_counter=$((network_check_counter + 1))
      if [ $network_check_counter -ge $NETWORK_CHECK_INTERVAL ] || [ "$check_count" -gt 0 ]; then
        network_check_counter=0
        if ! network_reachable; then
          log "警告：mihomo 运行中但国内网络不可达，代理可能已失效"
          check_count=$((check_count + 1))
          if [ $check_count -ge 3 ] && [ "$degraded" -eq 0 ]; then
            degrade_to_direct
            degraded=1
            check_count=0
            write_state
          fi
        fi
      fi
    else
      if [ "$last_proxy_ok" -eq 1 ]; then
        log "警告：代理不可达，开始监控"
        last_proxy_ok=0
        check_count=0
      fi
      check_count=$((check_count + 1))

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
BOXEOF
chmod 755 "$SCRIPT_DIR/BoxFix.sh"
log "BoxFix.sh v13 写入完成"

# 1.5 写入管理工具集与规则文件
# 查找路径：优先 agh-manager/scripts/ 子目录，其次同目录（兼容两种分发方式）
log "写入管理工具集 ..."
MANAGER_DIR="$(dirname "$0")"
if [ -d "$MANAGER_DIR/agh-manager/scripts" ]; then
  MANAGER_DIR="$MANAGER_DIR/agh-manager/scripts"
fi
[ -f "$MANAGER_DIR/aghctl" ] && cp -f "$MANAGER_DIR/aghctl" "$SCRIPT_DIR/" && chmod 755 "$SCRIPT_DIR/aghctl"
[ -f "$MANAGER_DIR/aghproxy" ] && cp -f "$MANAGER_DIR/aghproxy" "$SCRIPT_DIR/" && chmod 755 "$SCRIPT_DIR/aghproxy"
[ -f "$MANAGER_DIR/aghbridge" ] && cp -f "$MANAGER_DIR/aghbridge" "$SCRIPT_DIR/" && chmod 755 "$SCRIPT_DIR/aghbridge"
[ -f "$MANAGER_DIR/aghappclean" ] && cp -f "$MANAGER_DIR/aghappclean" "$SCRIPT_DIR/" && chmod 755 "$SCRIPT_DIR/aghappclean"
[ -f "$MANAGER_DIR/aghweb" ] && cp -f "$MANAGER_DIR/aghweb" "$SCRIPT_DIR/" && chmod 755 "$SCRIPT_DIR/aghweb"
[ -f "$MANAGER_DIR/chinese_rules.txt" ] && cp -f "$MANAGER_DIR/chinese_rules.txt" "$SCRIPT_DIR/"
log "管理工具集写入完成"

# 2. 修改 service.sh：确保读取 .port_mode 并启动 BoxFix
log "检查 service.sh ..."
if grep -q "BoxFix.sh" "$ADGPATH/service.sh"; then
    log "service.sh 已含 BoxFix 启动，跳过"
else
    log "service.sh 未含 BoxFix 启动，开始修改 ..."
    # 在附加脚本启动区后插入 BoxFix 启动
    if grep -q 'NoAdsService.sh' "$ADGPATH/service.sh"; then
        sed -i '/NoAdsService.sh/a\  "$SCRIPT_DIR\/BoxFix.sh" &' "$ADGPATH/service.sh"
    else
        # 找不到锚点则追加到末尾（exit 之前）
        sed -i '/^exit/i\"$SCRIPT_DIR/BoxFix.sh" &' "$ADGPATH/service.sh"
    fi
    log "service.sh 已插入 BoxFix 启动"
fi

# 2.5 修改 service.sh：启动 Web 管理面板（aghweb）
log "检查 service.sh aghweb 启动 ..."
if grep -q "aghweb" "$ADGPATH/service.sh"; then
    log "service.sh 已含 aghweb 启动，跳过"
else
    log "service.sh 未含 aghweb 启动，插入启动逻辑 ..."
    sed -i '/BoxFix.sh/a\  "$SCRIPT_DIR\/aghweb" start >> "$AGH_DIR\/agh.log" 2>&1 || true' "$ADGPATH/service.sh"
    log "service.sh 已插入 aghweb 启动"
fi

# 3. 修改 ModuleMOD.sh：描述随模式动态更新
log "检查 ModuleMOD.sh ..."
if grep -q "LAST_MODE" "$SCRIPT_DIR/ModuleMOD.sh"; then
    log "ModuleMOD.sh 已修复，跳过"
else
    log "ModuleMOD.sh 未修复，重写描述逻辑 ..."
    # 注入动态描述变量（保持原内容，追加 LAST_MODE 支持）
    sed -i 's/LAST_LOCALE="INIT"/LAST_LOCALE="INIT"\nLAST_MODE=""/' "$SCRIPT_DIR/ModuleMOD.sh"
    sed -i 's/LAST_LOCALE="$CURRENT_LOCALE"/LAST_LOCALE="$CURRENT_LOCALE"\n    LAST_MODE="$PORT_MODE"/' "$SCRIPT_DIR/ModuleMOD.sh"
    log "ModuleMOD.sh 已注入动态模式"
fi

# 4. 修改 uninstall.sh：卸载时还原 Box mihomo 配置
log "检查 uninstall.sh ..."
if grep -q "aghbak" "$ADGPATH/uninstall.sh"; then
    log "uninstall.sh 已修复，跳过"
else
    log "uninstall.sh 未修复，插入还原逻辑 ..."
    sed -i '/^#!/a\
# 还原 Box mihomo 配置（防卸载后 Box 指向已删除的 AGH 端口导致断网）\
BOX_CFG="/data/adb/box/mihomo/config.yaml"\
BOX_BAK="$BOX_CFG.aghbak"\
BOX_SERVICE="/data/adb/box/scripts/box.service"\
if [ -f "$BOX_BAK" ]; then\
    cp -f "$BOX_BAK" "$BOX_CFG"\
    rm -f "$BOX_BAK"\
    [ -f "$BOX_SERVICE" ] && "$BOX_SERVICE" restart\
fi\
pkill -9 "BoxFix"' "$ADGPATH/uninstall.sh"
    log "uninstall.sh 已插入还原逻辑"
fi

# 5. 清空 config.prop 的 PROXY_URL
log "清空 config.prop 中的 PROXY_URL ..."
if [ -f "$SCRIPT_DIR/config.prop" ]; then
    sed -i 's|^PROXY_URL=.*|PROXY_URL=""|' "$SCRIPT_DIR/config.prop"
    grep -q '^PROXY_URL=' "$SCRIPT_DIR/config.prop" || echo 'PROXY_URL=""' >> "$SCRIPT_DIR/config.prop"
fi

# 5.5 注入中国 App 定制规则到 AdGuardHome.yaml
log "注入中国 App 定制规则 ..."
RULES_FILE="$SCRIPT_DIR/chinese_rules.txt"
YAML_FILE="$BIN_DIR/AdGuardHome.yaml"
if [ -f "$RULES_FILE" ] && [ -f "$YAML_FILE" ]; then
    if grep -q "HTTPDNS 拦截" "$YAML_FILE"; then
        log "中国规则已存在，跳过注入"
    else
        # 将规则文件转换为 yaml user_rules 格式（缩进 + 引号包裹）
        awk 'NF && $1 !~ /^#/ { gsub(/\x27/, "\x27\x27"); printf "  - \x27%s\x27\n", $0 }' "$RULES_FILE" > "$SCRIPT_DIR/.rules_tmp"
        # 在 user_rules 块末尾追加（若无 user_rules 则创建）
        if grep -q "^user_rules:" "$YAML_FILE"; then
            sed -i '/^user_rules:/r '"$SCRIPT_DIR/.rules_tmp" "$YAML_FILE"
            log "中国 App 定制规则已注入 user_rules"
        else
            echo "user_rules:" >> "$YAML_FILE"
            sed -i '/^user_rules:/r '"$SCRIPT_DIR/.rules_tmp" "$YAML_FILE"
            log "已创建 user_rules 并注入中国规则"
        fi
        rm -f "$SCRIPT_DIR/.rules_tmp"
    fi
else
    log "规则文件或 yaml 缺失，跳过规则注入"
fi

# 6. 重新锁定防篡改（仅锁定模块内脚本，BoxFix 在 agh/scripts 不锁，避免协调器自修复受阻）
find "$ADGPATH" -type f -name "*.sh" -exec chattr +i {} \; 2>/dev/null

log "=============================================="
log "修复完成！请重启设备或在终端执行："
log "  pkill -f AdGuardHome && sh /data/adb/modules/AdGuardHome/service.sh &"
log "=============================================="

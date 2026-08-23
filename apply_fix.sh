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
#   1. 写入 scripts/BoxFix.sh（自适应协调器 v3）
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
# BoxFix v9 自适应协调器 + 故障自动降级
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

# 防止重复启动
[ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

log() { echo "$(date '+%F %T') [BoxFix] $*" >> "$LOG"; }

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

# 同步 mihomo 配置：fake-ip + DNS 上游指向 AGH 实际端口
# fake-ip-filter 保留原版 rule-set:Fake-IP-Filter（含全部国内 CDN 域名，每日自动更新）
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
# 基于当前已同步配置做最小改动：关 tun + 改 redir-host，不还原 aghbak，
# 避免覆盖已同步的 DNS 端口配置，也避免恢复时反复横跳
degrade_to_direct() {
  log "检测到网络故障，降级到直连模式..."
  [ -f "$CFG" ] || { log "未找到 $CFG，跳过降级"; return 1; }
  # 备份当前配置为降级前快照（供恢复）
  cp -f "$CFG" "$CFG.degbak"
  # 关闭 tun
  sed -i '/^tun:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 false/;}' "$CFG"
  # 切回 redir-host，DNS 直连可用
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
# 注意：不覆盖用户安装时选择的 .port_mode 端口模式
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

# 状态跟踪
degraded=0
last_proxy_ok=1
check_count=0

while true; do
  MODE=$(current_mode)
  if box_installed; then
    cleanup_standalone
    AGH_PORT=$(get_agh_port)

    # 检查代理健康
    if proxy_reachable; then
      if [ -f "$DEGRADED_FLAG" ]; then
        log "代理已恢复，重新同步配置"
        degraded=0
        is_synced "$AGH_PORT" && sync_mihomo "$AGH_PORT"
      fi
      last_proxy_ok=1
      is_synced "$AGH_PORT" || sync_mihomo "$AGH_PORT"
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
      fi
    fi
  else
    rm -f "$DEGRADED_FLAG" 2>/dev/null
    [ "$MODE" != "random" ] && switch_to_standalone || {
      pgrep -f "iptables.sh" >/dev/null || "$SCRIPT_DIR/iptables.sh" &
      pgrep -f "ProxyConfig.sh" >/dev/null || "$SCRIPT_DIR/ProxyConfig.sh" &
    }
  fi
  sleep 30
done &

BOXEOF
chmod 755 "$SCRIPT_DIR/BoxFix.sh"
log "BoxFix.sh 写入完成"

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

# 6. 重新锁定防篡改（仅锁定模块内脚本，BoxFix 在 agh/scripts 不锁，避免协调器自修复受阻）
find "$ADGPATH" -type f -name "*.sh" -exec chattr +i {} \; 2>/dev/null

log "=============================================="
log "修复完成！请重启设备或在终端执行："
log "  pkill -f AdGuardHome && sh /data/adb/modules/AdGuardHome/service.sh &"
log "=============================================="

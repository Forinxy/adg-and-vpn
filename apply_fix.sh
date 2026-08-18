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
# BoxFix v3 自适应协调器 + 端口自动同步
CFG="/data/adb/box/mihomo/config.yaml"
BOX_DIR="/data/adb/box"
RESTART_CMD="/data/adb/box/scripts/box.service restart"
LOG="/data/adb/agh/agh.log"
MODE_FILE="/data/adb/agh/.port_mode"
SCRIPT_DIR="/data/adb/agh/scripts"
BIN_DIR="/data/adb/agh/bin"
MARK="/data/adb/box/mihomo/.agh_fixed_v1"
YAML="$BIN_DIR/AdGuardHome.yaml"

[ "$(pgrep -f "$0" | wc -l)" -gt 1 ] && exit

log() { echo "$(date '+%F %T') [BoxFix] $*" >> "$LOG"; }

box_installed() {
  [ -d "$BOX_DIR" ] && [ -f "$CFG" ]
}

get_agh_port() {
  local p
  p=$(awk '/^[[:space:]]*dns:/{f=1;next} f&&/^[[:space:]]*port:/{gsub(/[^0-9]/,"",$NF);print $NF;exit}' "$YAML" 2>/dev/null)
  [ -z "$p" ] && p=$(sed -n 's/^redir_port=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
  echo "$p"
}

is_synced() {
  local PORT="$1"
  [ -f "$CFG" ] || return 1
  [ -n "$PORT" ] || return 1
  grep -q '^[[:space:]]*enhanced-mode:[[:space:]]*fake-ip' "$CFG" || return 1
  grep -q "127\.0\.0\.1:$PORT" "$CFG" || return 1
  return 0
}

sync_mihomo() {
  local PORT="$1"
  [ -f "$CFG" ] || { log "未找到 $CFG，跳过同步"; return 0; }
  [ -n "$PORT" ] || { log "AGH 端口未知，跳过同步"; return 0; }
  mkdir -p "$(dirname "$CFG")"
  [ -f "$CFG.aghbak" ] || cp -f "$CFG" "$CFG.aghbak"
  log "同步 mihomo DNS 上游到 127.0.0.1:$PORT ..."

  sed -i 's/^\([[:space:]]*enhanced-mode:\).*/\1 fake-ip/' "$CFG"

  sed -i "s/^\([[:space:]]*-[[:space:]]*\)127\.0\.0\.1:[0-9]*/\1127.0.0.1:$PORT/" "$CFG"

  grep -q '^[[:space:]]*nameserver:' "$CFG" || \
    awk -v port="$PORT" '/^dns:/{print; print "  nameserver:"; print "    - 127.0.0.1:" port; next}1' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

  sed -i '/^tun:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 true/;}' "$CFG"

  sed -i '/^sniffer:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 true/;}' "$CFG"

  awk 'BEGIN{skip=0} /^[[:space:]]*-[[:space:]]*name:[[:space:]]*Local_DNS_Forward/{skip=1;next} skip && /^[[:space:]]*-[[:space:]]*name:/{skip=0} !skip' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

  touch "$MARK"
  log "配置同步完成，重启 Box 服务..."
  $RESTART_CMD
  log "Box 服务已重启"
}

restart_agh() {
  pkill -9 "AdGuardHome"
  sleep 1
  export SSL_CERT_DIR="/system/etc/security/cacerts/"
  "$BIN_DIR/AdGuardHome" --no-check-update &
}

cleanup_standalone() {
  pkill -9 "ProxyConfig"
  pkill -9 "iptables.sh"
  iptables -w 2 -t nat -F ADGUARD 2>/dev/null
  iptables -w 2 -t nat -X ADGUARD 2>/dev/null
  ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
  ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
}

switch_to_standalone() {
  log "未检测到 Box 模块，切换到随机端口独立模式"
  echo "random" > "$MODE_FILE"
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

while true; do
  MODE=$(current_mode)
  if box_installed; then
    cleanup_standalone
    AGH_PORT=$(get_agh_port)
    is_synced "$AGH_PORT" || sync_mihomo "$AGH_PORT"
  else
    if [ "$MODE" != "random" ]; then
      switch_to_standalone
    else
      pgrep -f "iptables.sh" >/dev/null || "$SCRIPT_DIR/iptables.sh" &
      pgrep -f "ProxyConfig.sh" >/dev/null || "$SCRIPT_DIR/ProxyConfig.sh" &
    fi
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

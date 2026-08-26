#!/system/bin/sh
# ============================================================
# BoxFix v13.1 稳定版 - 保留保底机制，消除误触发重启
#
# 相比 v13 的改进：
#   1. 降级与恢复增加 5 分钟冷却时间，防止反复横跳
#   2. proxy_reachable 改用 DNS 解析验证，而非仅检查端口
#   3. network_reachable 改用 HTTP 检测，减少 DNS 干扰误判
#   4. needs_sync 增加降级标记残留清理，避免无谓同步
#   5. sync_mihomo 内增加 60 秒防抖锁
#   6. 停止 mihomo 改用 SIGTERM 优先，减少端口冲突
#   7. 主循环内增加状态变化日志，便于排查
#
#  - Box 存在   -> AGH 作为广告过滤上游，mihomo nameserver 自动同步
#  - Box 不存在 -> AGH 随机端口独立模式，iptables 劫持 53
#  - 分流原则   -> 域名规则走策略，cn_ip/private_ip 直连，MATCH 代理
#  - 保底机制   -> 30 秒循环检测，代理假死自动降级直连，恢复后自动切回
# ============================================================

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

# 将 Box 自带工具目录加入 PATH（AGH 模块环境默认不含，curl 等不可用）
PATH="$BOX_DIR/bin:$BOX_DIR/scripts:$PATH"
export PATH

mkdir -p "$STATE_DIR"

# ========== curl 探测（AGH 环境无 PATH curl 时回退到 box 自带） ==========
CURL_BIN=""
have_curl() {
    [ -n "$CURL_BIN" ] && return 0
    if command -v curl >/dev/null 2>&1; then
        CURL_BIN="curl"
    elif [ -x "$BOX_DIR/bin/curl" ]; then
        CURL_BIN="$BOX_DIR/bin/curl"
    else
        return 1
    fi
    return 0
}

# 防止重复启动（基于进程名匹配）
[ "$(pgrep -f "scripts/BoxFix.sh" | wc -l)" -gt 2 ] && exit

log() { echo "$(date '+%F %T') [BoxFix] $*" >> "$LOG"; }

# ========== 冷却时间管理 ==========
check_cooldown() {
    local COOLDOWN_FILE="$1"
    local COOLDOWN_SECONDS="${2:-300}"
    if [ -f "$COOLDOWN_FILE" ]; then
        LAST=$(cat "$COOLDOWN_FILE" 2>/dev/null)
        NOW=$(date +%s)
        [ -n "$LAST" ] && [ $((NOW - LAST)) -lt "$COOLDOWN_SECONDS" ] && return 1
    fi
    echo "$(date +%s)" > "$COOLDOWN_FILE"
    return 0
}

# ========== 等待系统开机 ==========
wait_for_boot() {
    local i=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        i=$((i + 1))
        [ $i -ge 150 ] && { log "警告：5 分钟未等到开机完成，继续执行"; return; }
        sleep 2
    done
    log "系统开机完成"
}

# ========== 等待 AGH DNS 端口就绪 ==========
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

# ========== Box 是否已安装 ==========
box_installed() {
    [ -d "$BOX_DIR" ] && [ -f "$CFG" ]
}

# ========== 代理是否真正可达（DNS 解析验证） ==========
proxy_reachable() {
    pgrep -f "mihomo" >/dev/null 2>&1 || return 1
    # 用 mihomo 的 DNS 解析国内域名，能通才认为真正可达
    if command -v dig >/dev/null 2>&1; then
        timeout 3 dig @127.0.0.1 -p 1053 www.qq.com +short >/dev/null 2>&1 && return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        timeout 3 nslookup www.qq.com 127.0.0.1:1053 >/dev/null 2>&1 && return 0
    fi
    # 兜底：检查端口是否监听
    timeout 2 sh -c 'echo > /dev/tcp/127.0.0.1/1053' >/dev/null 2>&1
}

# ========== 国内网络是否可达（HTTP 检测） ==========
network_reachable() {
    # 用 HTTP 访问国内网站，避免 DNS 干扰
    if have_curl; then
        timeout 3 "$CURL_BIN" -s -m 3 http://www.qq.com >/dev/null 2>&1 && return 0
        timeout 3 "$CURL_BIN" -s -m 3 http://www.baidu.com >/dev/null 2>&1 && return 0
    fi
    # 兜底：检查 AGH 本身是否存活
    local PORT
    PORT=$(get_agh_port)
    [ -z "$PORT" ] && return 1
    timeout 2 sh -c 'echo > /dev/tcp/127.0.0.1/'"$PORT" >/dev/null 2>&1
}

# ========== 国外站点是否可达（验证自动选择组是否有有效节点） ==========
# url-test 组 "自动选择" 用 https://cp.cloudflare.com/generate_204 测速，
# 若开机时 mihomo 早于 AGH/网络就绪，测速全失败，节点标记无效后不重试。
# 该检查通过代理访问国外站点，能通说明自动选择组已有可用节点。
proxy_healthy() {
    if have_curl; then
        timeout 6 "$CURL_BIN" -s -m 6 -o /dev/null https://cp.cloudflare.com/generate_204 2>/dev/null && return 0
        timeout 6 "$CURL_BIN" -s -m 6 -o /dev/null https://www.google.com/generate_204 2>/dev/null && return 0
    fi
    return 1
}

# ========== 读取 AGH 实际 DNS 端口 ==========
get_agh_port() {
    local p
    p=$(awk '/^[[:space:]]*dns:/{f=1;next} f&&/^[[:space:]]*port:/{gsub(/[^0-9]/,"",$NF);print $NF;exit}' "$YAML" 2>/dev/null)
    [ -z "$p" ] && p=$(sed -n 's/^redir_port=//p' "$SCRIPT_DIR/config.prop" 2>/dev/null)
    echo "$p"
}

# ========== 判断配置是否已同步 ==========
is_synced() {
    local PORT="$1"
    [ -f "$CFG" ] || return 1
    [ -n "$PORT" ] || return 1
    grep -q '^[[:space:]]*enhanced-mode:[[:space:]]*fake-ip' "$CFG" || return 1
    grep -q "127\.0\.0\.1:$PORT" "$CFG" || return 1
    sed -n '/^tun:/,/^[^ ]/p' "$CFG" > /tmp/.boxfix_tun_check 2>/dev/null
    grep -q '^[[:space:]]*enable:[[:space:]]*true' /tmp/.boxfix_tun_check || { rm -f /tmp/.boxfix_tun_check; return 1; }
    rm -f /tmp/.boxfix_tun_check
    grep -q 'RULE-SET,cn_ip' "$CFG" || return 1
    sed -n '/^dns:/,/^[^ ]/p' "$CFG" > /tmp/.boxfix_dns_check 2>/dev/null
    grep -q '^[[:space:]]*ipv6:[[:space:]]*true' "$CFG" && grep -q '^[[:space:]]*ipv6:[[:space:]]*true' /tmp/.boxfix_dns_check || { rm -f /tmp/.boxfix_dns_check; return 1; }
    rm -f /tmp/.boxfix_dns_check
    return 0
}

# ========== 检查是否需要同步（含降级标记清理） ==========
needs_sync() {
    local PORT="$1"
    # 配置已同步且无降级标记：不需要
    if is_synced "$PORT" && [ ! -f "$DEGRADED_FLAG" ]; then
        return 1
    fi
    # 配置已同步但有降级标记残留：清除标记，不重启
    if is_synced "$PORT" && [ -f "$DEGRADED_FLAG" ]; then
        log "配置已同步但降级标记残留，清除标记"
        rm -f "$DEGRADED_FLAG"
        return 1
    fi
    return 0
}

# ========== 同步 mihomo 配置（带防抖锁） ==========
sync_mihomo() {
    local PORT="$1"
    [ -f "$CFG" ] || { log "未找到 $CFG，跳过同步"; return 0; }
    [ -n "$PORT" ] || { log "AGH 端口未知，跳过同步"; return 0; }

    # 防抖锁：60 秒内不重复同步
    SYNC_LOCK="/data/adb/agh/.sync_lock"
    if [ -f "$SYNC_LOCK" ]; then
        LAST=$(cat "$SYNC_LOCK" 2>/dev/null)
        NOW=$(date +%s)
        [ -n "$LAST" ] && [ $((NOW - LAST)) -lt 60 ] && { log "60 秒内已同步，跳过"; return 0; }
    fi
    echo "$(date +%s)" > "$SYNC_LOCK"

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

    # 温和停止 mihomo，避免端口/TUN 残留
    pkill -15 -f "mihomo" 2>/dev/null
    local wait_i=0
    while [ $wait_i -lt 6 ]; do
        pgrep -f "mihomo" >/dev/null 2>&1 || break
        wait_i=$((wait_i + 1))
        sleep 0.5
    done
    pgrep -f "mihomo" >/dev/null 2>&1 && pkill -9 -f "mihomo" 2>/dev/null
    sleep 3

    $RESTART_CMD
    log "Box 服务已重启"
}

# ========== 降级到直连模式（带冷却） ==========
degrade_to_direct() {
    # 5 分钟冷却
    check_cooldown "/data/adb/agh/.degrade_cooldown" 300 || { log "降级冷却中，跳过"; return 0; }

    log "代理不可达，降级到直连模式，关闭 tun ..."
    [ -f "$CFG" ] || { log "未找到 $CFG，跳过降级"; return 1; }
    cp -f "$CFG" "$CFG.degbak"
    sed -i '/^tun:/,/^[^ ]/{s/^\([[:space:]]*enable:\).*/\1 false/;}' "$CFG"
    sed -i 's/^\([[:space:]]*enhanced-mode:\).*/\1 redir-host/' "$CFG"
    touch "$DEGRADED_FLAG"
    $RESTART_CMD
    log "已降级到直连模式，tun 已关闭"
}

# ========== 从直连模式恢复（带冷却） ==========
restore_from_degrade() {
    # 5 分钟冷却
    check_cooldown "/data/adb/agh/.restore_cooldown" 300 || { log "恢复冷却中，跳过"; return 0; }

    log "代理已恢复，从直连模式恢复 ..."
    [ -f "$CFG.degbak" ] && cp -f "$CFG.degbak" "$CFG" && rm -f "$CFG.degbak"
    rm -f "$DEGRADED_FLAG"
    touch "$MARK"
    $RESTART_CMD
    log "已从直连模式恢复"
}

# ========== AGH 进程管理 ==========
restart_agh() {
    pkill -9 "AdGuardHome"; sleep 1
    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    "$BIN_DIR/AdGuardHome" --no-check-update &
}

cleanup_standalone() {
    pkill -9 "ProxyConfig"; pkill -9 "iptables.sh"
    iptables -w 2 -t nat -F ADGUARD 2>/dev/null; iptables -w 2 -t nat -X ADGUARD 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -w 2 -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
    rm -f "$CFG.degbak" 2>/dev/null
}

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

write_state() {
    echo "box" > "$STATE_DIR/box_mode" 2>/dev/null || true
    [ -f "$DEGRADED_FLAG" ] && echo "degraded" > "$STATE_DIR/degraded" || echo "ok" > "$STATE_DIR/degraded" 2>/dev/null
}

start_aghproxy() {
    if ! pgrep -f "aghproxy watch" >/dev/null 2>&1; then
        "$SCRIPT_DIR/aghproxy" watch >> "$LOG" 2>&1 &
        log "aghproxy 已启动"
    fi
}

# ============================================================
# 主流程
# ============================================================
log "BoxFix v13.1 稳定版启动"

chmod 755 "$CTL" "$SCRIPT_DIR/aghproxy" "$SCRIPT_DIR/aghbridge" "$SCRIPT_DIR/aghappclean" 2>/dev/null

start_aghproxy
"$SCRIPT_DIR/aghbridge" start >> "$LOG" 2>&1

wait_for_boot
wait_for_agh

degraded=0
last_proxy_ok=1
check_count=0
network_check_counter=0
NETWORK_CHECK_INTERVAL=10

# 初始同步
if box_installed; then
    AGH_PORT=$(get_agh_port)
    log "检查初始配置同步状态"
    if needs_sync "$AGH_PORT"; then
        sync_mihomo "$AGH_PORT"
    else
        log "配置已同步"
    fi

    # 开机恢复：自动选择组无有效节点时（开机测速早于网络就绪），
    # 最多重启 2 次触发 url-test 重新测速，避免长期保持无效节点。
    # 仅在有 curl 可验证时执行；无 curl 时跳过，避免误重启。
    if proxy_reachable && have_curl; then
        retry=0
        while [ $retry -lt 2 ]; do
            if proxy_healthy; then
                log "自动选择组节点有效"
                break
            fi
            retry=$((retry + 1))
            log "自动选择组无有效节点（第 ${retry} 次），重启 Box 触发重新测速"
            rm -f "$SYNC_LOCK"
            $RESTART_CMD
            sleep 30
        done
    fi
fi

# ========== 主循环（30 秒保底） ==========
while true; do
    MODE=$(current_mode)

    if box_installed; then
        AGH_PORT=$(get_agh_port)
        write_state

        # 延迟同步
        if [ $AGH_PENDING -eq 1 ]; then
            AGH_PORT=$(get_agh_port)
            if [ -n "$AGH_PORT" ] && timeout 2 sh -c "echo > /dev/tcp/127.0.0.1/$AGH_PORT" >/dev/null 2>&1; then
                log "AGH 端口已就绪，触发延迟同步"
                sync_mihomo "$AGH_PORT"
                AGH_PENDING=0
                log "延迟同步完成"
            fi
        fi

        # ---- 代理可达性检测 ----
        if proxy_reachable; then
            # 如果当前处于降级状态，尝试恢复
            if [ -f "$DEGRADED_FLAG" ]; then
                log "代理已恢复，从直连模式切回 Box 模式"
                restore_from_degrade
                degraded=0
                cleanup_standalone
            fi
            last_proxy_ok=1
            check_count=0

            # 检查配置是否需要同步（不含降级标记残留的情况）
            if needs_sync "$AGH_PORT"; then
                log "配置需要同步，执行同步"
                sync_mihomo "$AGH_PORT"
            fi

            # 网络健康检测（每 10 轮约 5 分钟）
            network_check_counter=$((network_check_counter + 1))
            if [ $network_check_counter -ge $NETWORK_CHECK_INTERVAL ] || [ "$check_count" -gt 0 ]; then
                network_check_counter=0
                if ! network_reachable; then
                    log "警告：mihomo 运行中但国内网络不可达，可能代理失效"
                    check_count=$((check_count + 1))
                    if [ $check_count -ge 3 ] && [ "$degraded" -eq 0 ]; then
                        degrade_to_direct
                        degraded=1
                        check_count=0
                        write_state
                    fi
                elif ! proxy_healthy; then
                    # 仅记录不重启：自动选择组暂无有效节点时，访问外网会触发
                    # url-test 的 lazy 自动重测，主动重启反而造成频繁断连
                    log "提示：自动选择组暂无有效节点（下次访问外网时自动重测）"
                    check_count=0
                else
                    # 网络恢复时重置计数
                    [ "$check_count" -gt 0 ] && check_count=0
                fi
            fi
        else
            # 代理不可达
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
        # 无 Box，独立模式
        rm -f "$DEGRADED_FLAG" 2>/dev/null
        echo "standalone" > "$STATE_DIR/box_mode" 2>/dev/null
        [ "$MODE" != "random" ] && switch_to_standalone || {
            pgrep -f "iptables.sh" >/dev/null || "$SCRIPT_DIR/iptables.sh" &
            pgrep -f "ProxyConfig.sh" >/dev/null || "$SCRIPT_DIR/ProxyConfig.sh" &
        }
    fi

    sleep 30
done

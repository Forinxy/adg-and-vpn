# AGH 专属管理器（agh-manager）

学习自 Ceromis 的 `agh-dns-helper` Android 项目，为 adg-and-vpn 项目构建的专属管理工具集。
纯 shell 实现，无需安装任何 App，配合 Web 面板使用。

## 组件

| 组件 | 功能 |
|------|------|
| `aghctl` | AGH 生命周期管理（start/stop/restart/sync/rules/cleanup/status） |
| `aghproxy` | VPN/网络状态监控，检测网络变化自动刷新 DNS 拦截 |
| `aghbridge` | 控制桥接器，AGH 崩溃重启时保持控制通道 |
| `aghappclean` | 应用级过滤管理（IFW + 私有 DNS 保护） |
| `aghweb` | Web 管理面板（纯 shell HTTP 服务器，默认端口 8080） |
| `chinese_rules.txt` | 中国 App 广告过滤规则（HTTPDNS 拦截 + 主流 App 广告） |

## 安装

1. 将本目录文件连同 `apply_fix.sh` 一起 push 到设备：
   ```bash
   adb push agh-manager/ /data/local/tmp/
   adb push apply_fix.sh /data/local/tmp/
   ```
2. root 终端执行：
   ```bash
   sh /data/local/tmp/apply_fix.sh
   ```
3. 重启设备，或手动执行：
   ```bash
   pkill -f AdGuardHome && sh /data/adb/modules/AdGuardHome/service.sh &
   ```

## 使用

### Web 面板（推荐）
设备浏览器访问 `http://127.0.0.1:8080/`，可：
- 查看运行状态 / 工作模式 / DNS 端口 / 代理状态
- 启动 / 停止 / 重启 AGH
- 同步 Box 配置
- 清理劫持规则
- 查看最近日志

### 命令行
```bash
# 状态查询
sh /data/adb/agh/scripts/aghctl status
sh /data/adb/agh/scripts/aghctl mode
sh /data/adb/agh/scripts/aghctl port
sh /data/adb/agh/scripts/aghctl proxy-state

# 控制
sh /data/adb/agh/scripts/aghctl start
sh /data/adb/agh/scripts/aghctl stop
sh /data/adb/agh/scripts/aghctl sync    # 同步 mihomo 配置并重启 Box
sh /data/adb/agh/scripts/aghctl cleanup
```

## 关键改进（相对 v9）

1. **修复重启后 Box 需手动重启的问题**：BoxFix v10 等待 `sys.boot_completed` 后再进入主循环，
   避免开机早期 Box 未就绪就被干扰重启；每次启动先等待 Box 代理可达（最多 10 分钟）才做首次同步
2. **减少无谓重启**：`needs_sync` 仅在配置真正失配时才重启 Box
3. **VPN 检测**：`aghproxy` 每 3 秒监控网络状态，VPN 切换时自动刷新 DNS 拦截
4. **中国 App 规则**：注入 HTTPDNS 拦截 + 抖音/快手/哔哩哔哩/微博/美团/百度等主流 App 广告过滤规则
5. **Web 面板**：无需安装 App，浏览器即可管理

## 规则来源

`chinese_rules.txt` 提炼自 Ceromis Android 项目的 AdGuardHome.yaml user_rules，
保留对国内主流 App 广告域的拦截与关键误杀放行，并补充 HTTPDNS 拦截（防止 App 绕过 AGH DNS 过滤）。

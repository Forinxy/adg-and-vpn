# adg-and-vpn

AdGuard Home 与 Box for Root 模块共存方案（方案A）。

## 背景

AdGuard Home（DNS 广告过滤）与 Box for Root（VPN 代理分流）同时安装时，原版两模块会在 DNS 上互相冲突：

- AGH 将全部 TCP/UDP 53 重定向到自身随机端口，同时 DROP 所有 IPv6 DNS
- Box 也劫持 53 到 mihomo 的 DNS 端口
- 两者规则互相覆盖/竞争，导致部分应用断网、国内外分流异常

## 方案A（本方案）

- **AGH 只做广告过滤上游**：监听 `127.0.0.1`（DNS），默认固定 5591，也可选随机端口，两种端口均自动同步给 Box
- **mihomo 全权接管 DNS 与分流**：`enhanced-mode: fake-ip`，`tun.enable: true`，开启 sniffer
- **mihomo 的 nameserver 指向 AGH**：每次域名解析先经 AGH 过滤再走 DoH 上游
- 单一 DNS 链路：应用 DNS → Box 劫持 → mihomo:1053 → AGH(过滤) → DoH 上游

## 自动化机制

`scripts/BoxFix.sh`（AGH 模块自带自适应协调器）每 30 秒检查一次环境状态，**无需关心 Box 与 AGH 的安装顺序**：

- **检测到 Box**（`/data/adb/box` 存在）：AGH 作为广告过滤上游，mihomo 配置自动同步
  - 读取 AGH **实际 DNS 端口**（随机端口或固定 5591 均可），同步写入 mihomo 的 nameserver
  - 修正 mihomo 配置为 `fake-ip`，AGH 不劫持 53
  - 即使 Box 模块被重刷还原配置，也会自动重新修正，无需用户干预
- **未检测到 Box**：自动切换到随机端口独立模式
  - AGH 随机端口并劫持 53 做广告过滤，恢复原版独立行为
- **卸载 AGH**：`uninstall.sh` 自动还原 Box 的 mihomo 配置并重启 Box 服务，不会断网

## 独立使用

两模块可独立安装，各自功能完整：

- **只装 Box**：完全原版行为，不受任何影响
- **只装 AGH**：自动进入随机端口独立模式，劫持 53 过滤广告，等同原版
- **同时安装**：AGH 作为上游（端口自动同步给 Box），单一 DNS 链路

## 安装（发行版）

只需重刷 AGH 模块一个包：

1. 删除原 `AdGuard.Home.For.Android.20260720.zip`，使用 `AdGuard.Home.For.Android.20260720-fixed.zip`
2. 在 Magisk/KernelSU 管理器中安装该包
3. 安装过程中**通过音量键选择 DNS 端口模式**：
   - `音量加(+)= 随机端口`：AGH 使用随机端口。检测到 Box 时自动同步该端口给 Box（共存），无 Box 时独立劫持 53
   - `音量减(-)= 固定端口（5591）`：AGH 固定 5591，检测到 Box 时自动同步给 Box（共存），无 Box 时自动转随机独立
   - 10 秒内未选择自动默认：检测到 Box 时默认固定端口，未检测到 Box 时默认随机端口
4. 安装完成后重启

> 选择结果保存在 `/data/adb/agh/.port_mode`。**无论选随机还是固定，只要检测到 Box，BoxFix 都会把 mihomo 的 nameserver 自动同步到 AGH 实际端口**；若环境变化（安装/卸载 Box），协调器自动收敛，无需重新安装或手动改配置。
> Box 模块保持原版即可，不要重刷 `box_1.2.9.f15c940-fixed.zip`（其安装脚本会用旧备份覆盖新配置）。

## 更新上游 ADG 后如何重新修复

本模块基于他人维护的开源 AdGuardHome 模块。上游出新版本时，若直接重刷新包，共存的修复（BoxFix 协调器、service/uninstall 修改）会**被覆盖丢失**。重新应用修复有两种方式：

### 方式一：一键修复脚本（推荐）

1. 直接重刷上游的新版 AdGuardHome 包（无需本仓库的 fixed 包）
2. 将本仓库的 `apply_fix.sh` 推到设备（如 `adb push apply_fix.sh /data/local/tmp/`）
3. root 终端执行：

```bash
sh /data/local/tmp/apply_fix.sh
```

脚本会自动：写入 `scripts/BoxFix.sh`、修改 `service.sh` 启动 BoxFix、修改 `uninstall.sh` 卸载时还原 Box 配置、清空 `config.prop` 的 PROXY_URL、重新锁定脚本。

> 注意：音量键端口模式选择（customize.sh）在重刷上游包后也会丢失，`apply_fix.sh` 不恢复该功能（需改 customize.sh）；若无此需求可直接使用。

### 方式二：重新打包（需要本仓库维护者）

将上游新版 zip 交给维护者，维护者重新应用修复后产出发行包 `AdGuard.Home.For.Android.20260720-fixed.zip` 发布到本仓库 Release。

## 验证

### 检测到 Box（随机或固定端口共存）
- `iptables -t nat -L ADGUARD` 应为空（无 53 劫持）
- AGH 监听 `127.0.0.1`（DNS）与 `127.0.0.1:40165`（Web UI），DNS 端口为实际配置值
- `/data/adb/box/mihomo/config.yaml` 中 `enhanced-mode: fake-ip`，nameserver 指向 `127.0.0.1:<AGH实际DNS端口>`

### 未检测到 Box（随机端口独立）
- AGH 随机端口（范围 30000-65535）劫持 53
- 实际端口查看 `/data/adb/agh/scripts/config.prop` 中的 `redir_port`

## 回滚

- **共存模式**：将 `/data/adb/box/mihomo/config.yaml.aghbak` 还原为 `/data/adb/box/mihomo/config.yaml`，重刷原版 AGH 包即可
- **独立模式**：直接重刷原版 AGH 包即可（该模式不修改 Box 配置）
- 也可删除 `/data/adb/agh/.port_mode` 后重刷模块，重新通过音量键选择模式

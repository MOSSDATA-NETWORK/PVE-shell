# PVE-shell

Proxmox VE 实用脚本集。面向 PVE 母机的日常运维：VM 出网管控、滥用防护、自动化巡检等。

## 脚本目录

| 脚本 | 用途 | 特性 |
|---|---|---|
| [vm-netguard](vm-netguard/) | VM 出网管控：禁 SMTP/BT 出站、按域名拦截恶意站点（SNI/DNS） | 幂等 / IPv4+IPv6 / 一键安装卸载 |
| [pve-optimize.sh](pve-optimize.sh) | PVE 宿主机内核参数自适应优化：ulimit / sysctl / THP / CPU 调频 / KSM / IO 调度 / ZFS ARC / NTP | 按 CPU/内存自动分档 / 备份回滚 / 支持国内·香港·海外 NTP |
| [pve-nosub.sh](pve-nosub.sh) | 切换 no-subscription 源 + 去「无订阅」弹窗（apt 钩子持久化，升级后自动重补丁）；可选一键系统更新 | 幂等 / 默认不更新系统 / 兼容 deb822 与 .list / 备份回滚 |

## 使用约定

- **一个脚本一个目录**：主脚本 + 配套文件（systemd unit 等）+ `README.md`，自包含、可单独取用
- 所有脚本**幂等**：可重复执行，不产生重复规则或重复配置
- 改动系统行为的脚本必须提供 **install / uninstall** 子命令：一键部署、干净回滚
- 只依赖 PVE 系统自带工具（bash / systemd / iptables / ip6tables / sysctl），不引入第三方依赖
- 兼容 PVE 7.x / 8.x / 9.x（Debian 11 / 12 / 13）；vm-netguard 已在 **PVE 9.2**（kernel 7.0-pve，br_netfilter 内置）生产环境实测

## 快速取用

**vm-netguard**（VM 出网管控）：
```bash
# 安装（脚本自包含，自动生成 systemd service）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/vm-netguard/vm-netguard.sh) install

# 卸载
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/vm-netguard/vm-netguard.sh) uninstall
```

**pve-optimize.sh**（宿主机优化）：
```bash
# 预览（不写入，先看会改什么）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize.sh) --dry-run

# 执行优化（自动检测区域、备份原配置）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize.sh)

# 海外服务器指定 NTP 区域
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize.sh) --region intl

# 香港服务器（北京时间 + 本地 NTP）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize.sh) --region hk

# 回滚到上次备份
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize.sh) --restore
```

**pve-nosub.sh**（换 no-subscription 源 + 去弹窗 + 更新）：
```bash
# 预览（不写入，先看会改什么）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub.sh) --dry-run

# 默认执行：禁用 enterprise 源 → 启用 no-subscription 源 → 去弹窗（含持久化钩子），不更新系统
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub.sh)

# 追加系统更新（全自动免交互：跳过变更日志阅读，配置冲突保留现有配置）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub.sh) --upgrade

# 回滚到上次备份（含恢复弹窗）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub.sh) --restore
```

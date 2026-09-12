# PVE-shell

Proxmox VE 实用脚本集。面向 PVE 母机的日常运维：VM 出网管控、滥用防护、自动化巡检等。

## 脚本目录

| 脚本 | 用途 | 特性 |
|---|---|---|
| [vm-netguard](vm-netguard/) | VM 出网管控：禁 SMTP/BT 出站、按域名拦截恶意站点（SNI/DNS） | 可重复执行 / IPv4+IPv6 / 一键安装卸载 |
| [pve-arpfilter](pve-arpfilter/) | VM 入向 ARP 广播降噪：大扁平二层段网关 ARP 轮询噪声（每台 VM 恒定多收 17~24KB/s）按「目标 IP ∈ 本机 IP 集合」过滤 | 被动学习免配置 / fail-open 不断网 / 灰度白名单 / 一键安装卸载 |
| [pve-optimize](pve-optimize/) | PVE 宿主机内核参数自适应优化：ulimit / sysctl / THP / CPU 调频 / KSM / IO 调度 / ZFS ARC / NTP | 按 CPU/内存自动分档 / 备份回滚 / 支持国内·香港·海外 NTP |
| [pve-nosub](pve-nosub/) | 切换 no-subscription 源 + 去「无订阅」弹窗（apt 钩子持久化，升级后自动重补丁）；可选一键系统更新 | 可重复执行 / 默认不更新系统 / 兼容 deb822 与 .list / 备份回滚 |

## 使用约定

- **一个脚本一个目录**：主脚本 + 配套文件（systemd unit 等）+ `README.md` 详细介绍，自包含、可单独取用
- 所有脚本**可重复执行**：跑多遍和跑一遍效果相同，不会产生重复规则或重复配置
- 改动系统行为的脚本必须提供 **install / uninstall 或 backup / restore**：一键部署、干净回滚
- 只依赖 PVE 系统自带工具（bash / python3 / systemd / iptables / nftables / tcpdump / sysctl / apt），不引入第三方依赖
- 兼容 PVE 7.x / 8.x / 9.x（Debian 11 / 12 / 13）；vm-netguard、pve-arpfilter 已在 **PVE 9.2**（kernel 7.0-pve）生产环境实测

## 快速取用

**pve-arpfilter**（VM 入向 ARP 广播降噪）：
```bash
# 安装（脚本自包含，自动生成 systemd service）
sudo python3 <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-arpfilter/pve-arpfilter.py) install

# 灰度（只对列出的 VM 装规则）
printf '481\n204\n' | sudo tee /etc/pve/arpfilter.whitelist

# 卸载
sudo /usr/local/sbin/pve-arpfilter.py uninstall
```

**vm-netguard**（VM 出网管控）：
```bash
# 安装（脚本自包含，自动生成 systemd service）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/vm-netguard/vm-netguard.sh) install

# 卸载
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/vm-netguard/vm-netguard.sh) uninstall
```

**pve-optimize**（宿主机优化）：
```bash
# 执行优化（自动检测区域、备份原配置）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize/pve-optimize.sh)

# 海外服务器指定 NTP 区域
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize/pve-optimize.sh) --region intl

# 香港服务器（北京时间 + 本地 NTP）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize/pve-optimize.sh) --region hk

# 回滚到上次备份
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize/pve-optimize.sh) --restore
```

**pve-nosub**（换 no-subscription 源 + 去弹窗）：
```bash
# 默认执行：禁用 enterprise 源 → 启用 no-subscription 源 → 去弹窗（含持久化钩子），不更新系统
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub/pve-nosub.sh)

# 追加系统更新（全自动免交互：跳过变更日志阅读，配置冲突保留现有配置）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub/pve-nosub.sh) --upgrade

# 回滚到上次备份（含恢复弹窗）
sudo bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-nosub/pve-nosub.sh) --restore
```

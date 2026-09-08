# PVE-shell

Proxmox VE 实用脚本集。面向 PVE 母机的日常运维：VM 出网管控、滥用防护、自动化巡检等。

## 脚本目录

| 脚本 | 用途 | 特性 |
|---|---|---|
| [vm-netguard](vm-netguard/) | VM 出网管控：禁 SMTP/BT 出站、按域名拦截恶意站点（SNI/DNS） | 幂等 / IPv4+IPv6 / 一键安装卸载 |

## 使用约定

- **一个脚本一个目录**：主脚本 + 配套文件（systemd unit 等）+ `README.md`，自包含、可单独取用
- 所有脚本**幂等**：可重复执行，不产生重复规则或重复配置
- 改动系统行为的脚本必须提供 **install / uninstall** 子命令：一键部署、干净回滚
- 只依赖 PVE 系统自带工具（bash / systemd / iptables / ip6tables / sysctl），不引入第三方依赖
- 兼容 PVE 7.x / 8.x（Debian 11 / 12）

## 快速取用

```bash
git clone https://github.com/MOSSDATA-NETWORK/PVE-shell.git
cd PVE-shell/vm-netguard
sudo ./vm-netguard.sh install
```

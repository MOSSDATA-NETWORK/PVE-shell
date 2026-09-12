# pve-optimize — PVE 宿主机内核参数自适应优化

根据 **CPU 核心数和内存大小自动分档**，调整 PVE 母机的内核与资源参数。适用 PVE 7.x / 8.x / 9.x。

## 优化项

| 项目 | 内容 |
|---|---|
| ulimit / 文件描述符 | `limits.conf`、`/etc/profile`、PAM，按档位 52万~200万 |
| systemd DefaultLimit | `DefaultLimitNOFILE/NPROC/MEMLOCK/CORE` |
| journald | 日志上限 300M |
| sysctl | 网络（BBR、TCP 缓冲、backlog、conntrack）、内存（dirty、min_free）、转发、安全加固 |
| THP 透明大页 | 设为 `madvise`，关闭 khugepaged 主动合并（避免 VM 延迟毛刺） |
| CPU 调频 | 固定 `performance` |
| KSM 内存同页合并 | 按档位调扫描参数并启用 |
| 磁盘 IO 调度器 | SSD→mq-deadline / NVMe·virtio→none / HDD→bfq，udev 规则持久化 |
| ZFS ARC | 检测到 ZFS 时限制 ARC 上限（防 ARC 膨胀挤占 VM 内存） |
| 时区与 NTP | 统一北京时间（Asia/Shanghai），chrony 按区域选源 |

**不改动** PVE 依赖项：防火墙、conntrack 模块、irqbalance、`/etc/sysctl.d/` 下 PVE 自带配置、AppArmor。

## 分档规则

| 档位 | 条件 | 典型值 |
|---|---|---|
| small | ≤4核 且 ≤8G | conntrack 52万 / TCP 缓冲 64M |
| medium | ≤16核 且 ≤64G | conntrack 105万 / TCP 缓冲 128M |
| large | >16核 或 >64G | conntrack 210万 / TCP 缓冲 256M |

## 使用

```bash
# 执行优化（自动检测区域、备份原配置）
bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize/pve-optimize.sh)

# 指定 NTP 区域：cn 国内 / hk 香港 / intl 海外（默认按当前时区自动检测）
bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize/pve-optimize.sh) --region intl

# 回滚到上次备份
bash <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-optimize/pve-optimize.sh) --restore
```

执行后建议重启宿主机使全部参数生效。

## 备份与回滚

改动前把涉及的配置文件备份到 `/root/pve-optimize-backup/<时间戳>/`（含 `/etc/sysctl.d/` 整目录）。`--restore` 从最近一次备份还原并重新加载 sysctl / systemd / journald。

## 验证

脚本结束自动打印关键参数当前值（拥塞控制、somaxconn、conntrack、THP、CPU 调频、KSM、ZFS ARC 等），逐项核对即可。

## 文件清单

| 文件 | 说明 |
|---|---|
| `pve-optimize.sh` | 主脚本（默认优化；`--region` / `--restore`） |

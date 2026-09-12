# pve-arpfilter-static

PVE 母机 VM 入向 ARP 广播降噪 · **面板映射文件版**。

与 [pve-arpfilter](../pve-arpfilter/)（被动学习版）解决同一个问题：大扁平二层段里网关疯狂 ARP 轮询，每台 VM 恒定多收 17~24KB/s 广播垃圾。区别在于 **IP 集合的来源**：

| | 被动学习版 `pve-arpfilter` | 本版 `pve-arpfilter-static` |
|---|---|---|
| IP 来源 | 监听 ARP 自学 + cloud-init | **面板下发映射文件** + cloud-init |
| 外部依赖 | 无 | 面板写 `/etc/pve/arpfilter/` 目录 |
| 行为确定性 | 最佳努力（学不到的不过滤） | 完全确定（文件写了才算数） |
| 资源占用 | 每网桥一个 tcpdump | 无监听，更轻 |
| 适用 | 面板无法提供 IP 清单 | 面板能提供 IP 清单 |

**两版用同一个 nft 表名（`pve-arpfilter`），同一台宿主机不要同时装。**

## 映射文件格式（面板对接点）

路径：`/etc/pve/arpfilter/<VMID>.<网卡序号>.ips`

- 每行一个 IPv4 地址；`#` 开头为注释；空行忽略
- 一台 VM 有几块网卡就放几个文件（net0 → `<VMID>.0.ips`，net1 → `<VMID>.1.ips`）
- VM 删除/关机后面板可删文件（不删也无妨：VM 停止后 tap 消失，规则自动移除）
- 文件更新后最长 60 秒自动生效（调和周期）
- **面板必须原子写入**：先写 `<vmid>.<net>.ips.tmp` 再 `mv` 成正式名。任何非法行会导致整个文件被拒绝应用（fail-open），半成品文件不会造成部分 IP 集合

示例见 [example/](example/) 目录（用的是 RFC 5737 文档示例地址段，非真实地址）：

```
/etc/pve/arpfilter/100.0.ips      # VM 100 的 net0
/etc/pve/arpfilter/100.1.ips      # VM 100 的 net1
```

## 用法

```bash
# 安装（脚本自包含，自动生成 systemd service，自动建映射目录）
python3 <(curl -sSL https://raw.githubusercontent.com/MOSSDATA-NETWORK/PVE-shell/main/pve-arpfilter-static/pve-arpfilter-static.py) install

# 面板下发示例
echo '192.0.2.10' | tee /etc/pve/arpfilter/100.0.ips

# 状态
/usr/local/sbin/pve-arpfilter-static.py status

# 卸载（VM 网络立即恢复原样，映射文件目录保留）
/usr/local/sbin/pve-arpfilter-static.py uninstall
```

## 灰度发布

与被动学习版共用同一个白名单文件 `/etc/pve/arpfilter.whitelist`：存在且非空时只对列出的 VMID 装规则。

## 过滤语义（与被动学习版相同）

- nftables bridge 族 forward 钩子，vmap 按 tap 口哈希跳转到 per-VM 链（O(1)，不随 VM 数线性退化）
- 只放行「ARP 询问目标 IP ∈ 该 VM 的 IP 集合」（含 802.1Q 标签变体）；STP BPDU 全 tap 口统一丢弃
- **细流安全阀**：集合外 ARP 限速 5/s 放行（≈300B/s）——映射文件过期未更新时合法 ARP 靠网关重传大概率仍能到达；不是绝对保证（噪声饱和时单包可能丢，VIP/HA 场景可能秒级延迟）
- **fail-open**：映射文件和 cloud-init 都没有该 VM 的 IP → 不装规则，绝不影响通信
- 每轮调和都逐块校验活表内容（防外部 flush/篡改后静默失效），不一致即原子重建
- 回滚：`uninstall` 或手工 `systemctl stop pve-arpfilter-static && nft destroy table bridge pve-arpfilter`

## 已知边界

- 只降 ARP/STP 噪声；IPv6 ND/RA、DHCP 广播等残余约 0.5KB/s
- 映射文件内容由面板负责准确性；写错 IP（写了不属于该 VM 的地址）的后果只是该 VM 多收对应 ARP 噪声，不影响别人
- 依赖：PVE 自带的 python3 / nftables（v1.x）/ systemd

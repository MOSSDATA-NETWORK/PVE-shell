# pve-arpfilter

PVE 母机 VM 入向 ARP 广播降噪。解决「大扁平二层段里，上游网关对整段 IP 疯狂 ARP 轮询，广播被送到每台 VM，每台 VM 恒定多收 17~24KB/s（约 140~190kbps）垃圾流量、计入客户流量统计」的问题。

## 原理

VM 网卡拓扑（PVE firewall=1 时）：`tapXidYiN → fwbr小网桥 → fwln/fwpr veth对 → 主网桥`。

本工具在 nftables **bridge 族 forward 钩子**上建独立表 `pve-arpfilter`：

1. 按 `oifname`（VM 的 tap 口）经 **vmap 哈希跳转**到该 VM 的专属链（O(1)，不随 VM 数量线性退化）
2. 链内规则：**只放行「ARP 询问目标 IP ∈ 该 VM 自己的 IP 集合」的 ARP**（含 802.1Q 标签变体），其余 ARP 广播丢弃；STP BPDU（`01:80:c2:00:00:00`）对所有 tap 口统一丢弃
3. VM 正常通信不受影响：网关问 VM 自己的 IP → 放行；VM 发出的 ARP → 本工具不过滤（只过滤入向）；单播 IP 流量 → 不过滤（且已配合 `bridge-disable-mac-learning` + 静态 FDB，无泛洪）

## VM IP 集合从哪来（无需面板配合）

| 来源 | 说明 | 优先级 |
|---|---|---|
| VM 配置的 `ipconfigN`（cloud-init） | 静态、权威 | 高 |
| **被动学习** | 主网桥上常驻 `tcpdump arp`（内核 BPF 过滤，实测桥上 ARP 仅约 200 小包/秒，开销可忽略），从 VM 自己发出的 ARP 提取 源MAC→源IP。配了 IPv4 的 VM 几乎必然发 ARP（解析网关） | 补充 |

- 学习条目 **TTL 4 小时**，观测到即刷新；VM 停止后其 tap 消失、规则随即移除
- 学习只接受 **VM 配置里登记过的 MAC**（陌生 MAC 直接忽略）。已知残余风险：恶意 VM 冒用**别人的** MAC 伪造 ARP，可往受害 VM 的白名单塞多余 IP——后果仅是受害者多收少量 ARP 噪声，不影响其通信，接受
- **细流安全阀**：每条 VM 链对白名单外的 ARP 按 5 个/秒限速放行（≈300B/s）——换 IP、学习失效等极端场景下，合法 ARP 靠网关重传大概率能到达。注意这不是绝对保证：噪声打满限速器时单个 ARP 仍可能被丢，VIP/HA/多网关场景可能出现秒级入向延迟
- **fail-open 原则**：某台 VM 拿不到任何 IP → 不装规则，噪声照旧但绝不影响通信。静默静态 IP、从不发 ARP 的 VM 属于此类（定位是最佳努力降噪，不追求 100% 覆盖）

## 用法

```bash
# 安装（脚本自包含，自动生成 systemd service 并启动）
bash pve-arpfilter.py install

# 状态
/usr/local/sbin/pve-arpfilter.py status

# 卸载（VM 网络立即恢复原样）
/usr/local/sbin/pve-arpfilter.py uninstall
```

## 灰度发布

建立 `/etc/pve/arpfilter.whitelist`，每行一个 VMID：文件存在且非空时**只对列出的 VM 装规则**，其余 VM 不受影响。删掉该文件或置空即恢复全量。

```bash
printf '481\n204\n' > /etc/pve/arpfilter.whitelist   # 先灰度两台
```

## 文件

| 路径 | 作用 |
|---|---|
| `/usr/local/sbin/pve-arpfilter.py` | 守护进程（学习 + 调和，每分钟一次） |
| `/etc/systemd/system/pve-arpfilter.service` | 开机自启（After pve-guests） |
| `/var/lib/pve-arpfilter/state.json` | 学习状态（重启后 TTL 内有效） |
| `/etc/pve/arpfilter.whitelist` | 可选灰度白名单 |

## 设计约束与已知边界

- **只降 ARP/STP 噪声**；IPv6 ND/RA、DHCP 广播等残余约 0.5KB/s，二期再议
- 与 PVE 自带防火墙互不影响（独立 nft 表、固定 chain 优先级 0；PVE 防火墙当前 Datacenter 级 enable:0）
- 换 IP 自愈：VM 发出新 IP 的 ARP 后数秒内学到；旧条目最多残留 4 小时（只多放行少量噪声，无断网风险）
- 回滚：`uninstall` 或手工 `systemctl stop pve-arpfilter && nft destroy table bridge pve-arpfilter`
- 依赖：PVE 自带的 python3 / tcpdump / nftables（v1.x，需支持 `destroy` 命令）/ systemd
- 已在 **PVE 9.2**（kernel 7.0-pve）生产实测：单台试点降噪 95%+，连通性无损

## 验证方法

```bash
# 过滤前后对比某台 VM 的入向速率（tap 口 RX 即发给 VM 的流量）
grep tap481i0 /proc/net/dev   # 间隔 20 秒各取一次，第 10 列差值/时间

# 看 nft 规则命中计数（需自行给规则加 counter）
nft list table bridge pve-arpfilter

# 确认 VM 通信正常
ping <VM_IP>
```

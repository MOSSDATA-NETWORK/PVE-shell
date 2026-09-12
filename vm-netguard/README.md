# vm-netguard — PVE 母机 VM 出网管控

在 **PVE 母机**上限制其下所有 VM 的出网行为，一次部署对母机全部 VM 生效，无需逐台配置：

1. **禁对外 SMTP / BT**：25, 26, 465, 587（发信）与 6880:6999（BT）静默 DROP——反垃圾邮件、反 BT 滥用
2. **按域名拦截**：VM 无法访问指定站点（默认拦截 `shlii.io`（NAT VPS / 切鸡 / 机场平台）与 `userlocations.googleapis.com`）

兼容 PVE 7.x / 8.x / 9.x。已在 **PVE 9.2**（pve-manager 9.2.11，kernel 7.0.14-14-pve）生产环境实测；该内核 br_netfilter 编译进内核而非模块，脚本两种形态都兼容。

## 为什么做在母机转发层

| 方案 | 为什么不行 |
|---|---|
| 封 IP | 目标站在 Cloudflare 后面，封 IP 会误伤 CF 上所有网站 |
| 母机 `/etc/hosts` | VM 用自己的 DNS，不读母机 hosts |
| PVE 自带防火墙 | 只能封 IP/端口，拦不了「域名」，且默认策略全 DROP 风险大 |
| 逐台 VM 内部处理 | 几百台 VM 不现实，且租户可重装系统绕过 |

正确位置是母机的 **FORWARD 链 + 字符串匹配**：VM 流量必经母机转发，从 TLS 握手（SNI）、HTTP 明文、DNS 查询三个层面匹配域名关键字，与 VM 用什么 DNS、是否独立公网 IP 无关。

## 拦截原理

**前提**：VM 流量是桥接出去的（`bridge-nf-call-iptables=0` 时桥接流量不过 netfilter，规则全部无效）。脚本第一步会打开三个内核开关（这也是 PVE 官方默认值）：

```
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

**域名匹配分两种**：

- **TCP 443（SNI）/ TCP 80（HTTP 明文）/ UDP 443（QUIC 握手）**：握手包里域名是明文，直接文本匹配 `shlii.io`
- **DNS（53）**：DNS 报文里域名按「长度前缀+标签」编码，`shlii.io` 实际存储为 `\x05shlii\x02io\x00`——**连续字符串 "shlii.io" 在报文里根本不存在**，文本匹配永远 0 命中。脚本用纯 bash 把任意域名转成十六进制模式再匹配（`domain_to_hex` 函数），这是本脚本踩过并修掉的坑

**重要**：所有规则都带 `STRING match "域名"` 条件，**不是封端口**——只有「连往该域名」的包被拦，VM 的其他 443/53/QUIC 业务零影响（对照站点实测照常通）。

## 规则清单

| 层面 | 协议/端口 | 匹配 | 动作 |
|---|---|---|---|
| SMTP/BT | TCP 25,26,465,587,6880:6999 | 端口 | DROP（v4+v6） |
| HTTPS | TCP 443 | SNI 含域名 | REJECT (tcp-reset) |
| HTTP | TCP 80 | 内容含域名 | REJECT (tcp-reset) |
| QUIC/HTTP3 | UDP 443 | 握手含域名 | REJECT (icmp) |
| DNS | UDP/TCP 53 | 查询含域名（hex 模式） | REJECT |

QUIC/UDP 443 必须拦：只拦 TCP 时，xray 系工具和浏览器会自动降级走 HTTP/3 继续连，UDP 443 规则堵的就是这条绕过通道。

## 安装

```bash
git clone https://github.com/MOSSDATA-NETWORK/PVE-shell.git
cd PVE-shell/vm-netguard
./vm-netguard.sh install
```

`install` 做三件事：脚本装入 `/usr/local/sbin/vm-netguard.sh`、注册 systemd 开机自启（`vm-netguard.service`）、立即应用规则。母机重启后规则自动恢复。

只想临时应用（不持久化）：

```bash
./vm-netguard.sh apply
```

## 验证

在一台 VM 里执行（`example.com` / `cloudflare.com` 是对照组，证明不误伤）：

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 https://shlii.io/     # 预期 000（被拦）
curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 https://example.com/  # 预期 200
timeout 5 dig +short @8.8.8.8 shlii.io A   # 预期无结果（connection refused）
timeout 5 dig +short @8.8.8.8 example.com  # 预期正常返回 IP
```

母机上看命中计数：

```bash
iptables -nvL FORWARD | grep -E 'shlii|multiport'
```

## 卸载（干净回滚）

```bash
./vm-netguard.sh uninstall
```

删规则、还原三个内核开关、删服务与文件，约 30 秒还原到部署前状态。

## 自定义

编辑脚本顶部配置区：

```bash
BLOCK_DOMAINS="shlii.io userlocations.googleapis.com"  # 空格分隔可写多个，DNS 十六进制模式自动生成
DROP_PORTS="25,26,465,587,6880:6999"  # iptables multiport 格式
```

改完执行 `vm-netguard.sh apply` 即生效（可重复执行，不会叠加旧规则）。

## 已知边界

- **已建立的连接不会被掐断**：拦截生效于新连接的握手包，目标站的既有连接存活到自然断开（通常几分钟内）
- **TLS 加密 SNI（ECH）理论上可绕过**域名层拦截：主流客户端尚未默认启用，但这是域名拦截的技术极限；要强制管控请配合按端口/流量的其他手段
- **DNS qname 大小写随机化**理论上可绕过 DNS 层（bm 算法区分大小写），但 TCP/UDP 443 层仍然兜底
- `uninstall` 还原内核开关为 0；若机器上另启用了 PVE 防火墙等依赖 bridge-nf 的功能，请手动保持为 1

## 文件清单

| 文件 | 说明 |
|---|---|
| `vm-netguard.sh` | 主脚本（apply / install / uninstall） |
| `vm-netguard.service` | systemd unit（`install` 会自动生成，此处供手动安装参考） |

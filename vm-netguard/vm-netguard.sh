#!/bin/bash
# vm-netguard — PVE 母机 VM 出网管控
# 仓库: https://github.com/MOSSDATA-NETWORK/PVE-shell/tree/main/vm-netguard
#
# 用法:
#   vm-netguard.sh apply      立即应用规则（幂等，可重复执行）
#   vm-netguard.sh install    完整安装: 脚本装入 /usr/local/sbin + systemd 开机自启 + 立即应用
#   vm-netguard.sh uninstall  完全卸载: 删规则、还原内核开关、删服务与文件
#
# 功能:
#   1) 禁止 VM 对外 SMTP / BT 端口（反垃圾邮件、反 BT 滥用）
#   2) 按域名拦截 VM 访问指定站点（TLS SNI / HTTP 明文 / DNS 查询 三层匹配）
#
# 原理与验证方法见同目录 README.md

set -u

# ==================== 配置区（按需修改） ====================
# 要拦截的域名，空格分隔可写多个（会自动生成对应的 DNS 十六进制匹配模式）
BLOCK_DOMAINS="shlii.io"
# 禁止 VM 对外连接的 TCP 端口（iptables multiport 格式，支持 a,b,c:d）
DROP_PORTS="25,26,465,587,6880:6999"
# ============================================================

SCRIPT_NAME="vm-netguard"
INSTALL_PATH="/usr/local/sbin/${SCRIPT_NAME}.sh"
UNIT_PATH="/etc/systemd/system/${SCRIPT_NAME}.service"
SYSCTL_CONF="/etc/sysctl.d/99-${SCRIPT_NAME}.conf"

# 域名转 DNS 线上格式的十六进制匹配模式
# "shlii.io" -> |0573686c696902696f00|
# DNS 报文里域名按「长度前缀+标签」编码，连续的 "shlii.io" 字符串并不存在，
# 所以 DNS 层必须用 hex-string 匹配，纯文本永远 0 命中
str2hex() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    printf -v c '%02x' "'${s:i:1}"
    out+="$c"
  done
  printf '%s' "$out"
}

domain_to_hex() {
  local label pat="" hex
  IFS='.' read -ra _labels <<< "$1"
  for label in "${_labels[@]}"; do
    printf -v hex '%02x' "${#label}"
    pat+="$hex$(str2hex "$label")"
  done
  printf '|%s00|' "$pat"
}

apply_rules() {
  # 1) 桥接流量过 netfilter（PVE 官方默认值为 1；为 0 时下列规则对桥接 VM 全部无效）
  modprobe br_netfilter 2>/dev/null || true
  sysctl -w net.bridge.bridge-nf-call-iptables=1  >/dev/null
  sysctl -w net.bridge.bridge-nf-call-arptables=1 >/dev/null
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null
  cat > "$SYSCTL_CONF" <<'EOF'
# vm-netguard 依赖：桥接 VM 流量过 netfilter（PVE 官方默认值）
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

  # 2) 幂等添加 FORWARD 规则（已存在则跳过，重复执行不叠加）
  add4() { iptables  -C FORWARD "$@" 2>/dev/null || iptables  -I FORWARD 1 "$@"; }
  add6() { ip6tables -C FORWARD "$@" 2>/dev/null || ip6tables -I FORWARD 1 "$@"; }

  # 禁 VM 对外 SMTP / BT（静默 DROP，双栈）
  add4 -p tcp -m multiport --dports "$DROP_PORTS" -j DROP
  add6 -p tcp -m multiport --dports "$DROP_PORTS" -j DROP

  # 按域名拦截（双栈）：SNI(443) / HTTP(80) / QUIC(UDP 443) / DNS(53)
  local d hex
  for d in $BLOCK_DOMAINS; do
    hex=$(domain_to_hex "$d")
    add4 -p tcp --dport 443 -m string --string "$d" --algo bm -j REJECT --reject-with tcp-reset
    add6 -p tcp --dport 443 -m string --string "$d" --algo bm -j REJECT --reject-with tcp-reset
    add4 -p tcp --dport 80 -m string --string "$d" --algo bm -j REJECT --reject-with tcp-reset
    add6 -p tcp --dport 80 -m string --string "$d" --algo bm -j REJECT --reject-with tcp-reset
    add4 -p udp --dport 443 -m string --string "$d" --algo bm -j REJECT --reject-with icmp-port-unreachable
    add6 -p udp --dport 443 -m string --string "$d" --algo bm -j REJECT --reject-with icmp6-port-unreachable
    add4 -p udp --dport 53 -m string --hex-string "$hex" --algo bm -j REJECT --reject-with icmp-port-unreachable
    add6 -p udp --dport 53 -m string --hex-string "$hex" --algo bm -j REJECT --reject-with icmp6-port-unreachable
    add4 -p tcp --dport 53 -m string --hex-string "$hex" --algo bm -j REJECT --reject-with tcp-reset
    add6 -p tcp --dport 53 -m string --hex-string "$hex" --algo bm -j REJECT --reject-with tcp-reset
  done

  echo "$SCRIPT_NAME: 规则已应用（拦截域名: $BLOCK_DOMAINS / 禁端口: $DROP_PORTS）"
}

do_install() {
  install -m 0755 "$0" "$INSTALL_PATH"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=VM outbound guard: SMTP/BT drop + domain block (SNI/DNS)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SCRIPT_NAME" >/dev/null 2>&1
  echo "$SCRIPT_NAME: 已安装（$INSTALL_PATH + $UNIT_PATH，开机自动应用）"
}

do_uninstall() {
  systemctl disable --now "$SCRIPT_NAME" 2>/dev/null
  rm -f "$UNIT_PATH" "$INSTALL_PATH" "$SYSCTL_CONF"
  systemctl daemon-reload 2>/dev/null
  # 清理本脚本添加的规则（按特征精确匹配，不动其他规则）
  iptables -S FORWARD | grep -E -- '--string|--dports .* -j DROP' | sed 's/^-A/-D/; s/"//g' | while read -r r; do iptables "$r" 2>/dev/null; done
  ip6tables -S FORWARD | grep -E -- '--string|--dports .* -j DROP' | sed 's/^-A/-D/; s/"//g' | while read -r r; do ip6tables "$r" 2>/dev/null; done
  # 还原内核开关。注意: 若机器上启用了 PVE 防火墙或其他依赖 bridge-nf 的功能，请保持为 1
  sysctl -w net.bridge.bridge-nf-call-iptables=0  >/dev/null
  sysctl -w net.bridge.bridge-nf-call-arptables=0 >/dev/null
  sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null
  echo "$SCRIPT_NAME: 已卸载并还原"
}

case "${1:-apply}" in
  apply) apply_rules ;;
  install) do_install; apply_rules ;;
  uninstall) do_uninstall ;;
  *) echo "用法: $0 [apply|install|uninstall]"; exit 1 ;;
esac

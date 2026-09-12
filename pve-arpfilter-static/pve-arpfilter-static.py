#!/usr/bin/env python3
# pve-arpfilter-static — PVE 母机 VM 入向 ARP 广播降噪（面板映射文件版）
# 仓库: https://github.com/MOSSDATA-NETWORK/PVE-shell/tree/main/pve-arpfilter-static
#
# 与 pve-arpfilter（被动学习版）的区别:
#   IP 来源不是被动学习，而是面板/运维系统下发的映射文件
#   /etc/pve/arpfilter/<vmid>.<net序号>.ips（每行一个 IPv4，注释用 # 开头）。
#   不开 tcpdump 监听，无学习状态，更轻、行为完全确定。
#   适用: Provisioning 面板能下发 VMID→IP 清单的环境。
#
# 用法:
#   pve-arpfilter-static.py install     完整安装: 装入 /usr/local/sbin + systemd 开机自启
#   pve-arpfilter-static.py uninstall   完全卸载: 停服务、删 nft 表、删文件
#   pve-arpfilter-static.py run         前台运行（调和循环），供调试
#   pve-arpfilter-static.py once        只执行一次调和
#   pve-arpfilter-static.py status      查看映射文件与过滤状态
#
# 原理:
#   上游网关在大扁平二层段里对整段 IP 疯狂 ARP 轮询，广播被送到每台 VM，
#   每台 VM 恒定多收约 17~24KB/s 垃圾流量（计入客户流量）。本工具在
#   nftables bridge 族 forward 钩子上，按 VM 的 tap 口只放行
#   「ARP 询问目标 IP ∈ 该 VM 自己的 IP 集合」的帧，其余 ARP 广播与 STP BPDU 丢弃。
#
#   IP 集合来源（按优先级）:
#     1) /etc/pve/arpfilter/<vmid>.<net>.ips 映射文件（面板下发，权威）
#     2) VM 配置里的 cloud-init ipconfigN（若有）
#   两样都没有的 VM 不装规则（fail-open，噪声照旧但绝不影响通信）。
#
# 原理与验证方法见同目录 README.md

import os
import re
import sys
import time
import fcntl
import signal
import hashlib
import subprocess

SCRIPT_NAME = "pve-arpfilter-static"
INSTALL_PATH = f"/usr/local/sbin/{SCRIPT_NAME}.py"
UNIT_PATH = f"/etc/systemd/system/{SCRIPT_NAME}.service"
MAP_DIR = "/etc/pve/arpfilter"              # 面板下发 <vmid>.<net>.ips 到这里
WHITELIST_FILE = f"/etc/pve/arpfilter.whitelist"   # 存在且非空时只过滤列出的 VMID（灰度用）
LOCK_FILE = "/run/pve-arpfilter.lock"       # 与被动学习版共用同一把锁
NFT_TABLE = "pve-arpfilter"                 # 与被动学习版同名表：两者互斥，见 check_sibling
SIBLING_UNIT = "/etc/systemd/system/pve-arpfilter.service"
GUEST_CONF_DIR = "/etc/pve/qemu-server"
RECONCILE_INTERVAL = 60       # 调和周期（秒）
BPDU_MAC = "01:80:c2:00:00:00"

running = True


def _sigterm(_signum, _frame):
    global running
    running = False


def read_guest_configs():
    """读 /etc/pve/qemu-server/*.conf → {vmid: {nic: {"mac":…, "bridge":…, "ips": […]}}}。
    直接读文件，不走 qm 命令。"""
    guests = {}
    try:
        names = os.listdir(GUEST_CONF_DIR)
    except OSError:
        return guests
    for name in names:
        m = re.fullmatch(r"(\d+)\.conf", name)
        if not m:
            continue
        vmid = m.group(1)
        try:
            with open(os.path.join(GUEST_CONF_DIR, name)) as f:
                text = f.read()
        except OSError:
            continue
        nics = {}
        for line in text.splitlines():
            nm = re.match(r"net(\d+):\s*\S+=([0-9A-Fa-f:]{17})(.*)", line)
            if nm:
                n, mac, rest = nm.group(1), nm.group(2).lower(), nm.group(3)
                br = re.search(r"bridge=(\w+)", rest)
                nics[n] = {"mac": mac, "bridge": br.group(1) if br else None, "ips": []}
                continue
            im = re.match(r"ipconfig(\d+):\s*(.*)", line)
            if im and im.group(1) in nics:
                for ipm in re.finditer(r"(?:^|[,;\s])ip=([\d.]+)", im.group(2)):
                    nics[im.group(1)]["ips"].append(ipm.group(1))
        if nics:
            guests[vmid] = nics
    return guests


def read_mapfiles():
    """读面板映射文件 /etc/pve/arpfilter/<vmid>.<net>.ips → {(vmid, nic): [ip…]}。
    每行一个 IPv4；# 为注释（整行或行尾均可）；空行忽略。
    任何非法行 → 整个文件拒绝应用（fail-open），防面板半成品文件造成部分 IP 集合。"""
    maps = {}
    try:
        names = os.listdir(MAP_DIR)
    except OSError:
        return maps
    for name in names:
        m = re.fullmatch(r"(\d+)\.(\d+)\.ips", name)
        if not m:
            continue
        ips = []
        bad = False
        try:
            with open(os.path.join(MAP_DIR, name)) as f:
                for ln in f:
                    ln = ln.split("#", 1)[0].strip()    # 行尾注释一并去掉
                    if not ln:
                        continue
                    if re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ln):
                        ips.append(ln)
                    else:
                        bad = True                      # 有非法行，整文件作废
                        break
        except OSError:
            continue
        if ips and not bad:
            maps[(m.group(1), m.group(2))] = ips
    return maps


def list_taps():
    """枚举 /sys/class/net/tap*i* → {(vmid, nic): ifname}。tap 存在 = VM 在跑。"""
    taps = {}
    try:
        names = os.listdir("/sys/class/net")
    except OSError:
        return taps
    for name in names:
        m = re.fullmatch(r"tap(\d+)i(\d+)", name)
        if m:
            taps[(m.group(1), m.group(2))] = name
    return taps


def load_whitelist():
    """灰度白名单: 文件存在且非空 → 只过滤列出的 VMID；否则 None（全量）。"""
    try:
        with open(WHITELIST_FILE) as f:
            ids = {ln.strip() for ln in f if ln.strip() and not ln.startswith("#")}
        return ids or None
    except OSError:
        return None


def build_nft(model):
    """按目标模型生成整表规则文本。model: {ifname: (chain名, [ip…])}"""
    lines = [f"destroy table bridge {NFT_TABLE}", f"table bridge {NFT_TABLE} {{"]
    if model:
        lines.append("  map jump4vm {")
        lines.append("    type ifname : verdict")
        elems = ", ".join(f'"{ifn}" : jump {chain}' for ifn, (chain, _) in model.items())
        lines.append(f"    elements = {{ {elems} }}")
        lines.append("  }")
        for ifn, (chain, ips) in model.items():
            lines.append(f"  set {chain}_ips {{")
            lines.append("    type ipv4_addr")
            lines.append(f"    elements = {{ {', '.join(sorted(ips))} }}")
            lines.append("  }")
            lines.append(f"  chain {chain} {{")
            # 白名单内（本 VM 的 IP）直接放行，无标签/802.1Q 标签都覆盖
            lines.append(f"    arp daddr ip @{chain}_ips return")
            lines.append(f"    ether type 8021q arp daddr ip @{chain}_ips return")
            # 细流安全阀：未识别的 ARP 低速放行（≈300B/s，噪声仍降 97%+），
            # 映射文件过期/未更新时合法 ARP 靠重传大概率能到达；
            # 不是绝对保证——噪声打满限速器时单个 ARP 仍可能被丢
            # （bridge 族里裸 arp 后不能直接接 limit，必须带具体字段匹配）
            lines.append("    arp htype 1 arp ptype ip limit rate over 5/second burst 10 packets drop")
            lines.append("    ether type 8021q arp htype 1 arp ptype ip limit rate over 5/second burst 10 packets drop")
            lines.append("  }")
    lines.append("  chain main {")
    lines.append("    type filter hook forward priority 0; policy accept;")
    # STP BPDU 对 VM 永远无用，所有 tap 口统一丢弃
    lines.append(f'    oifname "tap*" ether daddr {BPDU_MAC} drop')
    if model:
        lines.append("    oifname vmap @jump4vm")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def _nft_block(text, kind, name):
    """从 nft list 输出里截取某个命名块的正文（块以制表符缩进、独立行 } 收尾）。"""
    m = re.search(rf"{kind} {re.escape(name)} \{{(.*?)\n\t\}}", text, re.S)
    return m.group(1) if m else None


def live_table_matches(model):
    """逐块严格校验活表内容与目标模型一致，防外部 flush/改写后静默失效。
    覆盖: main 链 hook/policy/priority/BPDU/vmap、map 逐元素、per-VM chain 的
    四条规则全文（含 802.1Q 变体与 rate/burst）、per-set 逐 IP。
    已知边界: 能改 nft 表的是 root，root 大可直接删表（会被检出）；不做 nft -j
    全等比较（句柄/换行格式漂移带来的脆弱性大于收益）。"""
    r = subprocess.run(["nft", "list", "table", "bridge", NFT_TABLE],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return False
    live = r.stdout
    main = _nft_block(live, "chain", "main")
    if main is None or "hook forward priority 0; policy accept" not in main \
            or BPDU_MAC not in main:
        return False
    mmap = _nft_block(live, "map", "jump4vm")
    if bool(model) != (mmap is not None):
        return False
    if not model:
        return True
    if "vmap @jump4vm" not in main:
        return False
    if mmap.count(" : jump ") != len(model):
        return False
    for ifname, (chain, ips) in model.items():
        if f'"{ifname}" : jump {chain}' not in mmap:
            return False
        cblk = _nft_block(live, "chain", chain)
        if cblk is None:
            return False
        clines = {ln.strip() for ln in cblk.splitlines()}   # 逐行精确比对，防子串误配
        for rule in (                       # 四条规则全文逐字核对（含 rate/burst）
                f"arp daddr ip @{chain}_ips return",
                f"ether type 8021q arp daddr ip @{chain}_ips return",
                "arp htype 1 arp ptype ip limit rate over 5/second burst 10 packets drop",
                "ether type 8021q arp htype 1 arp ptype ip limit rate over 5/second burst 10 packets drop"):
            if rule not in clines:
                return False
        sblk = _nft_block(live, "set", f"{chain}_ips")
        if sblk is None:
            return False
        for ip in ips:
            if not re.search(rf"\b{re.escape(ip)}\b", sblk):
                return False
    return True


def reconcile():
    """调和一次: 以当前 tap/配置/映射文件为目标模型，原子替换 nft 表。"""
    guests = read_guest_configs()
    taps = list_taps()
    maps = read_mapfiles()
    whitelist = load_whitelist()

    model = {}
    for (vmid, nic), ifname in sorted(taps.items()):
        cfg = guests.get(vmid, {}).get(nic)
        if not cfg or not cfg.get("mac"):   # 配置里查不到这块网卡 → 不信任，跳过
            continue
        if whitelist is not None and vmid not in whitelist:
            continue
        ips = list(maps.get((vmid, nic), []))   # 1) 面板映射文件（权威）
        ips += [ip for ip in cfg["ips"] if ip not in ips]  # 2) cloud-init ipconfigN
        if not ips:                         # fail-open: 拿不到 IP 不装规则
            continue
        model[ifname] = (f"c_{vmid}_{nic}", ips)

    text = build_nft(model)
    digest = hashlib.sha256(text.encode()).hexdigest()
    # 外部 flush/改动后摘要相同也不能信任 → 活表内容与目标模型不一致就强制重建
    if digest != reconcile._last_digest or not live_table_matches(model):
        with open(LOCK_FILE + ".nft", "w") as f:
            f.write(text)
        subprocess.run(["nft", "-f", LOCK_FILE + ".nft"], check=True)
        reconcile._last_digest = digest
    return len(model)


reconcile._last_digest = None


def acquire_lock():
    """flock: 保证单实例（run/once/两版之间都走这里）。
    与被动学习版共用同一锁文件 → 两版无法同时运行（表名相同，互相覆盖）。"""
    lockfd = open(LOCK_FILE, "w")
    fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return lockfd


def check_sibling():
    """install/run 前硬检测：被动学习版已安装则拒绝，防两版互踩同名 nft 表。"""
    if os.path.exists(SIBLING_UNIT):
        sys.exit(f"检测到被动学习版已安装（{SIBLING_UNIT}）。两版共用同一 nft 表，"
                 "不能同时安装；请先运行 /usr/local/sbin/pve-arpfilter.py uninstall")


def run_daemon():
    check_sibling()
    lockfd = acquire_lock()                 # noqa: F841 持有至进程结束

    signal.signal(signal.SIGTERM, _sigterm)
    signal.signal(signal.SIGINT, _sigterm)

    print(f"{SCRIPT_NAME}: daemon started", flush=True)
    while running:
        try:
            n = reconcile()
            print(f"{SCRIPT_NAME}: reconciled, {n} NICs filtered", flush=True)
        except Exception as e:
            print(f"{SCRIPT_NAME}: reconcile failed: {e}", flush=True)
        for _ in range(RECONCILE_INTERVAL):
            if not running:
                break
            time.sleep(1)
    print(f"{SCRIPT_NAME}: stopped", flush=True)


def status():
    maps = read_mapfiles()
    print(f"映射文件: {len(maps)} 个 NIC，IP 条目: {sum(len(v) for v in maps.values())}")
    r = subprocess.run(["nft", "list", "table", "bridge", NFT_TABLE],
                       capture_output=True, text=True)
    if r.returncode == 0:
        chains = len(re.findall(r"chain c_\d+_\d+", r.stdout))
        print(f"nft 表中 per-VM 链数: {chains}")
    else:
        print("nft 表不存在（未应用）")
    w = load_whitelist()
    print(f"灰度白名单: {'无（全量）' if w is None else f'{len(w)} 台 VM'}")


def install():
    check_sibling()
    os.makedirs("/usr/local/sbin", exist_ok=True)
    if os.path.realpath(__file__) != os.path.realpath(INSTALL_PATH):
        subprocess.run(["cp", os.path.abspath(__file__), INSTALL_PATH], check=True)
    subprocess.run(["chmod", "755", INSTALL_PATH], check=True)
    os.makedirs(MAP_DIR, exist_ok=True)     # 面板把 <vmid>.<net>.ips 放到这里
    with open(UNIT_PATH, "w") as f:
        f.write(f"""[Unit]
Description=pve-arpfilter-static - VM inbound ARP broadcast noise filter (mapfile edition)
After=network-online.target pve-guests.service
Wants=network-online.target

[Service]
Type=simple
ExecStart={INSTALL_PATH} run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
""")
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "--now", f"{SCRIPT_NAME}.service"], check=True)
    print(f"已安装并启动。映射文件目录: {MAP_DIR}/<vmid>.<net>.ips；状态: {INSTALL_PATH} status")


def uninstall():
    # 顺序: 先停服务（daemon 才释放 flock）→ 持锁（整个卸载期间）→ 删表并确认 → 最后才删文件
    r = subprocess.run(["systemctl", "disable", "--now", f"{SCRIPT_NAME}.service"])
    if r.returncode != 0:
        sys.exit("停止服务失败，中止卸载（请手动 systemctl stop 后重试）")
    lockfd = acquire_lock()                 # noqa: F841 必须持有引用，否则 fd 被回收锁即释放
    subprocess.run(["nft", "destroy", "table", "bridge", NFT_TABLE],
                   capture_output=True)
    # 表真的没了才继续；删不掉（残留过滤规则但已无人看护）必须中止，且文件原样保留
    if subprocess.run(["nft", "list", "table", "bridge", NFT_TABLE],
                      capture_output=True).returncode == 0:
        sys.exit(f"nft 表 {NFT_TABLE} 删除失败，中止卸载（服务文件均未动，请手工 nft list table bridge {NFT_TABLE} 排查）")
    for p in (UNIT_PATH, INSTALL_PATH):
        try:
            os.remove(p)
        except OSError:
            pass
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    print("已卸载: 服务停止，nft 表删除，VM 网络恢复原样（映射文件目录未动）")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        run_daemon()
    elif cmd == "once":
        lockfd = acquire_lock()             # noqa: F841 与 daemon 互斥，防止并发覆盖
        n = reconcile()
        print(f"已调和，{n} 个 NIC 装规则")
    elif cmd == "status":
        status()
    elif cmd == "install":
        install()
    elif cmd == "uninstall":
        uninstall()
    else:
        sys.exit(f"未知命令 {cmd}（install/uninstall/run/once/status）")


if __name__ == "__main__":
    main()

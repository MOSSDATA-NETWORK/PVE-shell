#!/usr/bin/env python3
# pve-arpfilter — PVE 母机 VM 入向 ARP 广播降噪
# 仓库: https://github.com/MOSSDATA-NETWORK/PVE-shell/tree/main/pve-arpfilter
#
# 用法:
#   pve-arpfilter.py install     完整安装: 装入 /usr/local/sbin + systemd 开机自启 + 立即启动
#   pve-arpfilter.py uninstall   完全卸载: 停服务、删 nft 表、删文件（VM 网络立即恢复原样）
#   pve-arpfilter.py run         前台运行守护进程（学习 + 调和），供调试
#   pve-arpfilter.py once        只执行一次调和（不重载规则则无变化）
#   pve-arpfilter.py status      查看学习与过滤状态
#
# 原理:
#   上游网关在大扁平二层段里对整段 IP 疯狂 ARP 轮询，广播被送到每台 VM，
#   每台 VM 恒定多收约 17~24KB/s 垃圾流量（计入客户流量）。本工具在
#   nftables bridge 族 forward 钩子上，按 VM 的 tap 口只放行
#   「ARP 询问目标 IP ∈ 该 VM 自己的 IP 集合」的帧，其余 ARP 广播与 STP BPDU 丢弃。
#
#   VM 的 IP 集合来源（无需面板配合）:
#     1) VM 配置里的 cloud-init ipconfigN（静态，最高优先）
#     2) 被动学习: 在主网桥上监听 ARP，从 VM 自己发出的 ARP 中提取 源MAC→源IP
#        （配了 IPv4 的 VM 必然发 ARP；条目 4 小时 TTL，观测到即刷新）
#   两样都没有的 VM 不装规则（fail-open，噪声照旧但绝不影响通信）。
#
# 原理与验证方法见同目录 README.md

import os
import re
import sys
import time
import json
import fcntl
import signal
import hashlib
import subprocess
import threading

SCRIPT_NAME = "pve-arpfilter"
INSTALL_PATH = f"/usr/local/sbin/{SCRIPT_NAME}.py"
UNIT_PATH = f"/etc/systemd/system/{SCRIPT_NAME}.service"
STATE_DIR = f"/var/lib/{SCRIPT_NAME}"
STATE_FILE = f"{STATE_DIR}/state.json"
WHITELIST_FILE = f"/etc/pve/arpfilter.whitelist"   # 存在且非空时，只有列出的 VMID 装规则（灰度用）
LOCK_FILE = f"/run/{SCRIPT_NAME}.lock"
NFT_TABLE = "pve-arpfilter"
GUEST_CONF_DIR = "/etc/pve/qemu-server"
LEARN_TTL = 4 * 3600          # 被动学习条目有效期（秒），观测到即刷新
RECONCILE_INTERVAL = 60       # 调和周期（秒）
BPDU_MAC = "01:80:c2:00:00:00"

# tcpdump -e 行解析: 源 MAC 在第 2 字段; 无标签/带 VLAN 标签的 ARP 都携带发送方 IP
# 无标签: "... ethertype ARP (0x0806), length 60: Request who-has A tell B, length 46"
# 带标签: "... ethertype 802.1Q (0x8100), length 64: vlan N, p 0, ethertype ARP (0x0806), Request who-has A tell B, ..."
# 应答:   "... ethertype ARP (0x0806), length 46: Reply A is-at M, length 46"
RE_ARP = re.compile(
    r"^\S+ ([0-9a-f:]{17}) > [0-9a-f:]{17},.*ARP \(0x0806\), "
    r"(?:length \d+: )?(?:Request who-has [\d.]+ tell ([\d.]+)|Reply ([\d.]+) is-at)"
)

running = True


def _sigterm(_signum, _frame):
    global running
    running = False


def read_guest_configs():
    """读 /etc/pve/qemu-server/*.conf → {vmid: {nic: {"mac":…, "bridge":…, "ips": […]}}}。
    直接读文件，不走 qm 命令（250 台逐个 qm config 每分钟一次太重）。"""
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


def load_state():
    try:
        with open(STATE_FILE) as f:
            st = json.load(f)
        # learned: {mac: {ip: expiry_epoch}}
        return {"learned": st.get("learned", {})}
    except (OSError, ValueError):
        return {"learned": {}}


def save_state(state, lock=None):
    """写状态文件。学习线程在并发写入，先在同一把锁下取快照再落盘。"""
    if lock is not None:
        with lock:
            snapshot = {"learned": {m: dict(ips) for m, ips in state["learned"].items()}}
    else:
        snapshot = state
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snapshot, f)
    os.replace(tmp, STATE_FILE)


class ArpLearner(threading.Thread):
    """每个主网桥一个 tcpdump 子进程，只抓 ARP（内核 BPF 过滤）。
    从 VM 发出的 ARP 中提取 源MAC→源IP，写入共享 learned 表。"""

    def __init__(self, bridge, state, lock):
        super().__init__(daemon=True)
        self.bridge = bridge
        self.state = state
        self.lock = lock
        self.proc = None
        self.dead = False

    def stop(self):
        """标记退役并停掉 tcpdump 回收，避免僵尸/泄漏。"""
        self.dead = True
        p = self.proc
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    def run(self):
        while running and not self.dead:
            self.proc = subprocess.Popen(
                ["tcpdump", "-i", self.bridge, "-nne", "-l", "arp"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace",
            )
            if self.dead:                   # stop() 与 Popen 的竞态收口
                self.stop()
                break
            try:
                for line in self.proc.stdout:
                    if not running or self.dead:
                        break
                    m = RE_ARP.match(line.strip())
                    if not m:
                        continue
                    mac = m.group(1).lower()
                    ip = m.group(2) or m.group(3)
                    if not ip or ip == "0.0.0.0":   # RFC5227 ARP Probe 源 IP 为 0，不可学习
                        continue
                    with self.lock:
                        self.state["learned"].setdefault(mac, {})[ip] = time.time() + LEARN_TTL
            finally:
                self.stop()
            if running and not self.dead:   # tcpdump 异常退出，5 秒后重连
                time.sleep(5)


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
            # 换 IP/学习失效时合法 ARP 靠重传大概率能到达（网关会多次重试）；
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
    两条 return（含 802.1Q）与两条 limit、per-set 逐 IP。
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


def reconcile(state, lock):
    """调和一次: 以当前 tap/配置/学习结果为目标模型，原子替换 nft 表。"""
    guests = read_guest_configs()
    taps = list_taps()
    whitelist = load_whitelist()
    now = time.time()

    # 清理过期学习条目
    with lock:
        learned = state["learned"]
        for mac in list(learned):
            learned[mac] = {ip: exp for ip, exp in learned[mac].items() if exp > now}
            if not learned[mac]:
                del learned[mac]

    model = {}
    for (vmid, nic), ifname in sorted(taps.items()):
        cfg = guests.get(vmid, {}).get(nic)
        if not cfg or not cfg.get("mac"):   # 配置里查不到这块网卡 → 不信任，跳过
            continue
        if whitelist is not None and vmid not in whitelist:
            continue
        ips = list(cfg["ips"])              # 1) 静态 ipconfigN（最高优先）
        with lock:                          # 2) 被动学习（只认配置里登记的 MAC，防伪造污染）
            ips += [ip for ip in state["learned"].get(cfg["mac"], {}) if ip not in ips]
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
    save_state(state, lock)                 # 学习条目 TTL 每次调和都落盘
    return len(model)


reconcile._last_digest = None


def acquire_lock():
    """flock: 保证单实例（run/once 都走这里）。"""
    lockfd = open(LOCK_FILE, "w")
    fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return lockfd


def run_daemon():
    os.makedirs(STATE_DIR, exist_ok=True)
    lockfd = acquire_lock()

    signal.signal(signal.SIGTERM, _sigterm)
    signal.signal(signal.SIGINT, _sigterm)

    state = load_state()
    lock = threading.Lock()
    learners = {}

    print(f"{SCRIPT_NAME}: daemon started", flush=True)
    while running:
        # 监听桥集合 = 当前所有 VM 配置里出现的网桥
        bridges = {c["bridge"] for nics in read_guest_configs().values()
                   for c in nics.values() if c.get("bridge")}
        for br in bridges - set(learners):  # 新出现的网桥：开监听
            t = ArpLearner(br, state, lock)
            t.start()
            learners[br] = t
            print(f"{SCRIPT_NAME}: learning ARP on {br}", flush=True)
        for br in set(learners) - bridges:  # 退役的网桥：停监听并回收
            learners.pop(br).stop()
            print(f"{SCRIPT_NAME}: stopped learning on {br}", flush=True)
        try:
            n = reconcile(state, lock)
            print(f"{SCRIPT_NAME}: reconciled, {n} NICs filtered", flush=True)
        except Exception as e:
            print(f"{SCRIPT_NAME}: reconcile failed: {e}", flush=True)
        for _ in range(RECONCILE_INTERVAL):
            if not running:
                break
            time.sleep(1)
    for t in learners.values():             # 退出前回收所有 tcpdump
        t.stop()
    for t in learners.values():
        t.join(timeout=5)
    save_state(state, lock)
    print(f"{SCRIPT_NAME}: stopped", flush=True)


def status():
    state = load_state()
    now = time.time()
    alive = {m: ips for m, ips in state["learned"].items()
             if any(e > now for e in ips.values())}
    print(f"已学习 MAC 数: {len(alive)}，IP 条目: {sum(len(v) for v in alive.values())}")
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
    os.makedirs("/usr/local/sbin", exist_ok=True)
    if os.path.realpath(__file__) != os.path.realpath(INSTALL_PATH):
        subprocess.run(["cp", os.path.abspath(__file__), INSTALL_PATH], check=True)
    subprocess.run(["chmod", "755", INSTALL_PATH], check=True)
    with open(UNIT_PATH, "w") as f:
        f.write(f"""[Unit]
Description=pve-arpfilter - VM inbound ARP broadcast noise filter
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
    # 清理早期试点残留（如有）
    subprocess.run(["nft", "destroy", "table", "bridge", "arpflt481"],
                   capture_output=True)
    print(f"已安装并启动。状态查看: {INSTALL_PATH} status")


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
    import shutil
    shutil.rmtree(STATE_DIR, ignore_errors=True)    # 清掉学习状态
    print("已卸载: 服务停止，nft 表与学习状态删除，VM 网络恢复原样")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        run_daemon()
    elif cmd == "once":
        lockfd = acquire_lock()             # noqa: F841 与 daemon 互斥，防止并发覆盖
        state = load_state()
        n = reconcile(state, threading.Lock())
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

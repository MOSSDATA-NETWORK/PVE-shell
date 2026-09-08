#!/bin/bash
#
# PVE 宿主机自适应优化脚本
# 根据 CPU 核心数和内存大小自动调整内核参数
# 适用：Proxmox VE 7.x / 8.x
#
# 用法：
#   bash pve-optimize.sh                    # 执行优化（自动检测区域）
#   bash pve-optimize.sh --dry-run          # 只打印不写入
#   bash pve-optimize.sh --restore          # 回滚到上次备份
#   bash pve-optimize.sh --region intl      # 海外服务器（国际 NTP，北京时间）
#   bash pve-optimize.sh --region hk        # 香港服务器（本地 NTP，北京时间）
#   bash pve-optimize.sh --region cn        # 中国大陆服务器（国内 NTP，北京时间）
#

set -euo pipefail

# ============================================================
# 颜色与日志
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $*"; }
error() { echo -e "${RED}[✘]${NC} $*"; }
title() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ============================================================
# 全局变量
# ============================================================
DRY_RUN=false
REGION="auto"
BACKUP_DIR="/root/pve-optimize-backup/$(date +%Y%m%d_%H%M%S)"

# ============================================================
# 环境检测
# ============================================================
check_env() {
    title "环境检测"

    if [[ $EUID -ne 0 ]]; then
        error "请以 root 权限运行此脚本"
        exit 1
    fi

    if ! command -v pveversion &>/dev/null; then
        warn "未检测到 pveversion，当前系统可能不是 PVE"
        read -rp "是否继续？(y/N): " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 1
    else
        local pve_ver
        pve_ver=$(pveversion --verbose 2>/dev/null | head -1 || echo "unknown")
        info "PVE 版本: $pve_ver"
    fi
}

# ============================================================
# 硬件检测与分档
# ============================================================
detect_hardware() {
    title "硬件检测"

    CPU_CORES=$(nproc)
    MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    MEM_MB=$(( MEM_KB / 1024 ))

    # 分档：small / medium / large
    if [[ $CPU_CORES -le 4 && $MEM_GB -le 8 ]]; then
        TIER="small"
        TIER_NAME="小型 (≤4核/≤8G)"
    elif [[ $CPU_CORES -le 16 && $MEM_GB -le 64 ]]; then
        TIER="medium"
        TIER_NAME="中型 (≤16核/≤64G)"
    else
        TIER="large"
        TIER_NAME="大型 (>16核/>64G)"
    fi

    info "CPU 核心数: ${CPU_CORES}"
    info "内存大小:   ${MEM_GB}G (${MEM_MB}MB)"
    info "配置档位:   ${TIER_NAME}"
}

# ============================================================
# 根据档位计算参数值
# ============================================================
calc_params() {
    title "参数计算"

    case "$TIER" in
        small)
            P_FILE_MAX=524288
            P_NOFILE=524288
            P_PID_MAX=4194304
            P_THREADS_MAX=262144
            P_CONNTRACK=524288
            P_CONNTRACK_BUCKETS=131072
            P_SOMAXCONN=8192
            P_SYN_BACKLOG=8192
            P_NETDEV_BACKLOG=8192
            P_TCP_RMEM_MAX=67108864        # 64M
            P_TCP_WMEM_MAX=67108864        # 64M
            P_RMEM_MAX=67108864
            P_WMEM_MAX=67108864
            P_TCP_MEM_LOW=131072
            P_TCP_MEM_PRESSURE=524288
            P_TCP_MEM_HIGH=2097152
            P_DIRTY_BYTES=67108864         # 64M
            P_DIRTY_BG_BYTES=33554432      # 32M
            P_MIN_FREE_KBYTES=$(( MEM_KB * 1 / 100 ))
            P_MAX_MAP_COUNT=262144
            ;;
        medium)
            P_FILE_MAX=1048576
            P_NOFILE=1048576
            P_PID_MAX=8388608
            P_THREADS_MAX=524288
            P_CONNTRACK=1048576
            P_CONNTRACK_BUCKETS=262144
            P_SOMAXCONN=32768
            P_SYN_BACKLOG=32768
            P_NETDEV_BACKLOG=32768
            P_TCP_RMEM_MAX=134217728       # 128M
            P_TCP_WMEM_MAX=134217728       # 128M
            P_RMEM_MAX=134217728
            P_WMEM_MAX=134217728
            P_TCP_MEM_LOW=262144
            P_TCP_MEM_PRESSURE=1048576
            P_TCP_MEM_HIGH=4194304
            P_DIRTY_BYTES=134217728        # 128M
            P_DIRTY_BG_BYTES=67108864      # 64M
            P_MIN_FREE_KBYTES=$(( MEM_KB * 3 / 200 ))
            P_MAX_MAP_COUNT=524288
            ;;
        large)
            P_FILE_MAX=2097152
            P_NOFILE=2097152
            P_PID_MAX=16777216
            P_THREADS_MAX=1048576
            P_CONNTRACK=2097152
            P_CONNTRACK_BUCKETS=524288
            P_SOMAXCONN=65536
            P_SYN_BACKLOG=65536
            P_NETDEV_BACKLOG=65536
            P_TCP_RMEM_MAX=268435456       # 256M
            P_TCP_WMEM_MAX=268435456       # 256M
            P_RMEM_MAX=268435456
            P_WMEM_MAX=268435456
            P_TCP_MEM_LOW=524288
            P_TCP_MEM_PRESSURE=2097152
            P_TCP_MEM_HIGH=8388608
            P_DIRTY_BYTES=268435456        # 256M
            P_DIRTY_BG_BYTES=134217728     # 128M
            P_MIN_FREE_KBYTES=$(( MEM_KB * 2 / 100 ))
            P_MAX_MAP_COUNT=1048576
            ;;
    esac

    # 防止 min_free_kbytes 太小
    [[ $P_MIN_FREE_KBYTES -lt 65536 ]] && P_MIN_FREE_KBYTES=65536

    info "file-max/nofile:  $P_FILE_MAX"
    info "conntrack_max:    $P_CONNTRACK"
    info "tcp_rmem/wmem max: $(( P_TCP_RMEM_MAX / 1048576 ))M"
    info "somaxconn:        $P_SOMAXCONN"
    info "min_free_kbytes:  $P_MIN_FREE_KBYTES"
}

# ============================================================
# 备份
# ============================================================
backup_configs() {
    title "备份现有配置"

    mkdir -p "$BACKUP_DIR"

    local files=(
        /etc/sysctl.conf
        /etc/security/limits.conf
        /etc/systemd/system.conf
        /etc/systemd/journald.conf
        /etc/profile
        /etc/default/cpufrequtils
        /etc/modprobe.d/zfs-arc.conf
        /etc/udev/rules.d/60-io-scheduler.rules
    )

    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak"
            info "已备份: $f"
        fi
    done

    # 备份 /etc/sysctl.d/ 下所有文件（只备份不删除）
    if [[ -d /etc/sysctl.d ]]; then
        mkdir -p "$BACKUP_DIR/sysctl.d"
        cp -a /etc/sysctl.d/* "$BACKUP_DIR/sysctl.d/" 2>/dev/null || true
        info "已备份: /etc/sysctl.d/"
    fi

    info "备份目录: $BACKUP_DIR"
}

# ============================================================
# 应用优化：ulimit
# ============================================================
apply_ulimit() {
    title "ulimit / 文件描述符调优"

    local limits_content
    limits_content="root     soft   nofile    ${P_NOFILE}
root     hard   nofile    ${P_NOFILE}
root     soft   nproc     ${P_NOFILE}
root     hard   nproc     ${P_NOFILE}
root     soft   core      unlimited
root     hard   core      unlimited
root     hard   memlock   unlimited
root     soft   memlock   unlimited

*     soft   nofile    ${P_NOFILE}
*     hard   nofile    ${P_NOFILE}
*     soft   nproc     ${P_NOFILE}
*     hard   nproc     ${P_NOFILE}
*     soft   core      unlimited
*     hard   core      unlimited
*     hard   memlock   unlimited
*     soft   memlock   unlimited
"

    if $DRY_RUN; then
        info "[dry-run] 将写入 /etc/security/limits.conf"
    else
        echo "$limits_content" > /etc/security/limits.conf
        info "已写入 /etc/security/limits.conf"
    fi

    # /etc/profile 中追加 ulimit
    if $DRY_RUN; then
        info "[dry-run] 将设置 ulimit -SHn ${P_NOFILE}"
    else
        sed -i '/ulimit -SHn/d' /etc/profile
        echo "ulimit -SHn ${P_NOFILE}" >> /etc/profile
        info "已设置 ulimit -SHn ${P_NOFILE}"
    fi

    # PAM
    if [[ -f /etc/pam.d/common-session ]]; then
        if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
            if $DRY_RUN; then
                info "[dry-run] 将追加 pam_limits.so"
            else
                echo "session required pam_limits.so" >> /etc/pam.d/common-session
                info "已追加 pam_limits.so 到 common-session"
            fi
        else
            info "pam_limits.so 已存在，跳过"
        fi
    fi
}

# ============================================================
# 应用优化：systemd limits
# ============================================================
apply_systemd_limits() {
    title "systemd DefaultLimit 调优"

    local sysconf_content="[Manager]
DefaultLimitCORE=infinity
DefaultLimitNOFILE=${P_NOFILE}
DefaultLimitNPROC=${P_NOFILE}
DefaultLimitMEMLOCK=infinity
"

    if $DRY_RUN; then
        info "[dry-run] 将写入 /etc/systemd/system.conf"
    else
        echo "$sysconf_content" > /etc/systemd/system.conf
        systemctl daemon-reload
        info "已写入 /etc/systemd/system.conf 并 daemon-reload"
    fi
}

# ============================================================
# 应用优化：journald
# ============================================================
apply_journald() {
    title "journald 日志限制"

    local journal_content="[Journal]
SystemMaxUse=300M
RuntimeMaxUse=100M
"

    if $DRY_RUN; then
        info "[dry-run] 将写入 /etc/systemd/journald.conf"
    else
        echo "$journal_content" > /etc/systemd/journald.conf
        systemctl restart systemd-journald
        info "已限制 journald 日志为 300M"
    fi
}

# ============================================================
# 应用优化：sysctl（核心）
# ============================================================
apply_sysctl() {
    title "sysctl 内核参数调优"

    local sysctl_content
    sysctl_content=$(cat <<EOF
# ============================================================
# PVE 宿主机优化 — 自动生成 ($(date +%Y-%m-%d))
# 硬件: ${CPU_CORES}核 / ${MEM_GB}G RAM / 档位: ${TIER_NAME}
# ============================================================

# --- 基础限制 ---
kernel.pid_max=${P_PID_MAX}
kernel.threads-max=${P_THREADS_MAX}
fs.file-max=${P_FILE_MAX}
fs.inotify.max_user_instances=131072
vm.max_map_count=${P_MAX_MAP_COUNT}

# --- 内存管理 ---
vm.swappiness=1
vm.dirty_background_bytes=${P_DIRTY_BG_BYTES}
vm.dirty_bytes=${P_DIRTY_BYTES}
vm.dirty_ratio=0
vm.dirty_background_ratio=0
vm.min_free_kbytes=${P_MIN_FREE_KBYTES}

# --- 连接追踪（PVE 防火墙/NAT 依赖） ---
net.netfilter.nf_conntrack_max=${P_CONNTRACK}
net.netfilter.nf_conntrack_buckets=${P_CONNTRACK_BUCKETS}

# --- TCP 基础 ---
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_max_tw_buckets=${P_CONNTRACK}
net.ipv4.tcp_abort_on_overflow=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_autocorking=0
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0

# --- TCP 队列与 backlog ---
net.core.somaxconn=${P_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog=${P_SYN_BACKLOG}
net.core.netdev_max_backlog=${P_NETDEV_BACKLOG}

# --- TCP 缓冲区 ---
net.ipv4.tcp_rmem=4096 87380 ${P_TCP_RMEM_MAX}
net.ipv4.tcp_wmem=4096 87380 ${P_TCP_WMEM_MAX}
net.core.rmem_default=262144
net.core.rmem_max=${P_RMEM_MAX}
net.core.wmem_default=262144
net.core.wmem_max=${P_WMEM_MAX}
net.ipv4.tcp_mem=${P_TCP_MEM_LOW} ${P_TCP_MEM_PRESSURE} ${P_TCP_MEM_HIGH}
net.ipv4.udp_mem=${P_TCP_MEM_LOW} ${P_TCP_MEM_PRESSURE} ${P_TCP_MEM_HIGH}
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1

# --- 拥塞控制 ---
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq

# --- 端口范围 ---
net.ipv4.ip_local_port_range=1024 65535

# --- ARP 表 ---
net.ipv4.neigh.default.gc_thresh1=1024
net.ipv4.neigh.default.gc_thresh2=4096
net.ipv4.neigh.default.gc_thresh3=8192
net.ipv6.neigh.default.gc_thresh1=1024
net.ipv6.neigh.default.gc_thresh2=4096
net.ipv6.neigh.default.gc_thresh3=8192

# --- 路由转发（PVE VM 桥接需要） ---
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2

# --- 安全加固 ---
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0
EOF
)

    if $DRY_RUN; then
        info "[dry-run] 将写入 /etc/sysctl.conf"
        echo ""
        echo "$sysctl_content"
        echo ""
    else
        echo "$sysctl_content" > /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf > /dev/null 2>&1
        info "已写入 /etc/sysctl.conf 并生效"
    fi
}

# ============================================================
# 时区与时间同步
# ============================================================

# 根据 region 返回 chrony 配置内容
get_chrony_conf() {
    local region="$1"
    case "$region" in
        cn)
            cat <<'EOF'
# PVE 时间同步 — 中国大陆（国内源，低延迟）
server ntp.aliyun.com iburst
server time.cloud.aliyuncs.com iburst
server ntp.tencent.com iburst
server ntp.ntsc.ac.cn iburst
server edu.ntp.org.cn iburst
EOF
            ;;
        hk)
            cat <<'EOF'
# PVE 时间同步 — 香港（本地+国际源，避免绕回大陆）
server time.hko.hk iburst
server clock.hkg10.hkcix.com.hk iburst
server time.google.com iburst
server time.cloudflare.com iburst
server pool.ntp.org iburst
EOF
            ;;
        intl)
            cat <<'EOF'
# PVE 时间同步 — 海外（国际源，低延迟）
server time.google.com iburst
server time.cloudflare.com iburst
server time.apple.com iburst
server time.windows.com iburst
server pool.ntp.org iburst
EOF
            ;;
    esac

    # 通用尾部配置
    cat <<'EOF'

# 偏差大于1秒时，前3次同步直接跳变校正
makestep 1.0 3

# 同步硬件时钟
rtcsync

# 日志目录
logdir /var/log/chrony
EOF
}

# 自动检测区域：通过 timezone 推断
detect_region() {
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")

    case "$tz" in
        Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Kashgar|Asia/Urumqi)
            echo "cn" ;;
        Asia/Hong_Kong|Asia/Macau)
            echo "hk" ;;
        Asia/Tokyo|Asia/Seoul|Asia/Singapore|Asia/Kuala_Lumpur|Asia/Bangkok|Asia/Taipei|Asia/Dubai|Asia/Kolkata)
            echo "intl" ;;
        Europe/*|America/*|Australia/*|Pacific/*|Africa/*)
            echo "intl" ;;
        "")
            echo "intl" ;;
        *)
            # 中国时区但不在上面列表的默认 cn
            if [[ "$tz" == Asia/* ]] && date +%Z 2>/dev/null | grep -qiE "^(CST|CCT)"; then
                echo "cn"
            else
                echo "intl"
            fi
            ;;
    esac
}

apply_timezone() {
    title "时区与时间同步"

    # 解析区域
    if [[ "$REGION" == "auto" ]]; then
        REGION=$(detect_region)
        info "自动检测区域: $REGION"
    fi

    # 时区统一用北京时间（Asia/Shanghai = UTC+8）
    if $DRY_RUN; then
        info "[dry-run] 将设置时区为 Asia/Shanghai（北京时间）"
    else
        timedatectl set-timezone Asia/Shanghai
        info "时区已设置为 Asia/Shanghai（北京时间）"
    fi

    # 配置 chrony
    if command -v chronyd &>/dev/null || dpkg -l chrony &>/dev/null 2>&1; then
        local chrony_conf="/etc/chrony/chrony.conf"
        if $DRY_RUN; then
            info "[dry-run] 将配置 chrony（区域: ${REGION}）"
            echo ""
            get_chrony_conf "$REGION"
            echo ""
        else
            [[ -f "$chrony_conf" ]] && cp -a "$chrony_conf" "${BACKUP_DIR}/chrony.conf.bak" 2>/dev/null || true
            get_chrony_conf "$REGION" > "$chrony_conf"
            systemctl enable chrony 2>/dev/null || systemctl enable chronyd 2>/dev/null || true
            systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true
            info "已配置 chrony（区域: ${REGION}）并重启服务"
        fi
    else
        warn "未检测到 chrony，跳过 NTP 配置"
        if ! $DRY_RUN; then
            info "尝试安装 chrony..."
            apt-get install -y chrony >/dev/null 2>&1 && info "chrony 安装成功" || warn "chrony 安装失败，请手动安装"
        fi
    fi

    # 验证同步状态
    if ! $DRY_RUN; then
        if command -v chronyc &>/dev/null; then
            info "当前同步状态:"
            chronyc sources 2>/dev/null | head -8 || true
        fi
    fi
}

# ============================================================
# 确认 BBR 可用
# ============================================================
ensure_bbr() {
    title "BBR 拥塞控制检查"

    if modprobe tcp_bbr 2>/dev/null; then
        info "tcp_bbr 模块已加载"
    else
        warn "tcp_bbr 模块不可用，将使用默认拥塞控制算法"
        if ! $DRY_RUN; then
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
        fi
    fi
}

# ============================================================
# THP（透明大页）优化
# ============================================================
apply_thp() {
    title "THP（透明大页）优化"

    local thp_path="/sys/kernel/mm/transparent_hugepage"

    if [[ ! -d "$thp_path" ]]; then
        info "内核不支持 THP，跳过"
        return
    fi

    local current_enabled
    current_enabled=$(cat "$thp_path/enabled" 2>/dev/null || echo "")

    if $DRY_RUN; then
        info "[dry-run] THP 当前: $current_enabled"
        info "[dry-run] 将设为 madvise（避免 khugepaged 后台合并导致 VM 延迟毛刺）"
    else
        # 设为 madvise：只有显式请求的应用才用大页，VM 不受影响
        echo madvise > "$thp_path/enabled"
        # khugepaged 设为按需扫描，不主动合并
        if [[ -d "$thp_path/khugepaged" ]]; then
            echo 0 > "$thp_path/khugepaged/defrag"
            echo 0 > "$thp_path/khugepaged/scan_sleep_millisecs"
            echo 1 > "$thp_path/khugepaged/pages_to_scan" 2>/dev/null || true
        fi

        # 持久化：通过 systemd tmpfiles 或 rc.local
        cat > /etc/tmpfiles.d/thp.conf <<'TMPF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag - - - - 0
TMPF

        info "THP 已设为 madvise，khugepaged 合并已关闭"
    fi
}

# ============================================================
# CPU 调频策略
# ============================================================
apply_cpu_governor() {
    title "CPU 调频策略"

    if ! command -v cpupower &>/dev/null && ! command -v cpufreq-set &>/dev/null; then
        # 没有 cpupower 工具，用 sysfs 直接写
        local governors
        governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")

        if [[ -z "$governors" ]]; then
            info "CPU 不支持调频或为虚拟化环境，跳过"
            return
        fi

        if $DRY_RUN; then
            info "[dry-run] CPU 调频当前: $governors"
            info "[dry-run] 将设为 performance（固定最高频率，消除 VM 因降频卡顿）"
        else
            for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                echo performance > "$gov" 2>/dev/null || true
            done

            # 持久化
            if ! dpkg -l cpufrequtils &>/dev/null 2>&1; then
                apt-get install -y cpufrequtils >/dev/null 2>&1 || true
            fi
            if [[ -f /etc/default/cpufrequtils ]]; then
                sed -i 's/^GOVERNOR=.*/GOVERNOR="performance"/' /etc/default/cpufrequtils
            else
                echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
            fi

            info "CPU 调频已设为 performance"
        fi
    else
        local current
        current=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")

        if $DRY_RUN; then
            info "[dry-run] CPU 调频当前: $current"
            info "[dry-run] 将设为 performance"
        else
            if command -v cpupower &>/dev/null; then
                cpupower frequency-set -g performance >/dev/null 2>&1
            elif command -v cpufreq-set &>/dev/null; then
                cpufreq-set -g performance -r >/dev/null 2>&1
            fi
            info "CPU 调频已设为 performance（当前: $current）"
        fi
    fi
}

# ============================================================
# KSM（内核同页合并）调优
# ============================================================
apply_ksm() {
    title "KSM（内存同页合并）调优"

    local ksm_path="/sys/kernel/mm/ksm"

    if [[ ! -d "$ksm_path" ]]; then
        info "内核未启用 KSM，跳过"
        return
    fi

    local ksm_run
    ksm_run=$(cat "$ksm_path/run" 2>/dev/null || echo "0")

    # 根据内存大小调整扫描参数
    local pages_to_scan sleep_ms
    case "$TIER" in
        small)
            pages_to_scan=64
            sleep_ms=20
            ;;
        medium)
            pages_to_scan=128
            sleep_ms=10
            ;;
        large)
            pages_to_scan=200
            sleep_ms=5
            ;;
    esac

    if $DRY_RUN; then
        info "[dry-run] KSM 当前状态: run=$ksm_run"
        info "[dry-run] 将启用 KSM 并设置扫描参数:"
        info "[dry-run]   pages_to_scan=$pages_to_scan, sleep_ms=${sleep_ms}ms"
    else
        # 先设参数再启用，避免启用后用默认值狂扫
        echo "$pages_to_scan" > "$ksm_path/pages_to_scan" 2>/dev/null || true
        echo "$sleep_ms" > "$ksm_path/sleep_millisecs" 2>/dev/null || true
        echo 1 > "$ksm_path/run"

        # 持久化
        cat > /etc/tmpfiles.d/ksm.conf <<TMPF
w /sys/kernel/mm/ksm/pages_to_scan - - - - ${pages_to_scan}
w /sys/kernel/mm/ksm/sleep_millisecs - - - - ${sleep_ms}
w /sys/kernel/mm/ksm/run - - - - 1
TMPF

        info "KSM 已启用（pages_to_scan=$pages_to_scan, sleep=${sleep_ms}ms）"
    fi
}

# ============================================================
# 磁盘 IO 调度器
# ============================================================
apply_io_scheduler() {
    title "磁盘 IO 调度器"

    local found_disk=false

    for dev in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
        [[ -d "$dev" ]] || continue
        local name
        name=$(basename "$dev")
        local sched_file="$dev/queue/scheduler"
        [[ -f "$sched_file" ]] || continue

        local current
        current=$(cat "$sched_file" 2>/dev/null || echo "")
        found_disk=true

        # 判断磁盘类型
        local target_sched
        if [[ "$name" == nvme* ]]; then
            # NVMe：none（多队列原生，不需要调度器）
            target_sched="none"
        elif [[ "$name" == vd* ]]; then
            # virtio 虚拟磁盘：none
            target_sched="none"
        elif cat "$dev/queue/rotational" 2>/dev/null | grep -q "0"; then
            # SSD：mq-deadline
            target_sched="mq-deadline"
        else
            # 机械盘：bfq
            target_sched="bfq"
        fi

        if $DRY_RUN; then
            info "[dry-run] $name: 当前=$current → 目标=$target_sched"
        else
            # 检查目标调度器是否可用
            if grep -q "$target_sched" "$sched_file" 2>/dev/null; then
                echo "$target_sched" > "$sched_file"
                info "$name: $current → $target_sched"
            else
                # 回退到可用的第一个非 none 调度器
                local fallback
                fallback=$(sed 's/\[//g;s/\]//g' "$sched_file" | awk '{print $1}')
                if [[ -n "$fallback" ]]; then
                    echo "$fallback" > "$sched_file"
                    warn "$name: $target_sched 不可用，回退到 $fallback"
                fi
            fi

            # 持久化：udev 规则
            local udev_rule="/etc/udev/rules.d/60-io-scheduler.rules"
            if [[ ! -f "$udev_rule" ]] || ! grep -q "$name" "$udev_rule" 2>/dev/null; then
                if [[ "$name" == nvme* ]]; then
                    echo 'ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"' >> "$udev_rule"
                elif [[ "$name" == vd* ]]; then
                    echo 'ACTION=="add|change", KERNEL=="vd*", ATTR{queue/scheduler}="none"' >> "$udev_rule"
                elif cat "$dev/queue/rotational" 2>/dev/null | grep -q "0"; then
                    echo 'ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"' >> "$udev_rule"
                else
                    echo 'ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"' >> "$udev_rule"
                fi
            fi
        fi
    done

    if ! $found_disk; then
        info "未检测到磁盘设备，跳过"
    fi
}

# ============================================================
# dmesg 日志缓冲
# ============================================================
apply_dmesg() {
    title "dmesg 日志缓冲"

    local current_size
    current_size=$(dmesg --buffer-size 2>/dev/null || cat /proc/sys/kernel/printk_devkmsg 2>/dev/null || echo "unknown")

    # 根据内存大小设不同的 buffer
    local target_kb
    case "$TIER" in
        small)  target_kb=262144  ;;  # 256K
        medium) target_kb=524288  ;;  # 512K
        large)  target_kb=1048576 ;;  # 1M
    esac

    if $DRY_RUN; then
        info "[dry-run] dmesg 缓冲当前: $current_size"
        info "[dry-run] 将设为 ${target_kb} 字节"
    else
        # 写入 sysctl
        if ! grep -q "kernel.printk_devkmsg" /etc/sysctl.conf 2>/dev/null; then
            echo "" >> /etc/sysctl.conf
            echo "# --- dmesg 日志缓冲 ---" >> /etc/sysctl.conf
            echo "kernel.printk_devkmsg=on" >> /etc/sysctl.conf
        fi

        # 通过 sysctl 设置 ring buffer 大小
        sysctl -w kernel.dmesg_restrict=0 >/dev/null 2>&1 || true

        # 持久化到 /etc/sysctl.conf
        if ! grep -q "kernel.dmesg_restrict" /etc/sysctl.conf 2>/dev/null; then
            echo "kernel.dmesg_restrict=0" >> /etc/sysctl.conf
        fi

        info "dmesg 缓冲已配置"
    fi
}

# ============================================================
# ZFS ARC 限制
# ============================================================
apply_zfs_arc() {
    title "ZFS ARC 内存限制"

    # 检测是否使用了 ZFS
    if ! command -v zfs &>/dev/null && ! lsmod 2>/dev/null | grep -q zfs; then
        info "未检测到 ZFS，跳过"
        return
    fi

    # ARC 限制：预留足够内存给宿主机和 VM
    # 默认 ZFS 会吃掉所有可用内存做缓存，这会导致 VM 内存被 swap
    local arc_max_mb
    case "$TIER" in
        small)
            # 小内存机器：ARC 最多用 1/4 内存
            arc_max_mb=$(( MEM_MB / 4 ))
            ;;
        medium)
            # 中等：ARC 最多用 1/3 内存
            arc_max_mb=$(( MEM_MB / 3 ))
            ;;
        large)
            # 大内存：ARC 最多用 1/4 内存（绝对值已经够大了）
            arc_max_mb=$(( MEM_GB * 1024 / 4 ))
            ;;
    esac

    # 下限 512M，上限 32G（超过没必要限了）
    [[ $arc_max_mb -lt 512 ]] && arc_max_mb=512
    [[ $arc_max_mb -gt 32768 ]] && arc_max_mb=32768

    local arc_max_bytes=$(( arc_max_mb * 1024 * 1024 ))
    # arc_meta_limit 设为 arc_max 的 3/4
    local arc_meta_bytes=$(( arc_max_bytes * 3 / 4 ))

    local current_arc
    current_arc=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo "0")

    if $DRY_RUN; then
        info "[dry-run] ZFS ARC 当前限制: $(( current_arc / 1024 / 1024 ))M"
        info "[dry-run] 将设为 ${arc_max_mb}M（内存的 ~$(( arc_max_mb * 100 / MEM_MB ))%）"
    else
        # 写入 modprobe 配置（重启生效）
        cat > /etc/modprobe.d/zfs-arc.conf <<MODPROBE
# ZFS ARC 内存限制 — PVE 优化脚本自动生成
# 预留内存给 VM，防止 ARC 膨胀导致 swap
options zfs zfs_arc_max=${arc_max_bytes}
options zfs zfs_arc_meta_limit=${arc_meta_bytes}
MODPROBE

        # 立即生效（运行时）
        echo "$arc_max_bytes" > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true
        echo "$arc_meta_bytes" > /sys/module/zfs/parameters/zfs_arc_meta_limit 2>/dev/null || true

        info "ZFS ARC 限制已设为 ${arc_max_mb}M"
    fi
}

# ============================================================
# 恢复备份
# ============================================================
do_restore() {
    title "恢复备份"

    # 找最新的备份目录
    local latest
    latest=$(ls -td /root/pve-optimize-backup/*/ 2>/dev/null | head -1)

    if [[ -z "$latest" ]]; then
        error "未找到备份目录 /root/pve-optimize-backup/"
        exit 1
    fi

    info "将从以下目录恢复: $latest"
    read -rp "确认恢复？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    for bak in "$latest"/*.bak; do
        local orig
        orig="/etc/$(basename "$bak" .bak)"
        if [[ "$orig" == "/etc/sysctl.d.bak" ]]; then
            continue
        fi
        cp -a "$bak" "$orig"
        info "已恢复: $orig"
    done

    # 恢复 sysctl.d
    if [[ -d "$latest/sysctl.d" ]]; then
        cp -a "$latest/sysctl.d/"* /etc/sysctl.d/ 2>/dev/null || true
        info "已恢复: /etc/sysctl.d/"
    fi

    # 生效
    sysctl --system > /dev/null 2>&1
    systemctl daemon-reload
    systemctl restart systemd-journald 2>/dev/null || true

    info "恢复完成！"
}

# ============================================================
# 验证生效
# ============================================================
verify() {
    title "验证关键参数"

    local checks=(
        "net.ipv4.tcp_congestion_control"
        "net.core.somaxconn"
        "net.ipv4.tcp_syncookies"
        "fs.file-max"
        "vm.swappiness"
        "net.ipv4.ip_forward"
        "net.netfilter.nf_conntrack_max"
        "net.ipv4.tcp_fin_timeout"
    )

    for param in "${checks[@]}"; do
        local val
        val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        printf "  %-45s = %s\n" "$param" "$val"
    done

    echo ""
    info "其他优化项状态:"

    # THP
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        local thp
        thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
        printf "  %-45s = %s\n" "THP (transparent_hugepage)" "$thp"
    fi

    # CPU governor
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        local gov
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        printf "  %-45s = %s\n" "CPU 调频策略" "$gov"
    fi

    # KSM
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
        local ksm_run
        ksm_run=$(cat /sys/kernel/mm/ksm/run)
        local ksm_label
        case "$ksm_run" in
            0) ksm_label="关闭" ;;
            1) ksm_label="运行中" ;;
            *) ksm_label="$ksm_run" ;;
        esac
        printf "  %-45s = %s\n" "KSM (内存同页合并)" "$ksm_label"
    fi

    # ZFS ARC
    if [[ -f /sys/module/zfs/parameters/zfs_arc_max ]]; then
        local arc
        arc=$(cat /sys/module/zfs/parameters/zfs_arc_max)
        if [[ "$arc" -gt 0 ]] 2>/dev/null; then
            printf "  %-45s = %sM\n" "ZFS ARC 限制" "$(( arc / 1024 / 1024 ))"
        fi
    fi
}

# ============================================================
# 摘要
# ============================================================
summary() {
    title "优化摘要"

    echo ""
    echo "  硬件配置:     ${CPU_CORES} 核 / ${MEM_GB}G RAM"
    echo "  优化档位:     ${TIER_NAME}"
    echo "  备份目录:     ${BACKUP_DIR}"
    echo ""
    echo "  已优化项:"
    echo "    ✔ ulimit / 文件描述符"
    echo "    ✔ systemd DefaultLimit"
    echo "    ✔ journald 日志限制 (300M)"
    echo "    ✔ sysctl 内核参数 (网络/内存/连接追踪)"
    echo "    ✔ BBR 拥塞控制"
    echo "    ✔ THP → madvise（避免 VM 延迟毛刺）"
    echo "    ✔ CPU 调频 → performance"
    echo "    ✔ KSM 内存同页合并"
    echo "    ✔ 磁盘 IO 调度器（SSD→mq-deadline / NVMe→none / HDD→bfq）"
    echo "    ✔ dmesg 日志缓冲"
    echo "    ✔ ZFS ARC 内存限制（如检测到 ZFS）"
    echo "    ✔ 时区 (Asia/Shanghai) + NTP 同步"
    echo ""
    echo "  未修改项（PVE 不应动）:"
    echo "    ✘ 防火墙 (pve-firewall 保留)"
    echo "    ✘ conntrack 模块 (PVE 依赖)"
    echo "    ✘ irqbalance (多核宿主机保留)"
    echo "    ✘ /etc/sysctl.d/ 下的 PVE 配置"
    echo "    ✘ 时间同步 (chrony)"
    echo "    ✘ AppArmor"
    echo ""

    if $DRY_RUN; then
        warn "本次为 dry-run 模式，未实际写入任何文件"
    else
        info "优化已完成，建议重启宿主机使所有参数完全生效"
        info "如需回滚: bash $0 --restore"
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PVE 宿主机自适应优化脚本 v1.0       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restore)
                do_restore
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                warn "dry-run 模式：只打印，不写入"
                ;;
            --region)
                shift
                case "${1:-}" in
                    cn|hk|intl)
                        REGION="$1"
                        ;;
                    *)
                        error "--region 参数无效，可选: cn / hk / intl"
                        exit 1
                        ;;
                esac
                ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --dry-run          只打印参数，不写入"
                echo "  --restore          回滚到上次备份"
                echo "  --region <区域>    NTP 服务器区域: cn / hk / intl"
                echo "                     时区始终为北京时间 (Asia/Shanghai)"
                echo "                     默认 auto（根据当前时区自动检测）"
                echo "  --help, -h         显示帮助"
                echo ""
                echo "示例:"
                echo "  bash $0                        # 自动检测，国内/海外 NTP"
                echo "  bash $0 --dry-run              # 预览模式"
                echo "  bash $0 --region intl           # 海外服务器（国际 NTP）"
                echo "  bash $0 --region hk             # 香港服务器（本地 NTP）"
                echo "  bash $0 --region cn --dry-run   # 国内服务器预览"
                exit 0
                ;;
            *)
                error "未知参数: $1（用 --help 查看帮助）"
                exit 1
                ;;
        esac
        shift
    done

    check_env
    detect_hardware
    calc_params

    if ! $DRY_RUN; then
        backup_configs
    fi

    apply_ulimit
    apply_systemd_limits
    apply_journald
    apply_sysctl
    ensure_bbr
    apply_thp
    apply_cpu_governor
    apply_ksm
    apply_io_scheduler
    apply_dmesg
    apply_zfs_arc
    apply_timezone

    if ! $DRY_RUN; then
        verify
    fi

    summary
}

main "$@"

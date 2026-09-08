#!/bin/bash
#
# PVE 无订阅源切换 + 去除「无有效订阅」弹窗（持久化）
# 适用：Proxmox VE 7.x / 8.x / 9.x（Debian 11 / 12 / 13）
#
# 做的事：
#   1. 禁用 pve-enterprise / ceph enterprise 源
#   2. 启用（不存在则新建）pve-no-subscription / ceph no-subscription 源
#      PVE 9 用 deb822 格式（.sources），PVE 7/8 用传统格式（.list）
#   3. 补丁 proxmoxlib.js 去除登录后的无订阅弹窗，并安装 apt 钩子：
#      每次 apt 升级覆盖 JS 文件后自动重新打补丁（持久化）
#   4. （可选，--upgrade）apt-get update && dist-upgrade 更新系统，
#      全自动免交互：跳过变更日志阅读、配置冲突保留现有配置、服务自动重启
#
# 用法：
#   bash pve-nosub.sh                 # 换源 + 去弹窗（默认不更新系统）
#   bash pve-nosub.sh --upgrade       # 换源 + 去弹窗 + 更新系统到最新
#   bash pve-nosub.sh --restore       # 回滚到上次备份（含恢复弹窗）
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
DO_UPGRADE=false
BACKUP_DIR="/root/pve-nosub-backup/$(date +%Y%m%d_%H%M%S)"
CODENAME=""
NAG_HOOK_BIN="/usr/local/bin/pve-nag-patch"
NAG_HOOK_APT="/etc/apt/apt.conf.d/90pve-no-nag"

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
        info "PVE 版本: $(pveversion 2>/dev/null | head -1 || echo unknown)"
    fi

    CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if [[ -z "$CODENAME" ]]; then
        error "无法检测 Debian 版本代号（/etc/os-release 无 VERSION_CODENAME）"
        exit 1
    fi
    info "Debian 版本代号: $CODENAME"

    case "$CODENAME" in
        trixie)   info "仓库格式: deb822（.sources，PVE 9）" ;;
        bookworm) info "仓库格式: 传统 .list（PVE 8）" ;;
        bullseye) info "仓库格式: 传统 .list（PVE 7）" ;;
        *)        warn "未识别的代号 $CODENAME，按传统 .list 处理" ;;
    esac
}

# ============================================================
# 备份（manifest 记录：M=改动前备份，C=新建需回滚删除）
# ============================================================
backup_file() {
    local f="$1" rel
    rel="${f#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$f" "$BACKUP_DIR/$rel"
    grep -qxF "M $f" "$BACKUP_DIR/manifest" 2>/dev/null || echo "M $f" >> "$BACKUP_DIR/manifest"
    info "已备份: $f"
}

mark_created() {
    grep -qxF "C $1" "$BACKUP_DIR/manifest" 2>/dev/null || echo "C $1" >> "$BACKUP_DIR/manifest"
}

# ============================================================
# 换源：deb822 格式（.sources，PVE 9）
# 逐段处理：含 enterprise.proxmox.com 的段 → Enabled: no
#           含 no-subscription 的段 → 确保启用
# ============================================================
fix_deb822_file() {
    local f="$1" tmp
    tmp=$(mktemp)
    awk '
        {
            is_ent   = ($0 ~ /enterprise\.proxmox\.com/)
            is_nosub = ($0 ~ /no-subscription/)
            n = split($0, lines, "\n")
            has_enabled = 0
            out = ""
            for (i = 1; i <= n; i++) {
                if (lines[i] ~ /^Enabled:/) {
                    has_enabled = 1
                    if (is_ent)        lines[i] = "Enabled: no"
                    else if (is_nosub) lines[i] = "Enabled: yes"
                }
                out = out lines[i] "\n"
            }
            if (!has_enabled && is_ent) out = out "Enabled: no\n"
            printf "%s\n", out
        }
    ' RS='' "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

# ============================================================
# 换源：传统格式（.list 与 /etc/apt/sources.list，PVE 7/8）
# ============================================================
fix_list_file() {
    local f="$1"
    # 注释掉 enterprise 行
    sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]].*enterprise\.proxmox\.com/ s/^[[:space:]]*/# disabled by pve-nosub: /' "$f"
    # 取消注释官方预留的 no-subscription 行
    sed -i -E '/^[[:space:]]*#[[:space:]]*deb(-src)?[[:space:]].*no-subscription/ s/^[[:space:]]*#[[:space:]]*//' "$f"
}

# ============================================================
# 是否已有启用状态的 pve-no-subscription 源
# ============================================================
has_pve_nosub() {
    local f
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if awk 'BEGIN{found=0} /pve-no-subscription/ && !/Enabled:[[:space:]]*no/ {found=1} END{exit !found}' RS='' "$f"; then
            return 0
        fi
    done
    if grep -Eq "^[[:space:]]*deb[[:space:]].*pve-no-subscription" \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        return 0
    fi
    return 1
}

# ============================================================
# 换源主流程
# ============================================================
switch_repos() {
    title "切换为 no-subscription 源"

    # --- 1. 处理已有的 .sources 文件（PVE 9） ---
    local f
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        grep -q "proxmox.com" "$f" || continue   # 跳过 debian.sources 等
        backup_file "$f"
        fix_deb822_file "$f"
        info "已处理: $f"
    done

    # --- 2. 处理 .list 文件与 /etc/apt/sources.list（PVE 7/8） ---
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        grep -q "proxmox.com" "$f" || continue
        backup_file "$f"
        fix_list_file "$f"
        info "已处理: $f"
    done

    # --- 3. ceph.list：按原有 enterprise 行补一条 no-subscription ---
    if [[ -f /etc/apt/sources.list.d/ceph.list ]]; then
        f=/etc/apt/sources.list.d/ceph.list
        if ! grep -Eq "^[[:space:]]*deb[[:space:]].*download\.proxmox\.com/debian/ceph.*no-subscription" "$f"; then
            local ent_line ceph_rel ceph_suite
            ent_line=$(grep -E "enterprise\.proxmox\.com/debian/ceph" "$f" | head -1 || true)
            ceph_rel=$(echo "$ent_line" | grep -oE "ceph-[a-z]+" | head -1 || true)
            ceph_suite=$(echo "$ent_line" | awk '{print $3}' || true)
            if [[ -n "$ceph_rel" ]]; then
                echo "deb http://download.proxmox.com/debian/${ceph_rel} ${ceph_suite:-$CODENAME} no-subscription" >> "$f"
                info "已向 ceph.list 追加 no-subscription 源（$ceph_rel）"
            else
                warn "ceph.list 中未找到 enterprise 行，无法推断 ceph 版本，跳过"
            fi
        fi
    fi

    # --- 4. 没有启用的 pve-no-subscription 源则新建 ---
    if has_pve_nosub; then
        info "已存在启用状态的 pve-no-subscription 源，跳过新建"
    elif [[ "$CODENAME" == "trixie" ]]; then
        # PVE 9：按官方 proxmox.sources 格式新建
        local signed_by="/usr/share/keyrings/proxmox-archive-keyring.gpg"
        if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
            signed_by=$(grep -m1 "^Signed-By:" /etc/apt/sources.list.d/pve-enterprise.sources | awk '{print $2}')
            [[ -n "$signed_by" ]] || signed_by="/usr/share/keyrings/proxmox-archive-keyring.gpg"
        fi
        cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: ${signed_by}
EOF
        mark_created /etc/apt/sources.list.d/proxmox.sources
        info "已新建: /etc/apt/sources.list.d/proxmox.sources"
    else
        # PVE 7/8：传统 .list
        echo "deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription" \
            > /etc/apt/sources.list.d/pve-no-subscription.list
        mark_created /etc/apt/sources.list.d/pve-no-subscription.list
        info "已新建: /etc/apt/sources.list.d/pve-no-subscription.list"
    fi
}

# ============================================================
# 去弹窗：生成补丁脚本（主脚本与 apt 钩子共用同一份逻辑）
# ============================================================
nag_patch_script() {
    cat <<'PATCH_EOF'
#!/bin/bash
# 由 pve-nosub.sh 安装：去除 PVE「无有效订阅」登录弹窗
# apt 钩子在每次 dpkg 操作成功后调用本脚本，包升级覆盖 JS 后自动重新补丁
set -u

patch_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    grep -q "No valid sub" "$f" || return 0

    # PVE 7/8/9（proxmox-widget-toolkit）：订阅状态判断改为恒假
    # 兼容 res.data.status 与可选链 res?.data?.status
    if grep -qE "res(\?)?\.data(\?)?\.status(\?)?\.toLowerCase\(\) !== 'active'" "$f"; then
        [[ -f "$f.nagbak" ]] || cp -a "$f" "$f.nagbak"
        sed -i -E "s/res(\?)?\.data(\?)?\.status(\?)?\.toLowerCase\(\) !== 'active'/false/g" "$f"
        echo "patched(active-check): $f"
    fi

    # PVE 5/6（pvemanagerlib.js 旧判断）
    if grep -q "data.status !== 'Active'" "$f"; then
        [[ -f "$f.nagbak" ]] || cp -a "$f" "$f.nagbak"
        sed -i "s/data\.status !== 'Active'/false/g" "$f"
        echo "patched(legacy-status): $f"
    fi

    # PVE 6 及更早：多行 Ext.Msg.show 弹窗整体置空
    if grep -q "Ext.Msg.show({" "$f" && grep -q "title: gettext('No valid sub" "$f"; then
        [[ -f "$f.nagbak" ]] || cp -a "$f" "$f.nagbak"
        sed -i -z -E "s/(Ext\.Msg\.show\(\{\s*title: gettext\('No valid sub)/void(\{ \1/g" "$f"
        echo "patched(msg-show): $f"
    fi
}

patch_file /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
patch_file /usr/share/pve-manager/js/pvemanagerlib.js
exit 0
PATCH_EOF
}

# ============================================================
# 去弹窗：安装补丁 + apt 持久化钩子
# ============================================================
remove_nag() {
    title "去除无订阅弹窗（含持久化钩子）"

    # 1. 安装补丁脚本
    nag_patch_script > "$NAG_HOOK_BIN"
    chmod +x "$NAG_HOOK_BIN"
    mark_created "$NAG_HOOK_BIN"
    info "已安装补丁脚本: $NAG_HOOK_BIN"

    # 2. 安装 apt 钩子：每次 apt/dpkg 成功后自动重新补丁
    cat > "$NAG_HOOK_APT" <<EOF
// pve-nosub.sh 安装：升级覆盖 JS 文件后自动重新去除无订阅弹窗
DPkg::Post-Invoke-Success { "if [ -x $NAG_HOOK_BIN ]; then $NAG_HOOK_BIN >/dev/null 2>&1; fi; true"; };
EOF
    mark_created "$NAG_HOOK_APT"
    info "已安装 apt 钩子: $NAG_HOOK_APT"

    # 3. 立即执行一次
    if "$NAG_HOOK_BIN"; then
        info "弹窗补丁已应用"
    else
        warn "弹窗补丁未命中（可能已补丁过，或 PVE 版本检查逻辑有变化）"
    fi

    info "浏览器端需强制刷新（Ctrl+F5）清缓存后生效"
}

# ============================================================
# 系统更新（--upgrade 时执行）
# ============================================================
do_upgrade() {
    title "更新系统"

    # 全自动免交互：
    #   DEBIAN_FRONTEND=noninteractive  跳过 debconf 提问
    #   APT_LISTCHANGES_FRONTEND=none   跳过变更日志「阅读后才能继续」的分页
    #   NEEDRESTART_MODE=a              服务需要重启时自动重启，不提问
    #   confdef/confold                 配置文件冲突时保留现有配置，不提问
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none
    export NEEDRESTART_MODE=a

    apt-get update
    apt-get -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        dist-upgrade

    # 升级可能覆盖了 JS 文件，保险起见再补丁一次（钩子通常已覆盖）
    [[ -x "$NAG_HOOK_BIN" ]] && "$NAG_HOOK_BIN" || true

    # 内核更新提示
    local running_kernel latest_kernel
    running_kernel=$(uname -r)
    latest_kernel=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's/.*vmlinuz-//' | sort -V | tail -1 || true)
    if [[ -n "$latest_kernel" && "$running_kernel" != "$latest_kernel" ]]; then
        warn "内核已更新（运行中: $running_kernel，最新: $latest_kernel），建议重启宿主机"
    fi

    info "系统更新完成"
}

# ============================================================
# 回滚
# ============================================================
do_restore() {
    title "恢复备份"

    local latest
    latest=$(ls -td /root/pve-nosub-backup/*/ 2>/dev/null | head -1 || true)

    if [[ -z "$latest" || ! -f "$latest/manifest" ]]; then
        error "未找到备份 /root/pve-nosub-backup/"
        exit 1
    fi

    info "将从以下目录恢复: $latest"
    read -rp "确认恢复？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    # 先删新建的文件（钩子、新建的源）
    grep "^C " "$latest/manifest" | cut -d' ' -f2- | while read -r f; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            info "已删除新建文件: $f"
        fi
    done

    # 再恢复改动过的文件
    grep "^M " "$latest/manifest" | cut -d' ' -f2- | while read -r f; do
        local rel="${f#/}"
        if [[ -f "$latest/$rel" ]]; then
            cp -a "$latest/$rel" "$f"
            info "已恢复: $f"
        fi
    done

    # 恢复弹窗 JS（.nagbak 是补丁脚本就地备份的）
    local js
    for js in /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js \
              /usr/share/pve-manager/js/pvemanagerlib.js; do
        if [[ -f "$js.nagbak" ]]; then
            cp -a "$js.nagbak" "$js"
            rm -f "$js.nagbak"
            info "已恢复弹窗 JS: $js"
        fi
    done

    info "恢复完成！建议执行: apt-get update"
}

# ============================================================
# 摘要
# ============================================================
summary() {
    title "摘要"

    echo ""
    echo "  完成项:"
    echo "    ✔ enterprise 源已禁用（pve / ceph）"
    echo "    ✔ no-subscription 源已启用（pve / ceph）"
    echo "    ✔ 无订阅弹窗已去除，并安装 apt 钩子持久化"
    if $DO_UPGRADE; then
        echo "    ✔ 系统已更新（apt update + dist-upgrade，全自动免交互）"
    else
        echo "    - 系统更新未执行（默认不更新，加 --upgrade 开启）"
    fi
    echo ""
    echo "  备份目录: ${BACKUP_DIR}"
    echo ""

    info "回滚: bash $0 --restore"
    info "弹窗去除需浏览器强制刷新（Ctrl+F5）后生效"
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   PVE no-subscription 换源 + 去弹窗     ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restore)
                do_restore
                exit 0
                ;;
            --upgrade)
                DO_UPGRADE=true
                ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --upgrade      换源后执行系统更新（默认不更新）"
                echo "                 全自动免交互：跳过变更日志阅读，配置冲突保留现有配置"
                echo "  --restore      回滚到上次备份（含恢复弹窗）"
                echo "  --help, -h     显示帮助"
                echo ""
                echo "示例:"
                echo "  bash $0                  # 换源 + 去弹窗（不更新系统）"
                echo "  bash $0 --upgrade        # 换源 + 去弹窗 + 更新系统到最新"
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
    mkdir -p "$BACKUP_DIR"

    switch_repos
    remove_nag

    if $DO_UPGRADE; then
        do_upgrade
    fi

    summary
}

main "$@"

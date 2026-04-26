#!/bin/bash
# ================================================================
# server-init.sh v3.0
# sing-box 部署前置脚本（配合 233boy sing-box 教程）
#
# 本脚本对应教程「步骤3：关闭防火墙（临时）」的扩展版本
# 执行完本脚本后，直接按教程步骤4继续即可
#
# 本脚本做的事：
#   ✓ 系统清理（APT/日志/缓存）
#   ✓ 性能优化（sysctl/BBR/ulimit）
#   ✓ SSH 端口迁移至 3333
#   ✓ 关闭防火墙（UFW/firewalld）让 sing-box 顺利安装
#   ✓ 安装 wget（sing-box 脚本依赖）
#
# 本脚本【不做】的事（由教程安全加固章节统一处理）：
#   ✗ UFW 规则配置（需要先知道 sing-box 端口）
#   ✗ fail2ban（教程安全加固章节统一装）
#   ✗ 自动更新 crontab（教程安全加固章节统一配）
#
# 支持：Debian 10+ / Ubuntu 18.04+
# 用法：sudo bash server-init.sh
# ================================================================

set -uo pipefail

VERSION="3.0"
LOGFILE="/var/log/server-init.log"
SYSCTL_FILE="/etc/sysctl.d/99-init.conf"
LIMITS_FILE="/etc/security/limits.d/99-init.conf"
SYSTEMD_LIMITS_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMITS_FILE="${SYSTEMD_LIMITS_DIR}/99-init-limits.conf"
SSH_NEW_PORT=3333

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()      { printf "${GREEN}  ✓ %s${NC}\n" "$*"; }
warn()    { printf "${YELLOW}  ⚠ %s${NC}\n" "$*"; }
err()     { printf "${RED}  ✗ %s${NC}\n" "$*"; }
info()    { printf "${CYAN}  → %s${NC}\n" "$*"; }
section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

mkdir -p /var/log 2>/dev/null || true
exec > >(tee -a "$LOGFILE") 2>&1

# ── 环境检测 ────────────────────────────────────────────────────
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请以 root 身份运行：sudo bash $0"; exit 1
    fi
}

detect_distro() {
    DISTRO="unknown"; DISTRO_NAME="unknown"; DISTRO_VER="?"
    IS_UBUNTU=false; IS_DEBIAN=false
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="${ID:-unknown}"
        DISTRO_NAME="${NAME:-unknown}"
        DISTRO_VER="${VERSION_ID:-?}"
    fi
    case "$DISTRO" in
        ubuntu|linuxmint|pop) IS_UBUNTU=true ;;
        debian|raspbian)      IS_DEBIAN=true ;;
        *) warn "未识别发行版 $DISTRO，按 Debian 模式运行"; IS_DEBIAN=true ;;
    esac
}

detect_virt() {
    IS_OPENVZ=false; IS_LXC=false
    [ -f /proc/vz/veinfo ] && IS_OPENVZ=true \
        && warn "检测到 OpenVZ：部分内核参数可能无效"
    if grep -qaE '(lxc|container=lxc)' /proc/1/environ 2>/dev/null \
       || [ -f /.dockerenv ] \
       || grep -qE ':/(docker|lxc)/' /proc/1/cgroup 2>/dev/null; then
        IS_LXC=true
        warn "检测到 LXC/Docker：部分参数依赖宿主机内核"
    fi
}

detect_mem() {
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
}

detect_iface() {
    local dev=""
    dev=$(ip -o route get 1.1.1.1 2>/dev/null \
          | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') || true
    [ -n "$dev" ] && [ -e "/sys/class/net/${dev}" ] && echo "$dev" && return
    dev=$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}') || true
    [ -n "$dev" ] && [ -e "/sys/class/net/${dev}" ] && echo "$dev" && return
    ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' || true
}

has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

check_bbr() {
    modprobe tcp_bbr 2>/dev/null || true
    grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

calc_buffers() {
    if [ "$TOTAL_MEM_MB" -lt 2048 ]; then
        RMEM_MAX=33554432;     WMEM_MAX=33554432
        RMEM_DEFAULT=1048576;  WMEM_DEFAULT=1048576
        TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
        UDP_MEM="21845 43690 87380"
        NETDEV_BACKLOG=10000;  SOMAXCONN=4096; CONNTRACK_MAX=262144
        info "内存 <2GB：保守缓冲区"
    elif [ "$TOTAL_MEM_MB" -lt 8192 ]; then
        RMEM_MAX=67108864;     WMEM_MAX=67108864
        RMEM_DEFAULT=4194304;  WMEM_DEFAULT=4194304
        TCP_RMEM="4096 131072 67108864"; TCP_WMEM="4096 65536 67108864"
        UDP_MEM="65536 131072 262144"
        NETDEV_BACKLOG=50000;  SOMAXCONN=16384; CONNTRACK_MAX=1048576
        info "内存 2-8GB：标准缓冲区"
    else
        RMEM_MAX=134217728;    WMEM_MAX=134217728
        RMEM_DEFAULT=16777216; WMEM_DEFAULT=16777216
        TCP_RMEM="4096 262144 134217728"; TCP_WMEM="4096 262144 134217728"
        UDP_MEM="262144 524288 1048576"
        NETDEV_BACKLOG=100000; SOMAXCONN=65535; CONNTRACK_MAX=2097152
        info "内存 >8GB：激进缓冲区"
    fi
}

# ================================================================
# 第一阶段：系统清理
# ================================================================
phase_clean() {
    section "第一阶段：系统清理"

    info "[1/6] 清理 APT 缓存..."
    apt-get clean -y 2>/dev/null && ok "apt clean 完成" || warn "跳过"
    apt-get autoremove --purge -y 2>/dev/null && ok "apt autoremove 完成" || warn "跳过"

    info "[2/6] 清理 dpkg rc 残留..."
    local rc_pkgs
    rc_pkgs=$(dpkg -l 2>/dev/null | awk '/^rc/{print $2}' | tr '\n' ' ')
    if [ -n "${rc_pkgs// /}" ]; then
        # shellcheck disable=SC2086
        apt-get purge -y $rc_pkgs 2>/dev/null && ok "rc 残留包已清理" || warn "跳过"
    else
        ok "无 rc 残留包"
    fi

    info "[3/6] 清理过期日志..."
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=7d 2>/dev/null && ok "journald 保留 7 天" || warn "跳过"
    fi
    find /var/log -type f \
        \( -name "*.gz" -o -name "*.1" -o -name "*.2" \
           -o -name "*.3" -o -name "*.4" -o -name "*.old" -o -name "*.bak" \) \
        -delete 2>/dev/null || true
    while IFS= read -r f; do
        truncate -s 0 "$f" 2>/dev/null || true
    done < <(find /var/log -maxdepth 2 -type f -name "*.log" -size +50M 2>/dev/null || true)
    ok "日志清理完成"

    if $IS_UBUNTU && [ -d /var/crash ]; then
        find /var/crash -type f -delete 2>/dev/null || true
        ok "apport 崩溃报告已清理"
    fi

    info "[4/6] 清理临时文件..."
    find /tmp    -mindepth 1 -maxdepth 3 ! -type s -atime +7  -delete 2>/dev/null || true
    find /var/tmp -mindepth 1            ! -type s -atime +30 -delete 2>/dev/null || true
    ok "临时文件清理完成"

    info "[5/6] 清理用户缓存..."
    if [ -d /root/.cache ] && [ ! -L /root/.cache ]; then
        find /root/.cache -mindepth 1 -delete 2>/dev/null || true
    fi
    while IFS=: read -r _ _ uid _ _ home _; do
        if [ "${uid:-0}" -ge 1000 ] && [ -d "$home/.cache" ] && [ ! -L "$home/.cache" ]; then
            find "$home/.cache" -mindepth 1 -delete 2>/dev/null || true
        fi
    done < /etc/passwd
    ok "用户缓存清理完成"

    if $IS_UBUNTU && command -v snap >/dev/null 2>&1; then
        info "[6/6] 清理 Snap 旧版本..."
        [ -d /var/lib/snapd/cache ] && \
            find /var/lib/snapd/cache -mindepth 1 -delete 2>/dev/null || true
        snap list --all 2>/dev/null | awk '/disabled/{print $1,$3}' | \
        while read -r snapname snaprev; do
            snap remove "$snapname" --revision="$snaprev" 2>/dev/null || true
        done
        ok "Snap 清理完成"
    else
        info "[6/6] 非 Ubuntu 或未安装 snap，跳过"
    fi

    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    ok "page cache 已释放"
}

# ================================================================
# 第二阶段：性能优化
# ================================================================
phase_optimize() {
    section "第二阶段：性能优化"
    local iface="$1"

    info "[1/4] 安装依赖工具（含 sing-box 所需的 wget）..."
    export DEBIAN_FRONTEND=noninteractive
    # wget 是 sing-box 安装脚本的硬依赖，必须确保安装
    if ! command -v wget >/dev/null 2>&1; then
        apt-get install -y wget 2>/dev/null && ok "wget 已安装" || warn "wget 安装失败，sing-box 安装可能受影响"
    else
        ok "wget 已存在"
    fi
    if ! command -v ethtool >/dev/null 2>&1; then
        apt-get install -y ethtool 2>/dev/null && ok "ethtool 已安装" || warn "ethtool 安装失败，跳过"
    fi
    if ! command -v tc >/dev/null 2>&1; then
        apt-get install -y iproute2 2>/dev/null && ok "iproute2 已安装" || warn "iproute2 安装失败，跳过"
    fi
    ok "依赖工具就绪"

    info "[2/4] 应用 sysctl 内核参数（内存 ${TOTAL_MEM_MB}MB）..."
    calc_buffers

    local USE_BBR=0
    if check_bbr; then
        USE_BBR=1; ok "BBR 可用"
    else
        warn "BBR 不可用，使用 cubic + fq_codel"
    fi

    modprobe nf_conntrack 2>/dev/null || true

    cat > "$SYSCTL_FILE" << EOF
# server-init.sh v${VERSION} | $(date '+%Y-%m-%d %H:%M:%S') | 内存: ${TOTAL_MEM_MB}MB

net.core.rmem_max            = ${RMEM_MAX}
net.core.wmem_max            = ${WMEM_MAX}
net.core.rmem_default        = ${RMEM_DEFAULT}
net.core.wmem_default        = ${WMEM_DEFAULT}
net.core.optmem_max          = 8388608
net.core.netdev_max_backlog  = ${NETDEV_BACKLOG}
net.core.netdev_budget       = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn           = ${SOMAXCONN}

net.ipv4.tcp_rmem                  = ${TCP_RMEM}
net.ipv4.tcp_wmem                  = ${TCP_WMEM}
net.ipv4.tcp_max_syn_backlog       = 65535
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_fin_timeout           = 15
net.ipv4.tcp_max_tw_buckets        = 2000000
net.ipv4.tcp_fastopen              = 1
net.ipv4.tcp_keepalive_time        = 600
net.ipv4.tcp_keepalive_probes      = 5
net.ipv4.tcp_keepalive_intvl       = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_window_scaling        = 1
net.ipv4.tcp_sack                  = 1
net.ipv4.tcp_timestamps            = 1
net.ipv4.tcp_dsack                 = 1
net.ipv4.tcp_syn_retries           = 3
net.ipv4.tcp_synack_retries        = 3
net.ipv4.tcp_max_orphans           = 262144
net.ipv4.tcp_ecn                   = 2
net.ipv4.tcp_no_metrics_save       = 1

net.ipv4.udp_mem             = ${UDP_MEM}
net.ipv4.ip_local_port_range = 1024 65535

net.netfilter.nf_conntrack_max                     = ${CONNTRACK_MAX}
net.nf_conntrack_max                               = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 30
EOF

    if [ "$USE_BBR" -eq 1 ]; then
        printf '\nnet.core.default_qdisc          = fq\n'  >> "$SYSCTL_FILE"
        printf 'net.ipv4.tcp_congestion_control = bbr\n'  >> "$SYSCTL_FILE"
    else
        printf '\nnet.core.default_qdisc          = fq_codel\n' >> "$SYSCTL_FILE"
        printf 'net.ipv4.tcp_congestion_control = cubic\n'      >> "$SYSCTL_FILE"
    fi

    cat >> "$SYSCTL_FILE" << 'EOF'

vm.swappiness                = 10
vm.dirty_ratio               = 40
vm.dirty_background_ratio    = 10
vm.dirty_expire_centisecs    = 3000
vm.dirty_writeback_centisecs = 500
vm.vfs_cache_pressure        = 50
vm.min_free_kbytes           = 65536

fs.file-max                   = 2097152
fs.nr_open                    = 2097152
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 8192
fs.suid_dumpable              = 0

kernel.panic   = 10
kernel.pid_max = 4194304

net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536

net.ipv4.tcp_syncookies                   = 1
net.ipv4.conf.all.rp_filter               = 2
net.ipv4.conf.default.rp_filter           = 2
net.ipv4.conf.all.accept_redirects        = 0
net.ipv4.conf.default.accept_redirects    = 0
net.ipv4.conf.all.send_redirects          = 0
net.ipv4.conf.default.send_redirects      = 0
net.ipv4.conf.all.accept_source_route     = 0
net.ipv4.conf.default.accept_source_route = 0
EOF

    local tmp_out; tmp_out=$(mktemp)
    sysctl -p "$SYSCTL_FILE" > "$tmp_out" 2>&1 || true
    local fails
    fails=$(grep -cE 'cannot stat|No such file|Invalid argument|unknown key|permission denied' \
            "$tmp_out" 2>/dev/null || echo 0)
    cat "$tmp_out" >> "$LOGFILE" 2>/dev/null || true; rm -f "$tmp_out"
    [ "${fails:-0}" -gt 0 ] \
        && warn "${fails} 个参数未生效（虚拟化环境正常），详见 $LOGFILE" \
        || ok "sysctl 参数全部应用成功"

    info "[3/4] 提升 ulimit 资源限制..."
    mkdir -p "$(dirname "$LIMITS_FILE")"
    cat > "$LIMITS_FILE" << 'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
*    soft nproc  unlimited
*    hard nproc  unlimited
*    soft memlock unlimited
*    hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc  unlimited
root hard nproc  unlimited
EOF
    mkdir -p "$SYSTEMD_LIMITS_DIR"
    cat > "$SYSTEMD_LIMITS_FILE" << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
EOF
    if has_systemd; then systemctl daemon-reexec 2>/dev/null || true; fi
    ok "ulimit 已提升至 1048576"

    info "[4/4] 配置网卡队列调度..."
    if command -v tc >/dev/null 2>&1; then
        tc qdisc del dev "$iface" root 2>/dev/null || true
        if tc qdisc add dev "$iface" root fq 2>/dev/null; then
            ok "已配置 fq（$iface）"
        elif tc qdisc add dev "$iface" root fq_codel 2>/dev/null; then
            ok "已配置 fq_codel（$iface）"
        else
            warn "qdisc 配置失败（虚拟网卡常见），跳过"
        fi
    else
        warn "tc 不可用，跳过"
    fi
}

# ================================================================
# 第三阶段：SSH 端口迁移
# ================================================================
phase_ssh() {
    section "第三阶段：SSH 端口迁移至 ${SSH_NEW_PORT}"

    local sshd_conf="/etc/ssh/sshd_config"
    local ssh_backup="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"

    if [ ! -f "$sshd_conf" ]; then
        warn "未找到 $sshd_conf，跳过 SSH 配置"
        OLD_PORT="22"
        return
    fi

    cp "$sshd_conf" "$ssh_backup"
    ok "SSH 配置已备份：$ssh_backup"

    OLD_PORT=$(grep -E '^Port ' "$sshd_conf" 2>/dev/null | awk '{print $2}' | head -1)
    OLD_PORT="${OLD_PORT:-22}"
    info "当前端口：$OLD_PORT → 目标端口：${SSH_NEW_PORT}"

    # 检测密钥
    local has_key=false
    [ -s /root/.ssh/authorized_keys ] && has_key=true
    if ! $has_key; then
        while IFS=: read -r _ _ uid _ _ home _; do
            [ "${uid:-0}" -ge 1000 ] && [ -s "${home}/.ssh/authorized_keys" ] \
                && has_key=true && break
        done < /etc/passwd
    fi

    # 检测 sudo 用户
    local has_sudo=false
    local sm wm
    sm=$(getent group sudo  2>/dev/null | cut -d: -f4 || true)
    wm=$(getent group wheel 2>/dev/null | cut -d: -f4 || true)
    [ -n "${sm//,/}" ] && has_sudo=true
    [ -n "${wm//,/}" ] && has_sudo=true

    _sshd_set() {
        local key="$1" val="$2"
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$sshd_conf"; then
            sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$sshd_conf"
        else
            printf '%s %s\n' "$key" "$val" >> "$sshd_conf"
        fi
    }

    # 无条件安全参数
    _sshd_set "PubkeyAuthentication"    "yes"
    _sshd_set "PermitEmptyPasswords"    "no"
    _sshd_set "X11Forwarding"           "no"
    _sshd_set "MaxAuthTries"            "5"
    _sshd_set "LoginGraceTime"          "30"
    _sshd_set "ClientAliveInterval"     "300"
    _sshd_set "ClientAliveCountMax"     "2"
    _sshd_set "UseDNS"                  "no"
    _sshd_set "IgnoreRhosts"            "yes"
    _sshd_set "HostbasedAuthentication" "no"
    _sshd_set "PrintLastLog"            "yes"
    ok "SSH 基础安全参数已设置"

    # 密码登录（保守：有密钥才禁）
    if $has_key; then
        _sshd_set "PasswordAuthentication" "no"
        ok "检测到密钥 → 已禁用密码登录"
    else
        _sshd_set "PasswordAuthentication" "yes"
        warn "未检测到 authorized_keys → 保留密码登录"
        warn "配置密钥后执行："
        warn "  sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' $sshd_conf"
        warn "  systemctl reload sshd"
    fi

    # root 登录（保守）
    if $has_sudo; then
        _sshd_set "PermitRootLogin" "no"
        ok "检测到 sudo 用户 → 已禁止 root 登录"
    elif $has_key; then
        _sshd_set "PermitRootLogin" "prohibit-password"
        ok "无 sudo 用户但有密钥 → root 仅保留密钥登录"
    else
        warn "无 sudo 用户且无密钥 → PermitRootLogin 保持原值"
    fi

    # 端口迁移（双监听过渡）
    if [ "$OLD_PORT" = "${SSH_NEW_PORT}" ]; then
        ok "SSH 端口已是 ${SSH_NEW_PORT}，无需迁移"
        SSH_MIGRATED=false
    else
        # 步骤 A：同时监听旧+新，reload
        sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]/d' "$sshd_conf"
        printf 'Port %s\nPort %s\n' "$OLD_PORT" "${SSH_NEW_PORT}" >> "$sshd_conf"

        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            ok "双端口监听已生效（$OLD_PORT + ${SSH_NEW_PORT}）"
            ok "当前两个端口都可以 SSH，不会断连"
            SSH_MIGRATED=true
        else
            err "双端口配置验证失败，回滚..."
            cp "$ssh_backup" "$sshd_conf"
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            warn "SSH 已回滚，端口保持 $OLD_PORT"
            SSH_MIGRATED=false
        fi
    fi
}

# ================================================================
# 第四阶段：关防火墙（临时）
# ── 对应教程「步骤3：关闭防火墙（临时）」
# ── sing-box 安装完成后，用户按教程安全加固章节手动配置 UFW
# ================================================================
phase_firewall() {
    section "第四阶段：关闭防火墙（临时，为 sing-box 安装准备）"

    # 完成 SSH 端口迁移的最后一步（去掉旧端口监听）
    # 这里在防火墙关掉之后做，最安全
    if [ "${SSH_MIGRATED:-false}" = "true" ]; then
        local sshd_conf="/etc/ssh/sshd_config"
        sed -i -E "/^Port ${OLD_PORT}$/d" "$sshd_conf"

        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            ok "SSH 端口迁移完成：${OLD_PORT} → ${SSH_NEW_PORT}"
        else
            err "移除旧端口后验证失败，回滚至双端口..."
            sed -i -E '/^Port /d' "$sshd_conf"
            printf 'Port %s\nPort %s\n' "$OLD_PORT" "${SSH_NEW_PORT}" >> "$sshd_conf"
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            warn "SSH 仍同时监听 ${OLD_PORT} 和 ${SSH_NEW_PORT}，请手动检查"
        fi
    fi

    # 安装 UFW（如未安装）
    if ! command -v ufw >/dev/null 2>&1; then
        info "安装 UFW..."
        apt-get install -y ufw 2>/dev/null && ok "UFW 安装成功" || warn "UFW 安装失败，跳过"
    fi

    # 关闭 UFW（临时，让 sing-box 顺利安装）
    if command -v ufw >/dev/null 2>&1; then
        ufw disable 2>/dev/null || true
        ok "UFW 已关闭（临时）"
    fi

    # 关闭 firewalld（如存在）
    if command -v firewalld >/dev/null 2>&1 || systemctl list-units --type=service 2>/dev/null | grep -q firewalld; then
        systemctl stop    firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        ok "firewalld 已关闭"
    fi

    ok "防火墙已临时关闭，sing-box 可以正常安装"
}

# ================================================================
# 最终汇报
# ================================================================
final_report() {
    local iface="$1"
    local after_disk freed
    after_disk=$(df -BM / | awk 'NR==2{print $3}' | tr -d 'M')
    freed=$(( BEFORE_DISK - after_disk ))

    local ssh_ports pw_auth pw_display
    ssh_ports=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null \
                | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    ssh_ports="${ssh_ports:-22}"
    pw_auth=$(grep -E '^PasswordAuthentication ' /etc/ssh/sshd_config 2>/dev/null \
              | awk '{print $2}' || echo "yes")
    [ "$pw_auth" = "no" ] \
        && pw_display="已禁用（仅密钥登录）" \
        || pw_display="保留密码登录"

    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✓ server-init.sh v${VERSION} 执行完成！${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "  %-22s %s\n"    "系统："         "${DISTRO_NAME} ${DISTRO_VER}"
    printf "  %-22s %s\n"    "内核："         "$(uname -r)"
    printf "  %-22s %s\n"    "主网卡："       "$iface"
    printf "  %-22s %s MB\n" "内存："         "${TOTAL_MEM_MB}"
    if [ "$freed" -gt 0 ]; then
        printf "  %-22s %s MB\n" "释放磁盘："  "$freed"
    fi
    printf "  %-22s %s\n"    "BBR："          "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo -)"
    printf "  %-22s %s\n"    "SSH 端口："     "$ssh_ports"
    printf "  %-22s %s\n"    "SSH 密码登录：" "$pw_display"
    printf "  %-22s %s\n"    "防火墙："       "已临时关闭（sing-box 安装后需手动配置）"
    echo ""
    echo -e "${BOLD}${YELLOW}  ⚠ 另开终端确认 SSH 端口 ${ssh_ports} 可正常登录后再关闭本连接${NC}"
    echo -e "${BOLD}${YELLOW}  ⚠ 防火墙已临时关闭，装完 sing-box 后记得配置 UFW${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "  执行日志：${LOGFILE}"
    echo ""
}

# ================================================================
# 主流程
# ================================================================
require_root
detect_distro
detect_virt
detect_mem

IFACE="${IFACE:-}"
[ -z "$IFACE" ] && IFACE=$(detect_iface || true)
if [ -z "$IFACE" ]; then
    err "无法自动检测网卡，请用 IFACE=eth0 bash server-init.sh"; exit 1
fi

BEFORE_DISK=$(df -BM / | awk 'NR==2{print $3}' | tr -d 'M')
OLD_PORT="22"
SSH_MIGRATED=false

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  server-init.sh v${VERSION}  |  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  ${DISTRO_NAME} ${DISTRO_VER}  |  内存: ${TOTAL_MEM_MB}MB  |  网卡: ${IFACE}${NC}"
echo -e "${BOLD}  定位：sing-box 部署前置脚本${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  ${CYAN}系统清理${NC} → ${CYAN}性能优化${NC} → ${CYAN}SSH迁移至3333${NC} → ${CYAN}关防火墙${NC}"
echo ""

phase_clean
phase_optimize "$IFACE"
phase_ssh
phase_firewall
final_report   "$IFACE"

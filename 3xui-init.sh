#!/bin/bash
# ================================================================
# 3xui-init.sh v1.0
# 3X-UI 服务器初始化脚本（上游住宅服务器 & 中转服务器通用）
#
# 本脚本做的事：
#   ✓ 系统更新（无交互）
#   ✓ 安装必要工具（curl / wget / sudo）
#   ✓ 性能优化（BBR / sysctl / ulimit）
#   ✓ 安装 3X-UI 面板
#
# 本脚本【不做】的事（需要你手动完成）：
#   ✗ UFW 规则（面板端口配置完才知道端口号）
#   ✗ 3X-UI 面板配置（入站/出站/路由规则）
#
# 支持：Debian 10+ / Ubuntu 18.04+
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/always1ov/toolbox/master/3xui-init.sh)
# ================================================================

set -uo pipefail

VERSION="1.0"
LOGFILE="/var/log/3xui-init.log"
SYSCTL_FILE="/etc/sysctl.d/99-init.conf"
LIMITS_FILE="/etc/security/limits.d/99-init.conf"
SYSTEMD_LIMITS_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMITS_FILE="${SYSTEMD_LIMITS_DIR}/99-init-limits.conf"

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
        NETDEV_BACKLOG=10000; SOMAXCONN=4096; CONNTRACK_MAX=262144
        info "内存 <2GB：保守缓冲区"
    elif [ "$TOTAL_MEM_MB" -lt 8192 ]; then
        RMEM_MAX=67108864;     WMEM_MAX=67108864
        RMEM_DEFAULT=4194304;  WMEM_DEFAULT=4194304
        TCP_RMEM="4096 131072 67108864"; TCP_WMEM="4096 65536 67108864"
        UDP_MEM="65536 131072 262144"
        NETDEV_BACKLOG=50000; SOMAXCONN=16384; CONNTRACK_MAX=1048576
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
# 第一阶段：系统更新
# ================================================================
phase_update() {
    section "第一阶段：系统更新"

    export DEBIAN_FRONTEND=noninteractive

    info "更新软件包列表..."
    apt-get update -y 2>/dev/null && ok "apt update 完成" || warn "apt update 失败，继续执行"

    info "升级系统软件包（无交互）..."
    apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        2>/dev/null && ok "apt upgrade 完成" || warn "apt upgrade 失败，继续执行"

    info "安装必要工具..."
    apt-get install -y curl wget sudo ufw 2>/dev/null \
        && ok "curl / wget / sudo / ufw 已安装" \
        || warn "部分工具安装失败，继续执行"

    # 清理
    apt-get autoremove --purge -y 2>/dev/null || true
    apt-get clean -y 2>/dev/null || true
    ok "系统更新完成"
}

# ================================================================
# 第二阶段：性能优化
# ================================================================
phase_optimize() {
    section "第二阶段：性能优化"
    local iface="$1"

    info "[1/3] 应用 sysctl 内核参数（内存 ${TOTAL_MEM_MB}MB）..."
    calc_buffers

    local USE_BBR=0
    if check_bbr; then
        USE_BBR=1; ok "BBR 可用"
    else
        warn "BBR 不可用，使用 cubic + fq_codel"
    fi

    modprobe nf_conntrack 2>/dev/null || true

    cat > "$SYSCTL_FILE" << EOF
# 3xui-init.sh v${VERSION} | $(date '+%Y-%m-%d %H:%M:%S') | 内存: ${TOTAL_MEM_MB}MB

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
    cat "$tmp_out" >> "$LOGFILE" 2>/dev/null || true
    rm -f "$tmp_out"
    [ "${fails:-0}" -gt 0 ] \
        && warn "${fails} 个参数未生效（虚拟化环境正常）" \
        || ok "sysctl 参数全部应用成功"

    info "[2/3] 提升 ulimit 资源限制..."
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

    info "[3/3] 配置网卡队列调度..."
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
# 第三阶段：安装 3X-UI
# ================================================================
phase_install_3xui() {
    section "第三阶段：安装 3X-UI 面板"

    info "正在运行 3X-UI 官方安装脚本..."
    echo ""

    # 官方一键安装脚本
    if bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh); then
        echo ""
        ok "3X-UI 安装完成"
    else
        echo ""
        err "3X-UI 安装失败，请手动执行："
        err "  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
    fi
}

# ================================================================
# 最终汇报
# ================================================================
final_report() {
    local SERVER_IP
    SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "获取失败")

    # 动态读取当前 SSH 端口（兼容 server-init.sh 改过端口的情况）
    local SSH_PORT
    SSH_PORT=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    SSH_PORT="${SSH_PORT:-22}"

    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✓ 3xui-init.sh v${VERSION} 执行完成！${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "  %-20s %s\n" "系统："       "${DISTRO_NAME} ${DISTRO_VER}"
    printf "  %-20s %s\n" "内核："       "$(uname -r)"
    printf "  %-20s %s\n" "服务器 IP："  "$SERVER_IP"
    printf "  %-20s %s\n" "内存："       "${TOTAL_MEM_MB} MB"
    printf "  %-20s %s\n" "BBR："        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo -)"
    printf "  %-20s %s\n" "SSH 端口："   "$SSH_PORT"
    printf "  %-20s %s\n" "防火墙："     "已安装但【未启用】"
    echo ""
    echo -e "${BOLD}${CYAN}  ══ 下一步：手动完成以下操作 ══════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}1. 访问 3X-UI 面板${NC}"
    echo -e "     安装过程中已设置端口和账号密码，用安装时填写的信息登录："
    echo -e "     地址：http://${SERVER_IP}:<你设置的面板端口>"
    echo -e "     ${YELLOW}⚠ 记好你设置的面板端口、账号、密码！${NC}"
    echo ""
    echo -e "  ${BOLD}2. 配置完面板后，开启防火墙（替换实际端口）${NC}"
    echo ""
    echo -e "  ${CYAN}  # 上游住宅服务器执行：${NC}"
    echo -e "  ${CYAN}  ufw default deny incoming${NC}"
    echo -e "  ${CYAN}  ufw default allow outgoing${NC}"
    echo -e "  ${CYAN}  ufw allow ${SSH_PORT}/tcp        # SSH${NC}"
    echo -e "  ${CYAN}  ufw allow 443/tcp          # VLESS Reality 入站${NC}"
    echo -e "  ${CYAN}  ufw allow <安装时设置的面板端口>/tcp${NC}"
    echo -e "  ${CYAN}  ufw --force enable${NC}"
    echo ""
    echo -e "  ${CYAN}  # 中转服务器执行：${NC}"
    echo -e "  ${CYAN}  ufw default deny incoming${NC}"
    echo -e "  ${CYAN}  ufw default allow outgoing${NC}"
    echo -e "  ${CYAN}  ufw allow ${SSH_PORT}/tcp        # SSH${NC}"
    echo -e "  ${CYAN}  ufw allow 8443/tcp         # VLESS Reality 入站${NC}"
    echo -e "  ${CYAN}  ufw allow <安装时设置的面板端口>/tcp${NC}"
    echo -e "  ${CYAN}  ufw --force enable${NC}"
    echo ""
    echo -e "  ${BOLD}3. 建议重启服务器使内核参数完全生效${NC}"
    echo -e "  ${CYAN}  reboot${NC}"
    echo ""
    echo -e "  执行日志：${LOGFILE}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
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
    err "无法自动检测网卡，请用 IFACE=eth0 bash 3xui-init.sh"; exit 1
fi

BEFORE_DISK=$(df -BM / | awk 'NR==2{print $3}' | tr -d 'M')

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  3xui-init.sh v${VERSION}  |  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  ${DISTRO_NAME} ${DISTRO_VER}  |  内存: ${TOTAL_MEM_MB}MB  |  网卡: ${IFACE}${NC}"
echo -e "${BOLD}  定位：3X-UI 双服务器部署前置脚本${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  ${CYAN}系统更新${NC} → ${CYAN}性能优化${NC} → ${CYAN}安装 3X-UI${NC}"
echo ""

phase_update
phase_optimize "$IFACE"
phase_install_3xui
final_report

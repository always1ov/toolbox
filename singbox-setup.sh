#!/bin/bash
# ================================================================
# singbox-setup.sh v1.0
# sing-box 安装 + 安全加固一键脚本
# 配合 server-init.sh 使用，在其执行完之后运行
#
# 执行顺序：
#   1. 安装 sing-box（233boy 一键脚本）
#   2. 添加 Hysteria2 + Reality 节点
#   3. 开启 BBR
#   4. 配置 UFW 防火墙
#   5. 安装 fail2ban
#   6. 配置自动维护 crontab
#   7. 打印节点信息
#
# 用法：sudo bash singbox-setup.sh
# ================================================================

set -uo pipefail

VERSION="1.0"
LOGFILE="/var/log/singbox-setup.log"
SSH_PORT=3333   # 与 server-init.sh 保持一致

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

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请以 root 身份运行：sudo bash $0"; exit 1
    fi
}

# ================================================================
# 第一阶段：安装 sing-box
# ================================================================
phase_install() {
    section "第一阶段：安装 sing-box"

    # 检查是否已安装
    if command -v sing-box >/dev/null 2>&1 || [ -f /etc/sing-box/sh/sing-box.sh ]; then
        warn "检测到 sing-box 已安装"
        warn "如需重装请先执行：sing-box reinstall"
        warn "跳过安装，继续后续步骤..."
        return 0
    fi

    info "开始安装 sing-box（233boy 一键脚本）..."
    if ! command -v wget >/dev/null 2>&1; then
        apt-get install -y wget 2>/dev/null || { err "wget 安装失败，无法继续"; exit 1; }
    fi

    # 执行安装脚本
    if bash <(wget -qO- https://github.com/233boy/sing-box/raw/main/install.sh); then
        ok "sing-box 安装完成"
    else
        err "sing-box 安装失败，请检查网络或手动安装"
        err "手动命令：bash <(wget -qO- https://github.com/233boy/sing-box/raw/main/install.sh)"
        exit 1
    fi
}

# ================================================================
# 第二阶段：添加节点
# ================================================================
phase_nodes() {
    section "第二阶段：添加节点"

    # 检查 sb 命令
    if ! command -v sb >/dev/null 2>&1 && ! command -v sing-box >/dev/null 2>&1; then
        err "sb 命令不存在，sing-box 可能未正确安装"
        exit 1
    fi

    # 加载 alias（安装脚本写入了 .bashrc，这里手动补）
    export PATH="/usr/local/bin:$PATH"

    # 添加 Hysteria2
    info "添加 Hysteria2 节点（家用主力，速度最快）..."
    if sb add hy 2>/dev/null; then
        ok "Hysteria2 节点添加成功"
    else
        warn "Hysteria2 添加失败，请手动执行：sb add hy"
    fi

    # 添加 Reality
    info "添加 Reality 节点（外出主力，隐蔽性强）..."
    if sb add reality 443 auto www.bing.com 2>/dev/null; then
        ok "Reality 节点添加成功"
    else
        warn "Reality 添加失败，请手动执行：sb add reality 443 auto www.bing.com"
    fi

    # 开启 BBR
    info "开启 BBR 加速..."
    if sb bbr 2>/dev/null; then
        ok "BBR 已开启"
    else
        warn "BBR 开启失败（可能已开启），跳过"
    fi
}

# ================================================================
# 第三阶段：读取 sing-box 端口
# ================================================================
get_singbox_ports() {
    section "第三阶段：读取节点端口"

    HY2_PORT=""
    REALITY_PORT=""

    # 从配置文件读取端口
    local conf_dir="/etc/sing-box/conf"
    if [ -d "$conf_dir" ]; then
        # Hysteria2 端口
        HY2_PORT=$(grep -r '"type": "hysteria2"' "$conf_dir" -l 2>/dev/null | \
                   xargs grep -h '"listen_port"' 2>/dev/null | \
                   grep -o '[0-9]*' | head -1)

        # Reality 端口
        REALITY_PORT=$(grep -r '"reality"' "$conf_dir" -l 2>/dev/null | \
                       xargs grep -h '"listen_port"' 2>/dev/null | \
                       grep -o '[0-9]*' | head -1)
    fi

    # 备用：从 sb info 输出解析
    if [ -z "$HY2_PORT" ] || [ -z "$REALITY_PORT" ]; then
        local sb_info
        sb_info=$(sb info 2>/dev/null || true)

        [ -z "$HY2_PORT" ] && \
            HY2_PORT=$(echo "$sb_info" | grep -i 'hysteria2\|hy2\|hy ' | \
                       grep -o ':[0-9]*' | head -1 | tr -d ':')

        [ -z "$REALITY_PORT" ] && \
            REALITY_PORT=$(echo "$sb_info" | grep -i 'reality\|vless' | \
                           grep -o ':[0-9]*' | head -1 | tr -d ':')
    fi

    if [ -n "$HY2_PORT" ]; then
        ok "Hysteria2 端口：$HY2_PORT"
    else
        warn "无法自动读取 HY2 端口，UFW 将跳过该规则（稍后手动添加）"
    fi

    if [ -n "$REALITY_PORT" ]; then
        ok "Reality 端口：$REALITY_PORT"
    else
        warn "无法自动读取 Reality 端口，UFW 将跳过该规则（稍后手动添加）"
    fi
}

# ================================================================
# 第四阶段：UFW 防火墙
# ================================================================
phase_ufw() {
    section "第四阶段：配置 UFW 防火墙"

    if ! command -v ufw >/dev/null 2>&1; then
        info "安装 UFW..."
        apt-get install -y ufw 2>/dev/null && ok "UFW 安装成功" || {
            err "UFW 安装失败，跳过防火墙配置"
            return 1
        }
    fi

    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming  >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # SSH（先放行，再启用，绝不锁死）
    ufw allow "${SSH_PORT}/tcp" comment "SSH" >/dev/null 2>&1
    ok "已放行 SSH 端口 ${SSH_PORT}"

    # Hysteria2（UDP）
    if [ -n "${HY2_PORT:-}" ]; then
        ufw allow "${HY2_PORT}/udp" comment "Hysteria2" >/dev/null 2>&1
        ok "已放行 Hysteria2 端口 ${HY2_PORT}/udp"
    else
        warn "HY2 端口未知，跳过（手动执行：ufw allow <端口>/udp）"
    fi

    # Reality（TCP）
    if [ -n "${REALITY_PORT:-}" ]; then
        ufw allow "${REALITY_PORT}/tcp" comment "Reality" >/dev/null 2>&1
        ok "已放行 Reality 端口 ${REALITY_PORT}/tcp"
    else
        warn "Reality 端口未知，跳过（手动执行：ufw allow <端口>/tcp）"
    fi

    # 启用
    ufw --force enable >/dev/null 2>&1
    ok "UFW 已启用"
    ufw status numbered 2>/dev/null | grep -v '^$' | while IFS= read -r line; do
        info "$line"
    done
}

# ================================================================
# 第五阶段：fail2ban
# ================================================================
phase_fail2ban() {
    section "第五阶段：安装配置 fail2ban"

    if ! command -v fail2ban-server >/dev/null 2>&1; then
        apt-get install -y fail2ban 2>/dev/null && ok "fail2ban 安装成功" || {
            warn "fail2ban 安装失败，跳过"
            return 0
        }
    else
        ok "fail2ban 已安装"
    fi

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 86400
findtime = 600
maxretry = 3
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 86400
EOF

    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null \
        && ok "fail2ban 已启动（SSH 错误 3 次→封禁 24 小时）" \
        || warn "fail2ban 启动失败，请手动检查"
}

# ================================================================
# 第六阶段：自动维护 crontab
# ================================================================
phase_crontab() {
    section "第六阶段：配置自动维护"

    local cron_entry="0 3 */20 * * root (apt update && apt upgrade -y && sb update core && sb restart) >> /var/log/vps-maintenance.log 2>&1"

    # 避免重复添加
    if grep -q 'sb update core' /etc/crontab 2>/dev/null; then
        ok "自动维护 crontab 已存在，跳过"
    else
        echo "$cron_entry" | tee -a /etc/crontab > /dev/null
        ok "自动维护已配置（每 20 天凌晨 3 点自动更新）"
    fi
}

# ================================================================
# 最终报告
# ================================================================
final_report() {
    section "完成！节点信息如下"

    echo ""
    sb info 2>/dev/null || warn "无法获取节点信息，请手动执行：sb info"
    echo ""

    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✓ singbox-setup.sh v${VERSION} 执行完成！${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "  %-22s %s\n" "SSH 端口："     "${SSH_PORT}"
    printf "  %-22s %s\n" "HY2 端口："     "${HY2_PORT:-请手动查看}"
    printf "  %-22s %s\n" "Reality 端口：" "${REALITY_PORT:-请手动查看}"
    printf "  %-22s %s\n" "UFW："          "已启用"
    printf "  %-22s %s\n" "fail2ban："     "已启用"
    printf "  %-22s %s\n" "自动维护："     "每 20 天凌晨 3 点"
    echo ""
    echo -e "${BOLD}${YELLOW}  ⚠ 请截图保存以上节点信息！${NC}"
    echo -e "${BOLD}${YELLOW}  ⚠ 如有端口未自动识别，执行 sb info 手动查看后补加 UFW 规则${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "  执行日志：${LOGFILE}"
    echo ""
}

# ================================================================
# 主流程
# ================================================================
require_root

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  singbox-setup.sh v${VERSION}  |  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  安装 sing-box + 安全加固${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

phase_install
phase_nodes
get_singbox_ports
phase_ufw
phase_fail2ban
phase_crontab
final_report

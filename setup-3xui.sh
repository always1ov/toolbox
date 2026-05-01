#!/bin/bash
# ================================================================
# setup-3xui.sh v2.0
# 3x-ui 安装 + 随机面板端口 + UFW 配置
#
# 在 server-init.sh 跑完之后执行
# 面板内的入站/出站/路由规则请参考教程自行配置
#
# 本脚本做的事：
#   1. 安装 3x-ui（MHSanaei 官方版）
#   2. 将面板端口改为随机 5 位数
#   3. UFW 放行：SSH 3333 / 面板端口 / 443 / 8443
#   4. 启用防火墙
#   5. 打印面板访问信息
# ================================================================

set -uo pipefail

LOGFILE="/var/log/setup-3xui.log"
SSH_PORT=3333

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
# Step 1：安装 3x-ui
# ================================================================
step_install() {
    section "Step 1：安装 3x-ui"

    # 确保 curl 可用
    if ! command -v curl >/dev/null 2>&1; then
        info "安装 curl..."
        apt-get install -y curl 2>/dev/null && ok "curl 已安装" || {
            err "curl 安装失败，无法继续"; exit 1
        }
    fi

    info "拉取 3x-ui 官方安装脚本..."
    echo ""

    # 官方安装脚本（回车跳过所有交互提示）
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<'EOF'

EOF

    # 检查服务是否启动
    local i=0
    info "等待 x-ui 服务启动..."
    while [ $i -lt 20 ]; do
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            ok "x-ui 服务已运行"
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if ! systemctl is-active --quiet x-ui 2>/dev/null; then
        warn "x-ui 未自动启动，尝试手动启动..."
        systemctl enable x-ui 2>/dev/null || true
        systemctl start  x-ui 2>/dev/null || true
        sleep 3
        systemctl is-active --quiet x-ui 2>/dev/null \
            && ok "x-ui 启动成功" \
            || { err "x-ui 启动失败，请检查：systemctl status x-ui"; exit 1; }
    fi
}

# ================================================================
# Step 2：将面板端口改为随机 5 位数
# ================================================================
step_set_port() {
    section "Step 2：设置随机面板端口"

    # 生成随机 5 位端口（10000-65535 范围内，避开常见端口）
    # 同时避开本脚本会放行的端口
    local candidate
    while true; do
        candidate=$(shuf -i 10000-65535 -n 1)
        # 跳过已使用的端口
        if [ "$candidate" -ne "$SSH_PORT" ] \
        && [ "$candidate" -ne 443 ] \
        && [ "$candidate" -ne 8443 ]; then
            break
        fi
    done
    PANEL_PORT=$candidate
    info "生成面板端口：$PANEL_PORT"

    # 用 x-ui 命令行修改端口
    if command -v x-ui >/dev/null 2>&1; then
        x-ui setting -port "$PANEL_PORT" 2>/dev/null \
            && ok "面板端口已通过 x-ui 命令设置为 $PANEL_PORT" \
            || warn "x-ui 命令设置失败，尝试直接修改数据库..."
    fi

    # 直接修改 SQLite 数据库（双保险）
    local db="/etc/x-ui/x-ui.db"
    if [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db" \
            "UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';" 2>/dev/null \
            && ok "数据库端口已更新为 $PANEL_PORT" \
            || warn "数据库更新失败，端口可能未生效"
    elif [ -f "$db" ] && ! command -v sqlite3 >/dev/null 2>&1; then
        info "安装 sqlite3 用于修改数据库..."
        apt-get install -y sqlite3 2>/dev/null || true
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$db" \
                "UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';" 2>/dev/null \
                && ok "数据库端口已更新为 $PANEL_PORT" \
                || warn "数据库更新失败"
        fi
    fi

    # 重启 x-ui 使端口生效
    info "重启 x-ui 使端口生效..."
    systemctl restart x-ui 2>/dev/null || true
    sleep 3

    # 验证端口是否生效
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT}"; then
            ok "已确认面板在端口 $PANEL_PORT 监听"
        else
            warn "端口 $PANEL_PORT 暂未监听，服务可能仍在启动中"
        fi
    fi
}

# ================================================================
# Step 3：配置并启用 UFW
# ================================================================
step_ufw() {
    section "Step 3：配置 UFW 防火墙"

    # 安装 UFW（如未安装）
    if ! command -v ufw >/dev/null 2>&1; then
        info "安装 UFW..."
        apt-get install -y ufw 2>/dev/null && ok "UFW 安装成功" || {
            err "UFW 安装失败，跳过防火墙配置"; return
        }
    fi

    # 重置规则
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming  >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # !! 先放行所有端口，最后才 enable !!
    ufw allow "${SSH_PORT}/tcp"   comment "SSH"        >/dev/null 2>&1 || true
    ufw allow "${PANEL_PORT}/tcp" comment "3x-ui面板"  >/dev/null 2>&1 || true
    ufw allow 443/tcp             comment "VLESS入站"  >/dev/null 2>&1 || true
    ufw allow 8443/tcp            comment "VLESS入站"  >/dev/null 2>&1 || true

    # 启用防火墙
    ufw --force enable >/dev/null 2>&1
    ok "UFW 已启用，放行端口："
    ok "  SSH        → ${SSH_PORT}/tcp"
    ok "  3x-ui 面板 → ${PANEL_PORT}/tcp"
    ok "  VLESS 入站 → 443/tcp"
    ok "  VLESS 入站 → 8443/tcp"
}

# ================================================================
# 最终汇报
# ================================================================
final_report() {
    # 获取服务器公网 IP
    local SERVER_IP=""
    SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
             || curl -s4 --max-time 5 ip.sb 2>/dev/null \
             || curl -s4 --max-time 5 api.ipify.org 2>/dev/null \
             || echo "你的服务器IP")

    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  ✓ 3x-ui 安装完成！${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "  %-20s %s\n" "面板地址："    "http://${SERVER_IP}:${PANEL_PORT}"
    printf "  %-20s %s\n" "默认用户名："  "admin"
    printf "  %-20s %s\n" "默认密码："    "admin"
    printf "  %-20s %s\n" "SSH 端口："    "${SSH_PORT}"
    echo ""
    echo -e "${BOLD}${YELLOW}  ⚠ 登录后立即修改用户名和密码！${NC}"
    echo -e "${BOLD}${YELLOW}  ⚠ 面板端口 ${PANEL_PORT} 请记录保存，重装后会变！${NC}"
    echo ""
    echo -e "  执行日志：${LOGFILE}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ================================================================
# 主流程
# ================================================================
require_root

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  setup-3xui.sh v2.0  |  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  3x-ui 安装 + 随机面板端口 + UFW 配置${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

PANEL_PORT=2053  # 默认值，step_set_port 会覆盖

step_install
step_set_port
step_ufw
final_report

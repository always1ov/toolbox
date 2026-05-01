#!/bin/bash
# ================================================================
# setup-3xui.sh v1.0
# 3x-ui 安装 + 防火墙配置脚本
# 在 server-init.sh 跑完之后执行
#
# 本脚本做的事：
#   1. 安装 3x-ui（MHSanaei 官方版）
#   2. 获取面板随机端口
#   3. 配置 UFW（SSH 3333 + 面板端口 + HTTPS 443）
#   4. 启用防火墙
#   5. 打印面板访问地址
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

    info "开始安装 3x-ui（官方一键脚本）..."
    echo ""

    # 官方安装脚本，-y 自动确认所有提示
    if bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) << 'INSTALL_INPUT'
y
INSTALL_INPUT
    then
        ok "3x-ui 安装完成"
    else
        # 安装脚本退出码不可靠，检查服务是否存在
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            ok "3x-ui 服务已运行"
        else
            err "3x-ui 安装可能失败，请检查上方输出"
            err "可手动执行：bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
            exit 1
        fi
    fi

    # 等待服务完全启动
    info "等待服务启动..."
    local i=0
    while [ $i -lt 15 ]; do
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            ok "x-ui 服务已运行"
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    if ! systemctl is-active --quiet x-ui 2>/dev/null; then
        warn "x-ui 服务未能自动启动，尝试手动启动..."
        systemctl enable x-ui 2>/dev/null || true
        systemctl start  x-ui 2>/dev/null || true
        sleep 3
        systemctl is-active --quiet x-ui 2>/dev/null \
            && ok "x-ui 启动成功" \
            || warn "x-ui 启动失败，请手动检查：systemctl status x-ui"
    fi
}

# ================================================================
# Step 2：获取面板端口
# ================================================================
step_get_port() {
    section "Step 2：获取面板端口"

    PANEL_PORT=""

    # 方法1：从 x-ui 配置数据库读取
    local db_path="/etc/x-ui/x-ui.db"
    if [ -f "$db_path" ] && command -v sqlite3 >/dev/null 2>&1; then
        PANEL_PORT=$(sqlite3 "$db_path" \
            "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null || true)
    fi

    # 方法2：从配置文件读取
    if [ -z "$PANEL_PORT" ]; then
        local conf_path="/usr/local/x-ui/bin/config.json"
        if [ -f "$conf_path" ]; then
            PANEL_PORT=$(grep -oP '"port"\s*:\s*\K[0-9]+' "$conf_path" 2>/dev/null | head -1 || true)
        fi
    fi

    # 方法3：从进程监听端口检测
    if [ -z "$PANEL_PORT" ]; then
        if command -v ss >/dev/null 2>&1; then
            PANEL_PORT=$(ss -tlnp 2>/dev/null | grep x-ui \
                | grep -oP ':\K[0-9]+' | head -1 || true)
        fi
    fi

    # 方法4：x-ui 命令行
    if [ -z "$PANEL_PORT" ] && command -v x-ui >/dev/null 2>&1; then
        PANEL_PORT=$(x-ui setting -show 2>/dev/null \
            | grep -i 'port' | grep -oP '[0-9]+' | head -1 || true)
    fi

    if [ -n "$PANEL_PORT" ] && [ "$PANEL_PORT" -gt 0 ] 2>/dev/null; then
        ok "面板端口：$PANEL_PORT"
    else
        # 获取失败则用默认值
        PANEL_PORT="2053"
        warn "未能自动检测面板端口，使用默认值 $PANEL_PORT"
        warn "安装后可在面板「面板设置」中确认实际端口"
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

    # !! 关键：先放行所有端口，最后才 enable !!
    ufw allow "${SSH_PORT}/tcp"    comment "SSH"       >/dev/null 2>&1 || true
    ufw allow "${PANEL_PORT}/tcp"  comment "3x-ui面板" >/dev/null 2>&1 || true
    ufw allow 443/tcp              comment "HTTPS"     >/dev/null 2>&1 || true
    # Reality 通常用 443，节点端口在面板里配置后若不是 443 需手动补充：
    # ufw allow <节点端口>/tcp

    ok "已放行端口："
    ok "  SSH        → ${SSH_PORT}/tcp"
    ok "  3x-ui 面板 → ${PANEL_PORT}/tcp"
    ok "  HTTPS      → 443/tcp"

    # 启用防火墙
    ufw --force enable >/dev/null 2>&1
    ok "UFW 已启用"

    echo ""
    ufw status numbered 2>/dev/null | while IFS= read -r line; do
        info "$line"
    done
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
    printf "  %-20s %s\n" "面板地址："   "http://${SERVER_IP}:${PANEL_PORT}"
    printf "  %-20s %s\n" "默认用户名：" "admin"
    printf "  %-20s %s\n" "默认密码："   "admin"
    printf "  %-20s %s\n" "SSH 端口："   "${SSH_PORT}"
    echo ""
    echo -e "${BOLD}${YELLOW}  ⚠ 登录后第一件事：修改面板用户名和密码！${NC}"
    echo ""
    echo -e "${BOLD}${CYAN}  ── 面板里配置 VLESS + Reality 节点步骤 ────────────${NC}"
    echo -e "  1. 浏览器打开面板地址，登录"
    echo -e "  2. 左侧「入站列表」→「添加入站」"
    echo -e "  3. 协议选 ${BOLD}vless${NC}"
    echo -e "  4. 传输选 ${BOLD}TCP${NC}，安全选 ${BOLD}Reality${NC}"
    echo -e "  5. SNI 填 ${BOLD}www.microsoft.com${NC}（或其他大厂域名）"
    echo -e "  6. 点「获取公钥」自动生成密钥对"
    echo -e "  7. 端口建议填 ${BOLD}443${NC}（已放行）"
    echo -e "  8. 保存 → 点行尾二维码图标 → 扫码导入客户端"
    echo ""
    echo -e "${BOLD}${CYAN}  ── 配置完节点后补充防火墙（如端口不是 443）───────${NC}"
    echo -e "  ${CYAN}ufw allow <节点端口>/tcp${NC}"
    echo -e "  ${CYAN}ufw reload${NC}"
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
echo -e "${BOLD}  setup-3xui.sh v1.0  |  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  3x-ui 安装 + UFW 防火墙配置${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

step_install
step_get_port
step_ufw
final_report

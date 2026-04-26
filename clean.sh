#!/bin/bash
# ================================================================
# Debian / Ubuntu 通用安全清理脚本 v3.0
# 支持：Debian 10+ / Ubuntu 18.04+
# 特性：自动检测发行版、幂等、安全、带日志、前后磁盘对比
# 用法：sudo bash clean.sh
# ================================================================

set -euo pipefail

# ── 颜色 ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 必须 root ────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请以 root 身份运行：sudo bash $0${NC}"
    exit 1
fi

# ── 检测发行版 ───────────────────────────────────────────────────
DISTRO="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO="${ID:-unknown}"        # debian / ubuntu / linuxmint ...
    DISTRO_NAME="${NAME:-unknown}"
    DISTRO_VER="${VERSION_ID:-?}"
fi

IS_UBUNTU=false
IS_DEBIAN=false
case "$DISTRO" in
    ubuntu|linuxmint|pop)   IS_UBUNTU=true ;;
    debian|raspbian)        IS_DEBIAN=true ;;
    *)
        echo -e "${YELLOW}[警告] 未识别的发行版：$DISTRO，将按 Debian 模式运行${NC}"
        IS_DEBIAN=true
        ;;
esac

# ── 脚本日志 ─────────────────────────────────────────────────────
LOGFILE="/var/log/safe_clean.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  通用安全清理脚本 v3.0  |  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  系统：${DISTRO_NAME} ${DISTRO_VER}${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"

# ── 工具函数 ─────────────────────────────────────────────────────
TOTAL=10
CURRENT=0

step() {
    CURRENT=$((CURRENT + 1))
    echo -e "\n${CYAN}[${CURRENT}/${TOTAL}] $1${NC}"
}
ok()   { echo -e "  ${GREEN}✓ $1${NC}"; }
skip() { echo -e "  ${YELLOW}⊘ $1${NC}"; }
warn() { echo -e "  ${RED}⚠ $1${NC}"; }

# ── 清理前磁盘快照 ───────────────────────────────────────────────
BEFORE=$(df -BM / | awk 'NR==2{print $3}' | tr -d 'M')
echo -e "\n${YELLOW}清理前磁盘已用：${BEFORE} MB${NC}"

# ================================================================
# 1. APT 缓存
# ================================================================
step "清理 APT 安装包缓存"
apt-get clean -y
ok "apt clean 完成"
apt-get autoremove --purge -y
ok "apt autoremove 完成"

# ================================================================
# 2. dpkg rc 残留
# ================================================================
step "清理 dpkg rc 残留配置"
RC_PKGS=$(dpkg -l | awk '/^rc/{print $2}')
if [ -n "$RC_PKGS" ]; then
    # shellcheck disable=SC2086
    apt-get purge -y $RC_PKGS
    ok "已清理 rc 残留包"
else
    skip "无 rc 残留包"
fi

# ================================================================
# 3. 系统日志（journald + 轮转旧日志 + 超大日志）
# ================================================================
step "清理过期系统日志"

# journald：保留最近 7 天
if command -v journalctl &>/dev/null; then
    journalctl --vacuum-time=7d
    ok "journald 已保留最近 7 天"
fi

# 删除轮转压缩旧日志
find /var/log -type f \
    \( -name "*.gz" -o -name "*.1" -o -name "*.2" \
       -o -name "*.3" -o -name "*.4" -o -name "*.old" \
       -o -name "*.bak" \) \
    -delete 2>/dev/null && ok "轮转旧日志已删除" || skip "无轮转旧日志"

# 超过 50MB 的 *.log 文件 truncate（保留文件句柄，rsyslog 不受影响）
while IFS= read -r f; do
    truncate -s 0 "$f"
    ok "已清空大日志：$f"
done < <(find /var/log -maxdepth 2 -type f -name "*.log" -size +50M 2>/dev/null)

# Ubuntu apport 崩溃报告
if $IS_UBUNTU && [ -d /var/crash ]; then
    find /var/crash -type f -delete 2>/dev/null && ok "apport 崩溃报告已清理" || skip "无崩溃报告"
fi

# ================================================================
# 4. /tmp 临时文件（仅删 7 天以上，跳过 socket）
# ================================================================
step "清理 /tmp 临时文件（>7天未访问）"
find /tmp -mindepth 1 -maxdepth 3 \
    ! -type s \
    -atime +7 \
    -delete 2>/dev/null && ok "/tmp 旧文件已清理" || skip "/tmp 无需清理"

find /var/tmp -mindepth 1 \
    ! -type s \
    -atime +30 \
    -delete 2>/dev/null && ok "/var/tmp 旧文件已清理" || skip "/var/tmp 无需清理"

# ================================================================
# 5. 用户缓存（~/.cache）
# ================================================================
step "清理用户缓存目录"

clean_user_cache() {
    local home="$1"
    if [ -d "$home/.cache" ]; then
        rm -rf "${home}/.cache/"* 2>/dev/null
        ok "已清理：$home/.cache"
    fi
}

clean_user_cache "/root"

while IFS=: read -r _ _ uid _ _ home _; do
    if [ "$uid" -ge 1000 ] && [ -d "$home/.cache" ]; then
        clean_user_cache "$home"
    fi
done < /etc/passwd

# ================================================================
# 6. 缩略图缓存
# ================================================================
step "清理缩略图缓存"

clean_thumbnails() {
    local home="$1"
    for d in "$home/.thumbnails" "$home/.local/share/thumbnails"; do
        if [ -d "$d" ]; then
            rm -rf "${d:?}/"* 2>/dev/null
            ok "已清理：$d"
        fi
    done
}

clean_thumbnails "/root"

while IFS=: read -r _ _ uid _ _ home _; do
    if [ "$uid" -ge 1000 ]; then
        clean_thumbnails "$home"
    fi
done < /etc/passwd

# ================================================================
# 7. Snap 清理（仅 Ubuntu 系）
# ================================================================
step "清理 Snap 缓存和旧版本（Ubuntu 专项）"

if $IS_UBUNTU && command -v snap &>/dev/null; then

    # 7a. snap 下载缓存
    if [ -d /var/lib/snapd/cache ]; then
        rm -rf /var/lib/snapd/cache/* 2>/dev/null
        ok "snap 下载缓存已清理"
    fi

    # 7b. 旧版本 snap 包（保留最新 1 个版本，删除其余）
    # snap list --all 列出所有版本，disabled 状态的是旧版本
    snap list --all 2>/dev/null | awk '
        /disabled/ {print $1, $3}
    ' | while read -r snapname revision; do
        snap remove "$snapname" --revision="$revision" 2>/dev/null \
            && ok "已删除旧版 snap：$snapname (rev $revision)" \
            || warn "删除失败（可能已被移除）：$snapname rev $revision"
    done

    ok "Snap 清理完成"
else
    skip "非 Ubuntu 系 或未安装 snap，跳过"
fi

# ================================================================
# 8. 开发工具缓存（pip / npm / yarn）
# ================================================================
step "清理开发工具缓存"

if command -v pip3 &>/dev/null; then
    pip3 cache purge 2>/dev/null && ok "pip3 缓存已清理" || skip "pip3 缓存跳过"
fi

if command -v npm &>/dev/null; then
    npm cache clean --force 2>/dev/null && ok "npm 缓存已清理" || skip "npm 缓存跳过"
fi

if command -v yarn &>/dev/null; then
    yarn cache clean 2>/dev/null && ok "yarn 缓存已清理" || skip "yarn 缓存跳过"
fi

if ! command -v pip3 &>/dev/null && ! command -v npm &>/dev/null && ! command -v yarn &>/dev/null; then
    skip "未检测到 pip3 / npm / yarn"
fi

# ================================================================
# 9. Docker 清理（仅当 Docker 已安装且运行）
# ================================================================
step "清理 Docker 悬空资源（如已安装）"

if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    docker system prune -f 2>/dev/null && ok "Docker 悬空镜像/容器/网络已清理" || warn "Docker 清理失败"
else
    skip "未安装 Docker 或服务未运行"
fi

# ================================================================
# 10. 释放内存 page cache
# ================================================================
step "释放内存 page cache"
sync
echo 3 > /proc/sys/vm/drop_caches
ok "page cache 已释放"

# ================================================================
# 完成报告
# ================================================================
AFTER=$(df -BM / | awk 'NR==2{print $3}' | tr -d 'M')
FREED=$((BEFORE - AFTER))

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✓ 清理完成！${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
printf "  %-20s %s MB\n" "清理前磁盘已用：" "$BEFORE"
printf "  %-20s %s MB\n" "清理后磁盘已用：" "$AFTER"
if [ "$FREED" -gt 0 ]; then
    echo -e "  ${GREEN}本次释放空间：${FREED} MB${NC}"
else
    echo -e "  ${YELLOW}磁盘变化：0 MB（系统本已干净）${NC}"
fi
echo -e "────────────────────────────────────────────────────────"
echo -e "  清理日志保存至：${LOGFILE}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

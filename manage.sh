#!/usr/bin/env bash
# =============================================================================
#  Winterbreak2 一键管理脚本 (macOS / Linux / Git Bash for Windows)
# =============================================================================
#  功能菜单：
#    [1] 部署状态检查  —— 检查 Node / 依赖 / 端口
#    [2] 修改运行端口  —— 交互式改端口并写入 .env
#    [3] 运行服务      —— 前台启动 node api/index.js（关闭终端即关服务）
#
#  设计要点：
#    - 用 .env 文件保存用户自定义端口（项目里没有 dotenv，所以脚本启动时 export）
#    - "运行" 选项用 exec 替换进程为 node，关闭终端 = 关服务（无需 trap）
#    - 端口检查用 Node.js 内置 net 模块（跨平台，避免 lsof/netstat 差异）
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
ENV_FILE=".env"
DEFAULT_PORT=3000

# ---------- 颜色（Git Bash / 现代终端都支持 ANSI） ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ---------- 工具函数 ----------

# 读取 .env 里的 PORT，没有则返回默认
get_port() {
    if [ -f "$ENV_FILE" ]; then
        local v
        v=$(grep -E '^PORT=' "$ENV_FILE" | head -n1 | cut -d'=' -f2 | tr -d '[:space:]')
        if [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null; then
            echo "$v"
            return
        fi
    fi
    echo "$DEFAULT_PORT"
}

# 检查端口是否被占用（返回 0 = 空闲，1 = 占用）
# 用 Node.js 内置 net 模块，跨平台一致
is_port_free() {
    local p=$1
    node -e "
        const net = require('net');
        const s = net.createServer();
        s.on('error', () => process.exit(1));
        s.listen($p, '0.0.0.0', () => s.close(() => process.exit(0)));
    " 2>/dev/null
}

press_enter() {
    echo ""
    read -rp "按 Enter 键返回菜单..." _
}

# ---------- 菜单项 ----------

action_deploy() {
    clear
    echo -e "${CYAN}===== 部署状态检查 =====${NC}"
    echo ""

    # 1. Node.js
    if command -v node >/dev/null 2>&1; then
        local node_v
        node_v=$(node --version)
        echo -e "  ${GREEN}✓${NC} Node.js       $node_v"
    else
        echo -e "  ${RED}✗${NC} Node.js       未安装（请先到 https://nodejs.org 下载）"
    fi

    # 2. 依赖
    if [ -d "node_modules" ]; then
        local expr_v
        expr_v=$(node -p "try{require('express/package.json').version}catch(e){'未安装'}" 2>/dev/null || echo "未安装")
        echo -e "  ${GREEN}✓${NC} express       $expr_v"
    else
        echo -e "  ${RED}✗${NC} express       未安装（请运行 pnpm install 或 npm install）"
    fi

    # 3. 入口文件
    if [ -f "api/index.js" ]; then
        echo -e "  ${GREEN}✓${NC} 入口文件      api/index.js"
    else
        echo -e "  ${RED}✗${NC} 入口文件      缺失"
    fi

    # 4. 资源目录
    if [ -d "assets" ]; then
        local mobi_size
        mobi_size=$(stat -c '%s' "assets/placeholder.mobi" 2>/dev/null || stat -f '%z' "assets/placeholder.mobi" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}✓${NC} 资源目录      assets/ (placeholder.mobi = ${mobi_size} 字节)"
    else
        echo -e "  ${RED}✗${NC} 资源目录      缺失"
    fi

    # 5. 端口信息
    local port
    port=$(get_port)
    echo -e "  ${GRAY}i${NC}  当前端口      ${YELLOW}$port${NC}"

    # 6. 端口可用性
    if is_port_free "$port"; then
        echo -e "  ${GREEN}✓${NC} 端口空闲      $port 可绑定"
    else
        echo -e "  ${RED}✗${NC} 端口被占用    $port 已被其他程序占用（请用 [2] 改端口）"
    fi

    # 7. .env 状态
    if [ -f "$ENV_FILE" ]; then
        echo -e "  ${GRAY}i${NC}  端口配置      ${BLUE}$ENV_FILE${NC}（已存在）"
    else
        echo -e "  ${GRAY}i${NC}  端口配置      ${BLUE}$ENV_FILE${NC}（未创建，运行时会用默认 $DEFAULT_PORT）"
    fi

    echo ""
    echo -e "${CYAN}======================${NC}"
    press_enter
}

action_change_port() {
    clear
    echo -e "${CYAN}===== 修改运行端口 =====${NC}"
    local current
    current=$(get_port)
    echo ""
    echo -e "  当前端口：${YELLOW}$current${NC}"
    echo -e "  监听地址：${BLUE}http://0.0.0.0:<新端口>${NC}"
    echo ""
    local new_port
    read -rp "请输入新端口（1-65535，留空取消）: " new_port

    if [ -z "$new_port" ]; then
        echo -e "${YELLOW}已取消${NC}"
        press_enter
        return
    fi

    # 数字校验
    if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：端口必须是纯数字${NC}"
        press_enter
        return
    fi

    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}错误：端口范围 1-65535${NC}"
        press_enter
        return
    fi

    # 端口占用检查
    if ! is_port_free "$new_port"; then
        echo -e "${RED}错误：端口 $new_port 已被占用${NC}"
        press_enter
        return
    fi

    # 写 .env
    echo "PORT=$new_port" > "$ENV_FILE"
    echo -e "${GREEN}✓ 已将端口设置为 $new_port（写入 $ENV_FILE）${NC}"
    press_enter
}

action_run() {
    clear
    local port
    port=$(get_port)
    echo -e "${CYAN}===== 启动服务 =====${NC}"
    echo ""
    echo -e "  监听地址：${BLUE}http://0.0.0.0:$port${NC}"
    echo -e "  访问方式：${GRAY}浏览器打开 http://localhost:$port/${NC}"
    echo -e "  关闭行为：${YELLOW}关闭此窗口 / Ctrl+C = 关闭服务${NC}"
    echo ""
    echo -e "${GRAY}3 秒后启动...（按 Ctrl+C 取消）${NC}"
    sleep 3

    # 依赖兜底：万一没装
    if [ ! -d "node_modules" ]; then
        echo -e "${RED}检测到 node_modules 缺失，自动执行 npm install...${NC}"
        npm install
    fi

    # 前台启动 node；exec 让 bash 进程被 node 替换，
    # 关闭终端 / Ctrl+C 时 bash 退出 → node 退出 → 端口释放。
    export PORT="$port"
    exec node api/index.js
}

# ---------- 主菜单 ----------

while true; do
    clear
    port=$(get_port)
    echo -e "${CYAN}=================================${NC}"
    echo -e "${CYAN}  Winterbreak2 一键管理脚本${NC}"
    echo -e "${CYAN}=================================${NC}"
    echo -e "  当前端口：${YELLOW}$port${NC}"
    echo ""
    echo "  [1] 部署状态检查"
    echo "  [2] 修改运行端口"
    echo "  [3] 运行（前台启动，关闭窗口即关服务）"
    echo "  [0] 退出"
    echo ""
    read -rp "请选择 [0-3]: " choice

    case "$choice" in
        1) action_deploy ;;
        2) action_change_port ;;
        3) action_run ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
    esac
done
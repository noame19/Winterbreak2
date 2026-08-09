#!/usr/bin/env bash
# =============================================================================
#  Winterbreak2 一键管理脚本 (macOS / Linux / Git Bash for Windows)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
ENV_FILE=".env"
DEFAULT_PORT=3000

# ---------- 智能判断 sudo 环境变量 ----------
SUDO=""
if [ "$(id -u 2>/dev/null)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# ---------- 颜色 ANSI ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ---------- 通用交互函数 ----------

ask_confirm() {
    local prompt_msg="$1"
    read -rp "$(echo -e "${YELLOW}${prompt_msg} [Y/n]: ${NC}")" choice
    case "$choice" in
        [Nn]* ) return 1 ;;
        * ) return 0 ;;
    esac
}

get_node_major_version() {
    if command -v node >/dev/null 2>&1; then
        node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'
    else
        echo "0"
    fi
}

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

# 动态更新 PATH 以确保刚安装的 node/npm 能被立即找到
refresh_path() {
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:$PATH"
    if command -v node >/dev/null 2>&1; then
        local node_bin
        node_bin=$(node -e "console.log(require('path').dirname(process.execPath))" 2>/dev/null || true)
        if [ -n "$node_bin" ] && [ -d "$node_bin" ]; then
            case ":$PATH:" in
                *":$node_bin:"*) ;;
                *) export PATH="$node_bin:$PATH" ;;
            esac
        fi
    fi
}

has_npm() {
    refresh_path
    if command -v npm >/dev/null 2>&1 || command -v npm.cmd >/dev/null 2>&1; then
        return 0
    fi
    if command -v where.exe >/dev/null 2>&1; then
        local npm_dirs
        npm_dirs=$(where.exe npm 2>/dev/null | xargs -I{} dirname {} 2>/dev/null | sort -u)
        if [ -n "$npm_dirs" ]; then
            export PATH="$npm_dirs:$PATH"
            if command -v npm >/dev/null 2>&1 || command -v npm.cmd >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    return 1
}

has_corepack() {
    refresh_path
    if command -v corepack >/dev/null 2>&1 || command -v corepack.cmd >/dev/null 2>&1; then
        return 0
    fi
    if command -v where.exe >/dev/null 2>&1; then
        local cp_dirs
        cp_dirs=$(where.exe corepack 2>/dev/null | xargs -I{} dirname {} 2>/dev/null | sort -u)
        if [ -n "$cp_dirs" ]; then
            export PATH="$cp_dirs:$PATH"
            if command -v corepack >/dev/null 2>&1 || command -v corepack.cmd >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    return 1
}

npm_version() {
    if has_npm; then npm --version 2>/dev/null; fi
}

# ---------- 安装与修复逻辑 ----------

action_install_node() {
    if ! ask_confirm "是否尝试自动安装 Node.js？"; then
        echo -e "${YELLOW}已跳过 Node.js 安装${NC}"
        return 1
    fi

    local os_name
    os_name=$(uname -s 2>/dev/null || echo "Windows")

    case "$os_name" in
        Linux)
            echo -e "${CYAN}正在通过系统包管理器安装 Node.js...${NC}"
            if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
                $SUDO apt-get update && $SUDO apt-get install -y nodejs npm
            elif command -v dnf >/dev/null 2>&1; then
                $SUDO dnf install -y nodejs npm
            elif command -v yum >/dev/null 2>&1; then
                $SUDO yum install -y nodejs npm
            elif command -v pacman >/dev/null 2>&1; then
                $SUDO pacman -S --noconfirm nodejs npm
            elif command -v zypper >/dev/null 2>&1; then
                $SUDO zypper install -y nodejs npm
            else
                echo -e "${RED}未识别的 Linux 发行版，请手动安装 Node.js${NC}"
            fi
            ;;
        Darwin)
            echo -e "${CYAN}检测到 macOS...${NC}"
            if command -v brew >/dev/null 2>&1; then
                brew install node
            else
                echo -e "${RED}未找到 Homebrew，正在打开官网...${NC}"
                open "https://nodejs.org/"
            fi
            ;;
        *)
            if command -v winget >/dev/null 2>&1; then
                echo -e "${CYAN}正在用 winget 安装 Node.js LTS...${NC}"
                winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
            else
                echo -e "${YELLOW}请手动前往 https://nodejs.org/ 下载安装${NC}"
            fi
            ;;
    esac

    refresh_path
}

repair_npm() {
    echo -e "${CYAN}正在检测并尝试修复 npm...${NC}"
    refresh_path

    if has_npm; then
        echo -e "  ${GREEN}✓${NC} npm 环境已恢复（v$(npm --version 2>/dev/null)）"
        return 0
    fi

    return 1
}

action_status() {
    refresh_path
    echo -e "${CYAN}===== 部署状态检查 =====${NC}"
    echo ""

    if command -v node >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Node.js       $(node --version)"
    else
        echo -e "  ${RED}✗${NC} Node.js       未安装"
    fi

    if command -v node >/dev/null 2>&1; then
        if has_npm; then
            echo -e "  ${GREEN}✓${NC} npm           $(npm_version)"
        else
            echo -e "  ${YELLOW}!${NC} npm           未安装"
        fi
    else
        echo -e "  ${GRAY}-${NC} npm           （跳过：Node.js 缺失）"
    fi

    if command -v node >/dev/null 2>&1; then
        if command -v pnpm >/dev/null 2>&1 && pnpm --version >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} pnpm          $(pnpm --version)"
        else
            echo -e "  ${RED}✗${NC} pnpm          未安装或版本不可用"
        fi
    else
        echo -e "  ${GRAY}-${NC} pnpm           （跳过：Node.js 缺失）"
    fi

    if command -v node >/dev/null 2>&1; then
        if [ -d "node_modules" ] && [ -f "node_modules/express/package.json" ]; then
            local expr_v
            expr_v=$(node -p "try{require('express/package.json').version}catch(e){'未安装'}" 2>/dev/null || echo "未安装")
            echo -e "  ${GREEN}✓${NC} express       $expr_v"
        else
            echo -e "  ${RED}✗${NC} express       未安装"
        fi
    else
        echo -e "  ${GRAY}-${NC} express       （跳过：Node.js 缺失）"
    fi

    if [ -f "api/index.js" ]; then
        echo -e "  ${GREEN}✓${NC} 入口文件      api/index.js"
    else
        echo -e "  ${RED}✗${NC} 入口文件      缺失"
    fi

    local port
    port=$(get_port)
    if is_port_free "$port"; then
        echo -e "  ${GREEN}✓${NC} 端口空闲      $port 可绑定"
    else
        echo -e "  ${RED}✗${NC} 端口被占用    $port 已被占用"
    fi
    echo ""
}

action_auto_deploy() {
    clear
    echo -e "${CYAN}===== 自动部署 =====${NC}"
    echo ""

    local needs_node=false
    local needs_npm=false
    local needs_pnpm=false
    local needs_express=false

    refresh_path

    if ! command -v node >/dev/null 2>&1; then needs_node=true; fi
    if [ "$needs_node" = false ] && ! has_npm; then needs_npm=true; fi
    if [ "$needs_node" = false ] && { ! command -v pnpm >/dev/null 2>&1 || ! pnpm --version >/dev/null 2>&1; }; then needs_pnpm=true; fi
    if [ "$needs_node" = false ] && { [ ! -d "node_modules" ] || [ ! -f "node_modules/express/package.json" ]; }; then needs_express=true; fi

    if [ "$needs_node" = false ] && [ "$needs_npm" = false ] && [ "$needs_pnpm" = false ] && [ "$needs_express" = false ]; then
        echo -e "${GREEN}所有组件均已安装完成，环境就绪！${NC}"
        press_enter
        return
    fi

    if ! ask_confirm "确定开始自动修复并安装缺失组件？"; then
        echo -e "${YELLOW}已取消自动部署${NC}"
        press_enter
        return
    fi

    # 1. 安装 Node.js
    if [ "$needs_node" = true ]; then
        echo -e "\n${CYAN}--- 步骤 1/4: 安装 Node.js ---${NC}"
        action_install_node
        refresh_path
        if ! command -v node >/dev/null 2>&1; then
            echo -e "${RED}Node.js 安装未完成，暂停后续步骤${NC}"
            press_enter
            return
        fi
        if ! has_npm; then needs_npm=true; fi
        needs_pnpm=true
        needs_express=true
    fi

    # 2. 检查并修复 npm
    if [ "$needs_npm" = true ] && command -v node >/dev/null 2>&1; then
        echo -e "\n${CYAN}--- 步骤 2/4: 检查 npm 环境 ---${NC}"
        repair_npm || true
        refresh_path
    fi

    # 3. 安装智能适配版本的 pnpm
    if [ "$needs_pnpm" = true ]; then
        echo -e "\n${CYAN}--- 步骤 3/4: 安装适配版 pnpm ---${NC}"
        if ask_confirm "是否自动安装 pnpm 包管理器？"; then
            local node_major
            node_major=$(get_node_major_version)
            local target_pnpm="pnpm"

            if [ "$node_major" -gt 0 ] && [ "$node_major" -lt 22 ]; then
                echo -e "${YELLOW}当前 Node.js 版本为 v${node_major}，将为你安装兼容版 pnpm@9...${NC}"
                target_pnpm="pnpm@9"
            fi

            if has_npm; then
                npm install -g "$target_pnpm" >/dev/null 2>&1 || true
            fi

            refresh_path

            if (! command -v pnpm >/dev/null 2>&1 || ! pnpm --version >/dev/null 2>&1) && has_corepack; then
                corepack prepare "$target_pnpm" --activate >/dev/null 2>&1 || true
                refresh_path
            fi
        fi
    fi

    # 4. 安装项目依赖包 (express)
    if [ "$needs_express" = true ]; then
        echo -e "\n${CYAN}--- 步骤 4/4: 安装项目依赖包 (express) ---${NC}"
        if ask_confirm "是否安装项目需要的 Node 依赖包？"; then
            local install_success=false

            refresh_path

            if command -v pnpm >/dev/null 2>&1 && pnpm --version >/dev/null 2>&1; then
                echo -e "${GRAY}正在使用 pnpm 安装依赖...${NC}"
                if pnpm install 2>/dev/null; then
                    install_success=true
                fi
            fi

            if [ "$install_success" = false ] && has_npm; then
                echo -e "${YELLOW}切换为 npm 自动进行依赖安装...${NC}"
                npm install
            fi
        fi
    fi

    echo -e "\n${CYAN}=== 部署流程完毕，最新状态： ===${NC}\n"
    action_status
    press_enter
}

action_change_port() {
    clear
    echo -e "${CYAN}===== 修改运行端口 =====${NC}"
    local current
    current=$(get_port)
    echo -e "当前端口：${YELLOW}$current${NC}"
    
    local new_port
    read -rp "请输入新端口（1-65535，留空取消）: " new_port

    if [ -z "$new_port" ]; then return; fi

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}错误：请输入有效端口号 (1-65535)${NC}"
        press_enter
        return
    fi

    if ! is_port_free "$new_port"; then
        echo -e "${RED}错误：端口 $new_port 已被占用${NC}"
        press_enter
        return
    fi

    echo "PORT=$new_port" > "$ENV_FILE"
    echo -e "${GREEN}✓ 已保存端口修改${NC}"
    press_enter
}

get_local_ips() {
    local os_name
    os_name=$(uname -s 2>/dev/null || echo "Linux")

    if command -v ip >/dev/null 2>&1; then
        # 现代 Linux (优先)
        ip -4 addr show 2>/dev/null | grep -v '127.0.0.1' | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}'
    elif command -v ifconfig >/dev/null 2>&1; then
        # macOS / 老旧 Linux
        ifconfig 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}'
    elif command -v hostname >/dev/null 2>&1; then
        # 通用 fallback
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '127.0.0.1'
    fi
}

action_run() {
    clear
    local port
    port=$(get_port)
    echo -e "${CYAN}===== 启动服务 =====${NC}\n"
    echo -e "  监听地址：${BLUE}http://0.0.0.0:$port${NC}"

    # 列出本机所有非 loopback 的 IPv4 地址（Kindle 等设备访问）
    local ips
    mapfile -t ips < <(get_local_ips) 2>/dev/null || ips=($(get_local_ips))

    if [ ${#ips[@]} -gt 0 ]; then
        echo ""
        echo -e "  ${CYAN}Kindle / 手机访问：浏览器打开以下任一地址${NC}"
        for ip in "${ips[@]}"; do
            [ -n "$ip" ] && echo -e "     ${CYAN}http://${ip}:${port}${NC}"
        done
    else
        echo ""
        echo -e "  ${YELLOW}⚠ 未检测到内网 IP，请手动查看网络配置${NC}"
    fi

    echo ""
    echo -e "  ${YELLOW}关闭行为：关闭此窗口 / Ctrl+C = 关闭服务${NC}"
    echo ""
    echo -e "${GRAY}3 秒后启动...（按 Ctrl+C 取消）${NC}"
    sleep 3

    refresh_path

    # 依赖兜底：node_modules 缺失时自动安装
    if [ ! -d "node_modules" ] || [ ! -f "node_modules/express/package.json" ]; then
        echo -e "\n${YELLOW}检测到依赖缺失，自动安装...${NC}"
        local install_success=false

        if command -v pnpm >/dev/null 2>&1 && pnpm --version >/dev/null 2>&1; then
            if pnpm install 2>/dev/null; then
                install_success=true
                echo -e "${GREEN}已通过 pnpm 安装依赖${NC}"
            fi
        fi

        if [ "$install_success" = false ] && has_npm; then
            if npm install; then
                install_success=true
                echo -e "${GREEN}已通过 npm 安装依赖${NC}"
            fi
        fi

        if [ "$install_success" = false ]; then
            echo -e "${RED}依赖安装失败，请手动在项目目录执行 pnpm install 或 npm install${NC}"
            press_enter
            return
        fi
    fi

    echo ""
    export PORT="$port"
    exec node api/index.js
}

# ---------- 卸载子菜单功能 ----------

uninstall_deps() {
    echo -e "${CYAN}正在清理项目依赖与本地缓存...${NC}"
    rm -rf node_modules pnpm-lock.yaml package-lock.json ~/.npm/_cacache ~/.pnpm-store 2>/dev/null || true
    echo -e "${GREEN}✓ 项目依赖及缓存清理完成！${NC}"
    press_enter
}

uninstall_global_env() {
    echo -e "${RED}====================================================${NC}"
    echo -e "${RED} 警告：这将卸载全局环境中的 Node.js, npm 和 pnpm！${NC}"
    echo -e "${RED} 这可能会导致您服务器上的其他 Node.js 项目不可用！${NC}"
    echo -e "${RED}====================================================${NC}"
    echo ""
    
    local confirm_input
    read -rp "请输入大写 'YES' 确认卸载全局环境（输入其他取消）: " confirm_input
    if [ "$confirm_input" != "YES" ]; then
        echo -e "${YELLOW}已取消全局卸载${NC}"
        press_enter
        return
    fi

    echo -e "\n${CYAN}正在卸载全局 pnpm...${NC}"
    if has_npm; then
        npm uninstall -g pnpm 2>/dev/null || true
    fi
    rm -rf ~/.local/share/pnpm ~/.pnpm-store 2>/dev/null || true

    echo -e "${CYAN}正在彻底卸载系统 Node.js 与 npm...${NC}"
    local os_name
    os_name=$(uname -s 2>/dev/null || echo "Windows")

    case "$os_name" in
        Linux)
            if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
                $SUDO apt-get purge -y nodejs npm 2>/dev/null || true
                $SUDO apt-get autoremove -y 2>/dev/null || true
            elif command -v dnf >/dev/null 2>&1; then
                $SUDO dnf remove -y nodejs npm 2>/dev/null || true
            elif command -v yum >/dev/null 2>&1; then
                $SUDO yum remove -y nodejs npm 2>/dev/null || true
            elif command -v pacman >/dev/null 2>&1; then
                $SUDO pacman -Rns --noconfirm nodejs npm 2>/dev/null || true
            elif command -v zypper >/dev/null 2>&1; then
                $SUDO zypper remove -y nodejs npm 2>/dev/null || true
            fi
            ;;
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew uninstall node 2>/dev/null || true
            fi
            ;;
    esac

    # 清理遗留软链接与全局缓存
    $SUDO rm -rf /usr/local/bin/npm /usr/local/bin/node /usr/local/bin/pnpm /usr/local/bin/corepack 2>/dev/null || true
    $SUDO rm -rf /usr/local/lib/node_modules 2>/dev/null || true
    rm -rf ~/.npm ~/.node-gyp 2>/dev/null || true

    refresh_path
    echo -e "${GREEN}✓ 全局 Node.js/npm/pnpm 环境已彻底卸载完毕！${NC}"
    press_enter
}

action_uninstall() {
    while true; do
        clear
        echo -e "${CYAN}===== 卸载与清理菜单 =====${NC}\n"
        echo "  [1] 卸载项目依赖 & 缓存 (只删 node_modules / 缓存)"
        echo "  [2] 卸载全局 Node/npm/pnpm (系统级清理，需手动确认 YES)"
        echo "  [0] 返回主菜单"
        echo ""
        read -rp "请选择 [0-2]: " un_choice

        case "$un_choice" in
            1) uninstall_deps; break ;;
            2) uninstall_global_env; break ;;
            0) break ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

# ---------- 主菜单 ----------

while true; do
    clear
    echo -e "${CYAN}=================================${NC}"
    echo -e "${CYAN}  Winterbreak2 一键管理部署脚本${NC}"
    echo -e "${CYAN}=================================${NC}\n"
    
    action_status
    
    echo "  [1] 自动部署"
    echo "  [2] 修改运行端口"
    echo "  [3] 本机运行网页"
    echo "  [4] 卸载与清理"
    echo "  [0] 退出"
    echo ""
    read -rp "请选择 [0-4]: " choice

    case "$choice" in
        1) action_auto_deploy ;;
        2) action_change_port ;;
        3) action_run ;;
        4) action_uninstall ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
    esac
done
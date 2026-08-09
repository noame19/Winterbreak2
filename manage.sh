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

# 列出本机所有非 loopback、非 link-local 的 IPv4 地址
# 排除：127.0.0.1（loopback）、169.254.x.x（APIPA link-local，未分配到 DHCP 的虚拟网卡）
get_local_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' \
            | grep -v '^127\.' | grep -v '^169\.254\.'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -oP 'inet (?:addr:)?\K[\d.]+' \
            | grep -v '^127\.' | grep -v '^169\.254\.'
    fi
}

press_enter() {
    echo ""
    read -rp "按 Enter 键返回菜单..." _
}

# 跨平台 npm 检测（Git Bash on Windows 上 npm 是 bash 脚本，不是 .exe，
# command -v 在 PATH 没显式加 nodejs 目录时会找不到）
has_npm() {
    if has_npm >/dev/null 2>&1; then
        return 0
    fi
    if command -v npm.cmd >/dev/null 2>&1; then
        return 0
    fi
    # Git Bash on Windows：用 where.exe 反查所有 npm 所在目录，全加进 PATH
    if command -v where.exe >/dev/null 2>&1; then
        local npm_dirs
        npm_dirs=$(where.exe npm 2>/dev/null | xargs -I{} dirname {} 2>/dev/null | sort -u)
        if [ -n "$npm_dirs" ]; then
            export PATH="$npm_dirs:$PATH"
            if has_npm >/dev/null 2>&1 || command -v npm.cmd >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    return 1
}

# 同上，corepack 检测
has_corepack() {
    if has_corepack >/dev/null 2>&1; then
        return 0
    fi
    if command -v corepack.cmd >/dev/null 2>&1; then
        return 0
    fi
    if command -v where.exe >/dev/null 2>&1; then
        local cp_dirs
        cp_dirs=$(where.exe corepack 2>/dev/null | xargs -I{} dirname {} 2>/dev/null | sort -u)
        if [ -n "$cp_dirs" ]; then
            export PATH="$cp_dirs:$PATH"
            if has_corepack >/dev/null 2>&1 || command -v corepack.cmd >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    return 1
}

# 拿 npm 版本字符串（用于显示）
npm_version() {
    if has_npm; then
        npm --version 2>/dev/null
    fi
}

# 拿 corepack 版本字符串
corepack_version() {
    if has_corepack; then
        corepack --version 2>/dev/null
    fi
}

# ---------- 菜单项 ----------

# npm 智能修复（Node.js 存在但 npm 命令找不到时）
# 常见原因：PowerShell 执行策略挡 .ps1 shim、npm-cli.js 缺失、多次重装残留
# 4 级修复路径：检查 npm.cmd → 绕开 .ps1 直接调 npm.cmd → 检查 npm-cli.js → corepack --install-directory
repair_npm() {
    # 调用前 caller 已确认 node 存在、npm 缺失
    echo ""
    echo -e "${CYAN}诊断 npm 缺失原因...${NC}"

    # Windows 上 npm.cmd 在 $env:ProgramFiles/nodejs/
    # 其他平台 npm 由 Node 自带不会缺失
    local npm_cmd_sh="$PROGRAMFILES/nodejs/npm.cmd"
    local npm_cli_js="$PROGRAMFILES/nodejs/node_modules/npm/bin/npm-cli.js"

    # 路径 1：检查 npm.cmd 是否真实存在
    if [ ! -f "$npm_cmd_sh" ]; then
        echo -e "  ${RED}✗${NC} npm.cmd 都不存在（$npm_cmd_sh 缺失）"
        echo -e "       Node.js 安装损坏，需要重装"
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} npm.cmd 存在：$npm_cmd_sh"

    # 路径 2：绕开 .ps1 shim 直接调 npm.cmd
    local ver
    ver=$("$npm_cmd_sh" --version 2>/dev/null)
    if [ -n "$ver" ]; then
        echo -e "  ${GREEN}✓${NC} 直接调 npm.cmd 可用（v$ver）—— 是 shell 把 npm.ps1 挡住了"
        # Git Bash / macOS / Linux 都不会卡 .ps1，直接可用
        if has_npm >/dev/null 2>&1; then
            return 0
        fi
        # Windows + Git Bash 罕见情况：手动加 PATH
        export PATH="$PROGRAMFILES/nodejs:$PATH"
        if has_npm >/dev/null 2>&1; then
            echo -e "       已把 $PROGRAMFILES/nodejs 加到 PATH"
            return 0
        fi
    fi

    # 路径 3：检查 npm-cli.js（npm 真正的入口）
    if [ ! -f "$npm_cli_js" ]; then
        echo -e "  ${RED}✗${NC} npm-cli.js 也不存在 —— Node.js 安装彻底损坏"
        echo -e "       需要用 winget / 重装 Node.js"
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} npm-cli.js 存在"

    # 路径 4：corepack --install-directory（不需要 admin，往用户目录写）
    if has_corepack >/dev/null 2>&1; then
        local install_dir="$LOCALAPPDATA/corepack"
        echo -e "  ${CYAN}尝试 corepack --install-directory $install_dir ...${NC}"
        if corepack enable pnpm --install-directory "$install_dir" >/dev/null 2>&1; then
            if command -v pnpm >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} pnpm 已通过 corepack 装到 $install_dir"
                echo -e "       （不需要 npm，可以装项目依赖）"
                return 0
            fi
        else
            echo -e "  ${YELLOW}corepack --install-directory 失败${NC}"
        fi
    fi

    echo -e "  ${RED}✗${NC} 所有自动修复路径都失败"
    return 1
}

# Node.js 缺失时的引导菜单（不自动装，符合"敏感动作要授权"原则）
action_install_node() {
    echo ""
    echo -e "${YELLOW}Node.js 是运行本项目的必备环境。请选择安装方式：${NC}"
    echo ""
    echo "  [1] 打开 Node.js 官网下载页（https://nodejs.org/）"
    if command -v winget >/dev/null 2>&1; then
        echo "  [2] 用 winget 自动装（需要管理员权限，仅 Windows）"
    fi
    echo "  [0] 返回（我自己搞定）"
    echo ""
    read -rp "请选择 [0-2]: " choice

    case "$choice" in
        1)
            if command -v xdg-open >/dev/null 2>&1; then
                xdg-open "https://nodejs.org/" >/dev/null 2>&1
            elif command -v open >/dev/null 2>&1; then
                open "https://nodejs.org/" >/dev/null 2>&1
            elif command -v start >/dev/null 2>&1; then
                start "" "https://nodejs.org/" >/dev/null 2>&1
            else
                echo -e "${RED}找不到浏览器启动命令${NC}"
                echo -e "请手动打开：${BLUE}https://nodejs.org/${NC}"
                return
            fi
            echo -e "${GREEN}已在默认浏览器打开下载页${NC}"
            ;;
        2)
            if command -v winget >/dev/null 2>&1; then
                echo -e "${CYAN}正在用 winget 安装 Node.js LTS（首次运行会弹 UAC 授权）...${NC}"
                winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
                echo ""
                echo -e "${YELLOW}提示：winget 装完后需要重新打开 Git Bash / PowerShell 让 PATH 生效${NC}"
                echo -e "      装好后回到本菜单再按一次 [1] 即可继续部署${NC}"
            else
                echo -e "${RED}本机没有 winget（Windows 10 旧版 / macOS / Linux 都没有）${NC}"
                echo -e "请手动下载安装：${BLUE}https://nodejs.org/${NC}"
            fi
            ;;
        0|"")
            echo -e "${YELLOW}已跳过 Node.js 安装${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

action_status() {
    # 纯只读状态检查（脚本启动时自动跑，不阻塞）
    echo -e "${CYAN}===== 部署状态检查 =====${NC}"
    echo ""

    # 1. Node.js
    if command -v node >/dev/null 2>&1; then
        local node_v
        node_v=$(node --version)
        echo -e "  ${GREEN}✓${NC} Node.js       $node_v"
    else
        echo -e "  ${RED}✗${NC} Node.js       未安装"
    fi

    # 2. npm（Node.js 通常自带，但部分安装方式可能缺失 npm）
    if command -v node >/dev/null 2>&1; then
        if has_npm >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} npm           $(npm_version)"
        else
            echo -e "  ${YELLOW}!${NC} npm           未安装（Node.js 存在但 npm 缺失，装包会走 corepack 兜底）"
        fi
    else
        echo -e "  ${GRAY}-${NC} npm           （跳过：Node.js 缺失）"
    fi

    # 3. corepack（Node 16.9+ 内置，不依赖 npm 也能装 pnpm）
    if command -v node >/dev/null 2>&1; then
        if has_corepack >/dev/null 2>&1; then
            echo -e "  ${GRAY}i${NC}  corepack      已可用（兜底包管理器安装）"
        else
            echo -e "  ${GRAY}i${NC}  corepack      不可用（Node 版本过低或 corepack 被禁用，装 pnpm 需用 npm）"
        fi
    else
        echo -e "  ${GRAY}-${NC} corepack      （跳过：Node.js 缺失）"
    fi

    # 4. pnpm
    if command -v node >/dev/null 2>&1; then
        if command -v pnpm >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} pnpm          $(pnpm --version)"
        else
            echo -e "  ${RED}✗${NC} pnpm          未安装"
        fi
    else
        echo -e "  ${GRAY}-${NC} pnpm          （跳过：Node.js 缺失）"
    fi

    # 5. express
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

    # 6. 入口文件
    if [ -f "api/index.js" ]; then
        echo -e "  ${GREEN}✓${NC} 入口文件      api/index.js"
    else
        echo -e "  ${RED}✗${NC} 入口文件      缺失（无法自动修复）"
    fi

    # 7. 资源目录
    if [ -d "assets" ]; then
        local mobi_size
        mobi_size=$(stat -c '%s' "assets/placeholder.mobi" 2>/dev/null || stat -f '%z' "assets/placeholder.mobi" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}✓${NC} 资源目录      assets/ (placeholder.mobi = ${mobi_size} 字节)"
    else
        echo -e "  ${RED}✗${NC} 资源目录      缺失（无法自动修复）"
    fi

    # 8. 端口
    local port
    port=$(get_port)
    if is_port_free "$port"; then
        echo -e "  ${GREEN}✓${NC} 端口空闲      $port 可绑定"
    else
        echo -e "  ${RED}✗${NC} 端口被占用    $port 已被其他程序占用"
    fi

    # 9. .env
    if [ -f "$ENV_FILE" ]; then
        echo -e "  ${GRAY}i${NC}  端口配置      ${BLUE}$ENV_FILE${NC}（已存在）"
    else
        echo -e "  ${GRAY}i${NC}  端口配置      ${BLUE}$ENV_FILE${NC}（未创建，运行时用默认 $DEFAULT_PORT）"
    fi

    echo ""
}

action_auto_deploy() {
    # 列出缺失项 → 二次确认 → 逐项装
    clear
    echo -e "${CYAN}===== 自动部署 =====${NC}"
    echo ""
    echo -e "${GRAY}正在扫描缺失组件...${NC}"
    echo ""

    local needs_node=false
    local needs_npm=false
    local needs_pnpm=false
    local needs_express=false
    local needs_index=false
    local needs_assets=false
    local has_corepack=false

    # 1. Node.js
    if command -v node >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Node.js       $(node --version)"
    else
        echo -e "  ${RED}✗${NC} Node.js       未安装"
        needs_node=true
    fi

    # 2. npm + corepack + pnpm + express
    if [ "$needs_node" = false ]; then
        # npm（Node.js 通常自带，但可能缺失）
        if has_npm >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} npm           $(npm_version)"
        else
            echo -e "  ${YELLOW}!${NC} npm           未安装（Node.js 存在但 npm 缺失）"
            needs_npm=true
        fi

        # corepack（Node 16.9+ 内置）
        if has_corepack >/dev/null 2>&1; then
            has_corepack=true
        fi

        # pnpm
        if command -v pnpm >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} pnpm          $(pnpm --version)"
        else
            echo -e "  ${RED}✗${NC} pnpm          未安装"
            needs_pnpm=true
        fi

        # express
        if [ -d "node_modules" ] && [ -f "node_modules/express/package.json" ]; then
            local expr_v
            expr_v=$(node -p "try{require('express/package.json').version}catch(e){'未安装'}" 2>/dev/null || echo "未安装")
            echo -e "  ${GREEN}✓${NC} express       $expr_v"
        else
            echo -e "  ${RED}✗${NC} express       未安装"
            needs_express=true
        fi
    else
        echo -e "  ${GRAY}-${NC} npm           （跳过：Node.js 缺失）"
        echo -e "  ${GRAY}-${NC} corepack      （跳过：Node.js 缺失）"
        echo -e "  ${GRAY}-${NC} pnpm          （跳过：Node.js 缺失）"
        echo -e "  ${GRAY}-${NC} express       （跳过：Node.js 缺失）"
    fi

    if [ -f "api/index.js" ]; then
        echo -e "  ${GREEN}✓${NC} 入口文件      api/index.js"
    else
        echo -e "  ${RED}✗${NC} 入口文件      缺失"
        needs_index=true
    fi

    if [ -d "assets" ]; then
        local mobi_size
        mobi_size=$(stat -c '%s' "assets/placeholder.mobi" 2>/dev/null || stat -f '%z' "assets/placeholder.mobi" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}✓${NC} 资源目录      assets/ (placeholder.mobi = ${mobi_size} 字节)"
    else
        echo -e "  ${RED}✗${NC} 资源目录      缺失"
        needs_assets=true
    fi

    echo ""

    # 没有缺失项就直接返回
    if [ "$needs_node" = false ] && [ "$needs_pnpm" = false ] && [ "$needs_express" = false ] && [ "$needs_index" = false ] && [ "$needs_assets" = false ]; then
        echo -e "${GREEN}所有组件都已就绪，无需部署。${NC}"
        echo ""
        press_enter
        return
    fi

    # 列出可执行的部署动作
    echo -e "${YELLOW}待部署项：${NC}"
    echo ""
    if [ "$needs_node" = true ]; then
        echo -e "  ${YELLOW}•${NC} Node.js  → 弹菜单让你选：打开官网 / winget 自动装"
    fi
    if [ "$needs_npm" = true ]; then
        echo -e "  ${YELLOW}•${NC} npm      → 智能修复（检查 npm.cmd → corepack --install-directory → 重装 Node.js）"
    fi
    if [ "$needs_pnpm" = true ]; then
        if [ "$has_corepack" = true ]; then
            echo -e "  ${YELLOW}•${NC} pnpm     → 自动 corepack prepare pnpm@latest --activate"
        elif has_npm >/dev/null 2>&1; then
            echo -e "  ${YELLOW}•${NC} pnpm     → 自动 npm install -g pnpm"
        else
            echo -e "  ${RED}•${NC} pnpm     → 无法自动装（缺 corepack 也缺 npm），需手动装 Node.js"
        fi
    fi
    if [ "$needs_express" = true ]; then
        echo -e "  ${YELLOW}•${NC} express  → 自动 pnpm install（兜底 npm install）"
    fi
    if [ "$needs_index" = true ]; then
        echo -e "  ${RED}•${NC} 入口文件 → ${RED}无法自动修复${NC}（请 git pull 或重新 fork）"
    fi
    if [ "$needs_assets" = true ]; then
        echo -e "  ${RED}•${NC} 资源目录 → ${RED}无法自动修复${NC}（请 git pull 或重新 fork）"
    fi

    echo ""
    echo -e "${YELLOW}确认开始部署？(Y/n)${NC}"
    read -rp "" confirm
    if [[ ! "$confirm" =~ ^[Yy]?$ ]] && [ -n "$confirm" ]; then
        echo -e "${YELLOW}已取消部署${NC}"
        press_enter
        return
    fi

    echo ""

    # 1. Node.js
    if [ "$needs_node" = true ]; then
        echo -e "${CYAN}--- 步骤 1: Node.js ---${NC}"
        action_install_node
        if command -v node >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Node.js 已可用 ($(node --version))${NC}"
            # 重新检测 npm 和 corepack（Node 装完后可能有了）
            has_npm >/dev/null 2>&1 && needs_npm=false || needs_npm=true
            has_corepack >/dev/null 2>&1 && has_corepack=true
        else
            echo -e "${YELLOW}! Node.js 仍未安装，停止后续步骤${NC}"
            press_enter
            return
        fi
        echo ""
    fi

    # 1.5. npm 智能修复（Node.js 存在但 npm 命令找不到）
    if [ "$needs_npm" = true ] && command -v node >/dev/null 2>&1; then
        echo -e "${CYAN}--- 步骤 1.5: 智能修复 npm ---${NC}"
        if repair_npm; then
            # 重新检测
            has_npm >/dev/null 2>&1 && needs_npm=false
        else
            # 最后兜底：弹二次确认用 winget 重装 Node.js（仅 Windows）
            if command -v winget >/dev/null 2>&1; then
                echo ""
                echo -e "  ${YELLOW}npm 自动修复失败，最后一招：用 winget 重装 Node.js（带 npm）${NC}"
                echo -e "  ${GRAY}这会覆盖当前 Node.js 安装（同样版本号），全局 npm 包会保留${NC}"
                read -rp "  确认重装 Node.js？(Y/n): " winget_confirm
                if [ -n "$winget_confirm" ] && [[ ! "$winget_confirm" =~ ^[Yy]?$ ]]; then
                    echo -e "  ${YELLOW}已跳过重装，请手动重装 Node.js：https://nodejs.org/${NC}"
                else
                    echo -e "  ${CYAN}正在用 winget 重装 Node.js（首次会弹 UAC 授权）...${NC}"
                    winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements --force
                    # 重装后 PATH 需要新开窗口才能刷新；用绝对路径测一下
                    local node_exe="$PROGRAMFILES/nodejs/node.exe"
                    if [ -f "$node_exe" ]; then
                        local ver
                        ver=$("$node_exe" --version 2>/dev/null)
                        echo -e "  ${GREEN}Node.js 已重装（$ver）${NC}"
                    fi
                    echo -e "  ${YELLOW}提示：winget 装完后需要重新打开 Git Bash / PowerShell 让 PATH 生效${NC}"
                fi
            else
                echo ""
                echo -e "  ${YELLOW}本机没有 winget，请手动重装 Node.js（选 LTS，自带 npm）：https://nodejs.org/${NC}"
            fi
            # 重装或不重装，统一让后续步骤尝试重连
            needs_npm=false
        fi
        echo ""
    fi

    # 2. pnpm（双路径：corepack 优先，npm 兜底）
    if [ "$needs_pnpm" = true ]; then
        echo -e "${CYAN}--- 步骤: pnpm ---${NC}"
        local pnpm_installed=false

        # 路径 A：corepack（Node 16.9+ 内置，不依赖 npm）
        if has_corepack >/dev/null 2>&1; then
            echo -e "${GRAY}  尝试 corepack 安装...${NC}"
            if corepack prepare pnpm@latest --activate >/dev/null 2>&1; then
                if command -v pnpm >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ pnpm 已通过 corepack 安装 ($(pnpm --version))${NC}"
                    pnpm_installed=true
                fi
            else
                echo -e "${YELLOW}  corepack 失败${NC}"
            fi
        fi

        # 路径 B：npm（传统方式，需要 npm）
        if [ "$pnpm_installed" = false ]; then
            if has_npm >/dev/null 2>&1; then
                echo -e "${GRAY}  尝试 npm 安装...${NC}"
                local npm_err
                npm_err=$(npm install -g pnpm 2>&1) || true
                if command -v pnpm >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ pnpm 已通过 npm 安装 ($(pnpm --version))${NC}"
                    pnpm_installed=true
                else
                    if echo "$npm_err" | grep -qiE 'EACCES|EPERM|permission'; then
                        echo -e "${RED}✗ 权限不足，无法全局安装 pnpm${NC}"
                        echo -e "       请在终端手动执行（可能需要 sudo）："
                    else
                        echo -e "${RED}✗ npm 安装 pnpm 失败：${npm_err}${NC}"
                    fi
                fi
            fi
        fi

        # 最终还是没装上
        if [ "$pnpm_installed" = false ]; then
            echo -e "  ${RED}✗ pnpm 自动安装失败，请手动执行以下任一命令：${NC}"
            echo -e "        ${CYAN}corepack prepare pnpm@latest --activate${NC}"
            echo -e "        ${CYAN}npm install -g pnpm${NC}"
            echo -e "        或重装 Node.js（自带 npm）：${BLUE}https://nodejs.org/${NC}"
        fi
        echo ""
    fi

    # 3. express（三路径：pnpm → npm → corepack→pnpm）
    if [ "$needs_express" = true ]; then
        echo -e "${CYAN}--- 步骤: express ---${NC}"
        local express_installed=false

        if command -v pnpm >/dev/null 2>&1; then
            echo -e "${GRAY}  尝试 pnpm install...${NC}"
            if pnpm install >/dev/null 2>&1; then
                local expr_v
                expr_v=$(node -p "try{require('express/package.json').version}catch(e){'未安装'}" 2>/dev/null || echo "未安装")
                echo -e "${GREEN}✓ express 已安装 ($expr_v，通过 pnpm)${NC}"
                express_installed=true
            else
                echo -e "${YELLOW}  pnpm install 失败${NC}"
            fi
        fi

        if [ "$express_installed" = false ] && has_npm >/dev/null 2>&1; then
            echo -e "${GRAY}  尝试 npm install...${NC}"
            if npm install >/dev/null 2>&1; then
                local expr_v
                expr_v=$(node -p "try{require('express/package.json').version}catch(e){'未安装'}" 2>/dev/null || echo "未安装")
                echo -e "${GREEN}✓ express 已安装 ($expr_v，通过 npm)${NC}"
                express_installed=true
            else
                echo -e "${YELLOW}  npm install 失败${NC}"
            fi
        fi

        if [ "$express_installed" = false ]; then
            echo -e "  ${RED}✗ express 安装失败，请手动执行：${NC}"
            echo -e "        ${CYAN}cd 到项目目录后，运行 pnpm install（或 npm install）${NC}"
            echo -e "        如 pnpm/npm 都不在，先执行：${CYAN}corepack prepare pnpm@latest --activate${NC}"
        fi
        echo ""
    fi

    echo -e "${CYAN}=== 部署完成，最新状态： ===${NC}"
    echo ""
    action_status
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
    echo ""

    # 列出本机所有非 loopback、非 link-local 的 IPv4 地址（Kindle 用内网 IP 访问）
    local ips
    ips=$(get_local_ips)
    if [ -n "$ips" ]; then
        echo -e "  Kindle 访问：浏览器打开以下任一地址"
        for ip in $ips; do
            echo -e "     ${CYAN}http://${ip}:${port}${NC}"
        done
    else
        echo -e "  ${YELLOW}⚠ 未检测到内网 IP，请手动运行 ipconfig 查看${NC}"
    fi

    echo ""
    echo -e "  关闭行为：${YELLOW}关闭此窗口 / Ctrl+C = 关闭服务${NC}"
    echo ""
    echo -e "${GRAY}3 秒后启动...（按 Ctrl+C 取消）${NC}"
    sleep 3

    # 依赖兜底：node_modules 缺失或损坏时自动安装
    if [ ! -d "node_modules" ] || [ ! -f "node_modules/express/package.json" ]; then
        echo -e "${YELLOW}检测到依赖缺失，自动安装...${NC}"

        local installed=false
        if command -v pnpm >/dev/null 2>&1; then
            pnpm install >/dev/null 2>&1 && installed=true
            [ "$installed" = true ] && echo -e "${GREEN}已通过 pnpm 安装依赖${NC}"
        fi
        if [ "$installed" = false ] && has_npm >/dev/null 2>&1; then
            npm install >/dev/null 2>&1 && installed=true
            [ "$installed" = true ] && echo -e "${GREEN}已通过 npm 安装依赖${NC}"
        fi
        if [ "$installed" = false ] && has_corepack >/dev/null 2>&1; then
            corepack prepare pnpm@latest --activate >/dev/null 2>&1 && \
            pnpm install >/dev/null 2>&1 && installed=true
            [ "$installed" = true ] && echo -e "${GREEN}已通过 corepack→pnpm 安装依赖${NC}"
        fi
        if [ "$installed" = false ]; then
            echo -e "${RED}依赖安装失败，请手动在项目目录执行 pnpm install 或 npm install${NC}"
            read -rp "按 Enter 键退出..." _
            exit 1
        fi
    fi

    # 前台启动 node；exec 让 bash 进程被 node 替换，
    # 关闭终端 / Ctrl+C 时 bash 退出 → node 退出 → 端口释放。
    export PORT="$port"
    exec node api/index.js
}

action_uninstall() {
    clear
    echo -e "${CYAN}===== 卸载指南 =====${NC}"
    echo ""
    echo -e "${GRAY}本项目用完即丢，依赖（express 等 67 个包）全部装在 node_modules 里。${NC}"
    echo -e "${GRAY}删项目文件夹就能清掉项目依赖，Node.js 和 pnpm 不受任何影响。${NC}"
    echo ""
    echo -e "${YELLOW}按需选择要执行的步骤（步骤 1 是必须的，2-4 是可选）：${NC}"
    echo ""
    echo -e "  1) 删除项目文件夹（必做）"
    echo -e "       项目依赖（express 等）会一起清掉"
    echo -e "       ${GRAY}本项目路径：$(pwd)${NC}"
    echo ""
    echo -e "       PowerShell:"
    echo -e "         ${CYAN}Remove-Item -Recurse -Force \"$(pwd)\"${NC}"
    echo -e "       cmd:"
    echo -e "         ${CYAN}rmdir /s /q \"$(pwd)\"${NC}"
    echo -e "       Mac/Linux (bash):"
    echo -e "         ${CYAN}rm -rf \"$(pwd)\"${NC}"
    echo ""
    echo -e "  2) （可选）清理 pnpm 全局缓存"
    echo -e "       ${CYAN}pnpm store prune${NC}"
    echo -e "       ${GRAY}（如不需要 pnpm 可跳过，电脑里若有其他 pnpm 项目则不要执行）${NC}"
    echo ""
    echo -e "  3) （可选）卸 pnpm 本身"
    echo -e "       ${CYAN}npm uninstall -g pnpm${NC}"
    echo ""
    echo -e "  4) （可选）卸 Node.js 本身"
    echo -e "       ${GRAY}Windows: 控制面板 → 程序 → 卸载 Node.js${NC}"
    echo -e "       ${GRAY}Mac:    brew uninstall node   或   官网卸载工具${NC}"
    echo -e "       ${GRAY}Linux:  sudo apt remove nodejs   (按你的发行版)${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠ 步骤 3 和 4 只在电脑不再需要 Node.js / pnpm 时才做${NC}"
    echo -e "     ${YELLOW}否则会破坏其他 Node.js 项目的开发环境${NC}"
    echo ""
    press_enter
}

# ---------- 启动时显示一次标题 ----------
echo -e "${CYAN}=================================${NC}"
echo -e "${CYAN}  Winterbreak2 一键管理部署脚本${NC}"
echo -e "${CYAN}=================================${NC}"
echo ""

# ---------- 启动时自动跑一次状态检查（只读、不阻塞） ----------
action_status

# ---------- 主菜单 ----------

while true; do
    port=$(get_port)
    echo -e "  当前端口：${YELLOW}$port${NC}"
    echo ""
    echo "  [1] 自动部署"
    echo "  [2] 修改运行端口"
    echo "  [3] 本机运行网页"
    echo "  [4] 卸载指南"
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
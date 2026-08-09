# =============================================================================
#  Winterbreak2 一键管理脚本 (Windows PowerShell)
# =============================================================================
#  功能菜单：
#    [1] 部署状态检查  —— 检查 Node / 依赖 / 端口
#    [2] 修改运行端口  —— 交互式改端口并写入 .env
#    [3] 运行服务      —— 前台启动 node api/index.js（关闭窗口即关服务）
#    [0] 退出
#
#  用法：在 PowerShell 里 cd 到本目录后输入 .\manage.ps1
#        或右键 manage.ps1 → "用 PowerShell 运行"
#
#  编码：本文件用 UTF-8 with BOM 保存（PowerShell 原生识别，无 BOM 冲突）
# =============================================================================

# 强制所有 Write-Host 输出按 UTF-8 编码（解决中文 Windows 默认 GBK 导致的乱码）
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$EnvFile = Join-Path $ScriptDir '.env'
$DefaultPort = 3000

# ---------- 工具函数 ----------

function Get-Port {
    if (Test-Path $EnvFile) {
        $content = Get-Content $EnvFile -Raw -ErrorAction SilentlyContinue
        if ($content -match 'PORT=(\d+)') {
            return [int]$Matches[1]
        }
    }
    return $DefaultPort
}

function Test-PortFree {
    param([int]$Port)
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Get-LocalIPs {
    # 列出本机所有非 loopback、非 link-local 的 IPv4 地址
    # 排除：127.0.0.1（loopback）、169.254.x.x（APIPA，未分配到 DHCP 的虚拟网卡）、
    #       Hyper-V/VMware/Docker/WSL 等虚拟接口
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $ip = $_.IPAddress.ToString()
            $ip -ne '127.0.0.1' -and
            -not $ip.StartsWith('169.254.') -and
            $_.InterfaceAlias -notmatch 'Loopback|Hyper-V|VMware|Docker|WSL|vEthernet|Loopback Pseudo-Interface'
        } |
        ForEach-Object { $_.IPAddress.ToString() }
}

# 跨平台 npm 检测（PS 默认能找 npm.ps1 / npm.cmd，但路径乱时 fallback）
function Test-NpmAvailable {
    if (Get-Command npm -ErrorAction SilentlyContinue) { return $true }
    if (Get-Command npm.cmd -ErrorAction SilentlyContinue) { return $true }
    # 用 Get-Command -All 查全部，找不到再 fallback
    $all = Get-Command npm -All -ErrorAction SilentlyContinue
    if ($all) { return $true }
    return $false
}

# 同上，corepack 检测
function Test-CorepackAvailable {
    if (Get-Command corepack -ErrorAction SilentlyContinue) { return $true }
    if (Get-Command corepack.cmd -ErrorAction SilentlyContinue) { return $true }
    return $false
}

# ---------- 菜单项 ----------

# npm 智能修复（Node.js 存在但 npm 命令找不到时）
# 常见原因：PowerShell 执行策略挡 .ps1 shim、npm-cli.js 缺失、多次重装残留
# 4 级修复路径：执行策略 → 绕开 shim 直调 npm.cmd → 检查 npm-cli.js → corepack --install-directory
function Repair-Npm {
    # 调用前 caller 已确认 node 存在、npm 缺失
    Write-Host ''
    Write-Host '诊断 npm 缺失原因...' -ForegroundColor Cyan

    # 路径 1：检查 npm.cmd 是否真实存在
    $npmCmd = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
    if (-not (Test-Path $npmCmd)) {
        Write-Host '  [X]  npm.cmd 都不存在 ($env:ProgramFiles\nodejs\npm.cmd 缺失)' -ForegroundColor Red
        Write-Host '       Node.js 安装损坏，需要重装' -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [OK] npm.cmd 存在：$npmCmd" -ForegroundColor Green

    # 路径 2：绕开 .ps1 shim，直接调 npm.cmd
    try {
        $ver = & "$npmCmd" --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] 直接调 npm.cmd 可用（v$ver）—— 是 PowerShell 执行策略挡了 npm.ps1" -ForegroundColor Green
            # 自动给当前进程放开执行策略
            try {
                Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
                Write-Host '       已临时放开当前 PowerShell 进程的执行策略' -ForegroundColor Green
                # 重新检测 npm
                $recheck = Get-Command npm -ErrorAction SilentlyContinue
                if ($recheck) {
                    Write-Host "  [OK] npm 现在可用了 ($(npm --version))" -ForegroundColor Green
                    return $true
                }
            } catch {
                Write-Host "       执行策略放开失败：$_" -ForegroundColor Yellow
            }
        }
    } catch {}

    # 路径 3：检查 npm-cli.js（npm 真正的入口）
    $npmCliJs = Join-Path $env:ProgramFiles 'nodejs\node_modules\npm\bin\npm-cli.js'
    if (-not (Test-Path $npmCliJs)) {
        Write-Host "  [X]  npm-cli.js 也不存在 —— Node.js 安装彻底损坏" -ForegroundColor Red
        Write-Host "       需要用 winget 重装 Node.js" -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [OK] npm-cli.js 存在" -ForegroundColor Green

    # 路径 4：corepack --install-directory（不需要 admin，往用户目录写）
    $cp = Get-Command corepack -ErrorAction SilentlyContinue
    if ($cp) {
        $installDir = Join-Path $env:LOCALAPPDATA 'corepack'
        Write-Host "  尝试 corepack --install-directory $installDir ..." -ForegroundColor Cyan
        try {
            $null = corepack enable pnpm --install-directory "$installDir" 2>&1
            if (Get-Command pnpm -ErrorAction SilentlyContinue) {
                Write-Host "  [OK] pnpm 已通过 corepack 装到 $installDir" -ForegroundColor Green
                Write-Host "       （不需要 npm，可以装项目依赖）" -ForegroundColor Green
                # 但 express 安装仍可能需要 npm 或 pnpm；pnpm 装好已经够用
                return $true
            }
        } catch {
            Write-Host "  corepack --install-directory 失败：$_" -ForegroundColor Yellow
        }
    }

    Write-Host '  [X]  所有自动修复路径都失败' -ForegroundColor Red
    return $false
}

# Node.js 缺失时的引导菜单（不自动装，符合"敏感动作要授权"原则）
function Install-NodeJsInteractive {
    Write-Host ''
    Write-Host 'Node.js 是运行本项目的必备环境。请选择安装方式：' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  [1] 打开 Node.js 官网下载页（https://nodejs.org/）'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host '  [2] 用 winget 自动装（需要管理员权限，仅 Windows）'
    }
    Write-Host '  [0] 返回（我自己搞定）'
    Write-Host ''
    $choice = Read-Host '请选择 [0-2]'

    switch ($choice) {
        '1' {
            try {
                Start-Process 'https://nodejs.org/'
                Write-Host '已在默认浏览器打开下载页' -ForegroundColor Green
            } catch {
                Write-Host "找不到浏览器启动命令" -ForegroundColor Red
                Write-Host '请手动打开: https://nodejs.org/' -ForegroundColor Blue
            }
        }
        '2' {
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Write-Host '正在用 winget 安装 Node.js LTS（首次运行会弹 UAC 授权）...' -ForegroundColor Cyan
                winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
                Write-Host ''
                Write-Host '提示：winget 装完后需要重新打开 PowerShell 让 PATH 生效' -ForegroundColor Yellow
                Write-Host '      装好后回到本菜单再按一次 [1] 即可继续部署' -ForegroundColor Yellow
            } else {
                Write-Host '本机没有 winget（Windows 10 旧版 / macOS / Linux 都没有）' -ForegroundColor Red
                Write-Host '请手动下载安装：https://nodejs.org/' -ForegroundColor Blue
            }
        }
        default {
            Write-Host '已跳过 Node.js 安装' -ForegroundColor Yellow
        }
    }
}

function Show-Status {
    # 纯只读状态检查（脚本启动时自动跑，不阻塞）
    Write-Host '===== 部署状态检查 =====' -ForegroundColor Cyan
    Write-Host ''

    # 1. Node.js
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $nodeVer = node --version
        Write-Host "  [OK] Node.js       $nodeVer" -ForegroundColor Green
    } else {
        Write-Host '  [X]  Node.js       未安装' -ForegroundColor Red
    }

    # 2. npm（Node.js 通常自带，但部分安装方式可能缺失 npm）
    if ($node) {
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
        if ($npmCmd) {
            Write-Host "  [OK] npm           $(npm --version)" -ForegroundColor Green
        } else {
            Write-Host '  [!]  npm           未安装（Node.js 存在但 npm 缺失，装包会走 corepack 兜底）' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  [-]  npm           （跳过：Node.js 缺失）' -ForegroundColor Gray
    }

    # 3. corepack（Node 16.9+ 内置，不依赖 npm 也能装 pnpm）
    if ($node) {
        $cp = Get-Command corepack -ErrorAction SilentlyContinue
        if ($cp) {
            Write-Host '  [i]  corepack      已可用（兜底包管理器安装）' -ForegroundColor Gray
        } else {
            Write-Host '  [i]  corepack      不可用（Node 版本过低或 corepack 被禁用，装 pnpm 需用 npm）' -ForegroundColor Gray
        }
    } else {
        Write-Host '  [-]  corepack      （跳过：Node.js 缺失）' -ForegroundColor Gray
    }

    # 4. pnpm
    if ($node) {
        $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($pnpm) {
            Write-Host "  [OK] pnpm          $(pnpm --version)" -ForegroundColor Green
        } else {
            Write-Host '  [X]  pnpm          未安装' -ForegroundColor Red
        }
    } else {
        Write-Host '  [-]  pnpm          （跳过：Node.js 缺失）' -ForegroundColor Gray
    }

    # 5. express
    if ($node) {
        $expressPath = Join-Path $ScriptDir 'node_modules\express\package.json'
        if (Test-Path $expressPath) {
            $expressVer = (Get-Content $expressPath -Raw | ConvertFrom-Json).version
            Write-Host "  [OK] express       $expressVer" -ForegroundColor Green
        } else {
            Write-Host '  [X]  express       未安装' -ForegroundColor Red
        }
    } else {
        Write-Host '  [-]  express       （跳过：Node.js 缺失）' -ForegroundColor Gray
    }

    # 6. 入口文件
    $indexPath = Join-Path $ScriptDir 'api\index.js'
    if (Test-Path $indexPath) {
        Write-Host '  [OK] 入口文件      api\index.js' -ForegroundColor Green
    } else {
        Write-Host '  [X]  入口文件      缺失（无法自动修复）' -ForegroundColor Red
    }

    # 7. 资源目录
    $mobiPath = Join-Path $ScriptDir 'assets\placeholder.mobi'
    if (Test-Path $mobiPath) {
        $mobiSize = (Get-Item $mobiPath).Length
        Write-Host "  [OK] 资源目录      assets\ (placeholder.mobi = $mobiSize 字节)" -ForegroundColor Green
    } else {
        Write-Host '  [X]  资源目录      缺失（无法自动修复）' -ForegroundColor Red
    }

    # 8. 端口
    if (Test-PortFree (Get-Port)) {
        $port = Get-Port
        Write-Host "  [OK] 端口空闲      $port 可绑定" -ForegroundColor Green
    } else {
        $port = Get-Port
        Write-Host "  [X]  端口被占用    $port 已被其他程序占用" -ForegroundColor Red
    }

    # 9. .env
    if (Test-Path $EnvFile) {
        Write-Host "  [i]  端口配置      .env（已存在）" -ForegroundColor Gray
    } else {
        Write-Host "  [i]  端口配置      .env（未创建，运行时用默认 $DefaultPort）" -ForegroundColor Gray
    }

    Write-Host ''
}

function Show-AutoDeploy {
    # 列出缺失项 → 二次确认 → 逐项装
    Clear-Host
    Write-Host '===== 自动部署 =====' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '正在扫描缺失组件...' -ForegroundColor Gray
    Write-Host ''

    $needsNode = $false
    $needsNpm = $false
    $needsPnpm = $false
    $needsExpress = $false
    $needsIndex = $false
    $needsAssets = $false
    $hasCorepack = $false

    # 1. Node.js
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        Write-Host "  [OK] Node.js       $(node --version)" -ForegroundColor Green
    } else {
        Write-Host '  [X]  Node.js       未安装' -ForegroundColor Red
        $needsNode = $true
    }

    # 2. npm + corepack + pnpm / express
    if (-not $needsNode) {
        # npm（Node.js 通常自带，但可能缺失）
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
        if ($npmCmd) {
            Write-Host "  [OK] npm           $(npm --version)" -ForegroundColor Green
        } else {
            Write-Host '  [!]  npm           未安装（Node.js 有但 npm 缺失）' -ForegroundColor Yellow
            $needsNpm = $true
        }

        # corepack（Node 16.9+ 内置）
        $cp = Get-Command corepack -ErrorAction SilentlyContinue
        if ($cp) {
            $hasCorepack = $true
        }

        # pnpm
        $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($pnpm) {
            Write-Host "  [OK] pnpm          $(pnpm --version)" -ForegroundColor Green
        } else {
            Write-Host '  [X]  pnpm          未安装' -ForegroundColor Red
            $needsPnpm = $true
        }

        # express
        $expressPath = Join-Path $ScriptDir 'node_modules\express\package.json'
        if (Test-Path $expressPath) {
            $expressVer = (Get-Content $expressPath -Raw | ConvertFrom-Json).version
            Write-Host "  [OK] express       $expressVer" -ForegroundColor Green
        } else {
            Write-Host '  [X]  express       未安装' -ForegroundColor Red
            $needsExpress = $true
        }
    } else {
        Write-Host '  [-]  npm           （跳过：Node.js 缺失）' -ForegroundColor Gray
        Write-Host '  [-]  corepack      （跳过：Node.js 缺失）' -ForegroundColor Gray
        Write-Host '  [-]  pnpm          （跳过：Node.js 缺失）' -ForegroundColor Gray
        Write-Host '  [-]  express       （跳过：Node.js 缺失）' -ForegroundColor Gray
    }

    # 入口文件
    $indexPath = Join-Path $ScriptDir 'api\index.js'
    if (Test-Path $indexPath) {
        Write-Host '  [OK] 入口文件      api\index.js' -ForegroundColor Green
    } else {
        Write-Host '  [X]  入口文件      缺失' -ForegroundColor Red
        $needsIndex = $true
    }

    # 资源目录
    $mobiPath = Join-Path $ScriptDir 'assets\placeholder.mobi'
    if (Test-Path $mobiPath) {
        $mobiSize = (Get-Item $mobiPath).Length
        Write-Host "  [OK] 资源目录      assets\ (placeholder.mobi = $mobiSize 字节)" -ForegroundColor Green
    } else {
        Write-Host '  [X]  资源目录      缺失' -ForegroundColor Red
        $needsAssets = $true
    }

    Write-Host ''

    # 没有缺失项
    if (-not $needsNode -and -not $needsPnpm -and -not $needsExpress -and -not $needsIndex -and -not $needsAssets) {
        Write-Host '所有组件都已就绪，无需部署。' -ForegroundColor Green
        Write-Host ''
        Read-Host '按 Enter 键返回菜单'
        return
    }

    # 列出可执行的部署动作
    Write-Host '待部署项：' -ForegroundColor Yellow
    Write-Host ''
    if ($needsNode) {
        Write-Host '  [•] Node.js  → 弹菜单让你选：打开官网 / winget 自动装' -ForegroundColor Yellow
    }
    if ($needsNpm) {
        Write-Host '  [•] npm      → 智能修复（执行策略 → corepack --install-directory → 重装 Node.js）' -ForegroundColor Yellow
    }
    if ($needsPnpm) {
        if ($hasCorepack) {
            Write-Host '  [•] pnpm     → 自动 corepack prepare pnpm@latest --activate' -ForegroundColor Yellow
        } elseif ($npmCmd) {
            Write-Host '  [•] pnpm     → 自动 npm install -g pnpm' -ForegroundColor Yellow
        } else {
            Write-Host '  [•] pnpm     → 无法自动装（缺 corepack 也缺 npm），需手动装 Node.js' -ForegroundColor Red
        }
    }
    if ($needsExpress) {
        Write-Host '  [•] express  → 自动 pnpm install（兜底 npm install）' -ForegroundColor Yellow
    }
    if ($needsIndex) {
        Write-Host '  [•] 入口文件 → 无法自动修复（请 git pull 或重新 fork）' -ForegroundColor Red
    }
    if ($needsAssets) {
        Write-Host '  [•] 资源目录 → 无法自动修复（请 git pull 或重新 fork）' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '确认开始部署？(Y/n)' -ForegroundColor Yellow
    $confirm = Read-Host ''
    if ($confirm -and $confirm -notmatch '^[Yy]?$') {
        Write-Host '已取消部署' -ForegroundColor Yellow
        Read-Host '按 Enter 键返回菜单'
        return
    }

    Write-Host ''

    # 1. Node.js
    if ($needsNode) {
        Write-Host '--- 步骤 1: Node.js ---' -ForegroundColor Cyan
        Install-NodeJsInteractive
        $node = Get-Command node -ErrorAction SilentlyContinue
        if ($node) {
            Write-Host "Node.js 已可用 ($(node --version))" -ForegroundColor Green
            # 重新检测 npm 和 corepack（Node 装完后可能有了）
            if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { $needsNpm = $true } else { $needsNpm = $false }
            if (Get-Command corepack -ErrorAction SilentlyContinue) { $hasCorepack = $true }
        } else {
            Write-Host 'Node.js 仍未安装，停止后续步骤' -ForegroundColor Yellow
            Read-Host '按 Enter 键返回菜单'
            return
        }
        Write-Host ''
    }

    # 1.5. npm 智能修复（Node.js 存在但 npm 命令找不到）
    if ($needsNpm -and (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Host '--- 步骤 1.5: 智能修复 npm ---' -ForegroundColor Cyan
        $repaired = Repair-Npm
        if ($repaired) {
            # 重新检测
            $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
            if ($npmCmd) { $needsNpm = $false }
        } else {
            # 最后兜底：弹二次确认用 winget 重装 Node.js
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Write-Host ''
                Write-Host '  npm 自动修复失败，最后一招：用 winget 重装 Node.js（带 npm）' -ForegroundColor Yellow
                Write-Host '  这会覆盖当前 Node.js 安装（同样版本号），所有全局 npm 包会保留' -ForegroundColor Gray
                $wingetConfirm = Read-Host '  确认重装 Node.js？(Y/n)'
                if ($wingetConfirm -and $wingetConfirm -notmatch '^[Yy]?$') {
                    Write-Host '  已跳过重装，请手动重装 Node.js：https://nodejs.org/' -ForegroundColor Yellow
                } else {
                    Write-Host '  正在用 winget 重装 Node.js（首次会弹 UAC 授权）...' -ForegroundColor Cyan
                    winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements --force
                    # 重装后 PATH 需要新开窗口才能刷新；强制让 node/npm 走绝对路径再测
                    $nodeExe = Join-Path $env:ProgramFiles 'nodejs\node.exe'
                    if (Test-Path $nodeExe) {
                        $ver = & "$nodeExe" --version 2>&1
                        Write-Host "  Node.js 已重装（$ver）" -ForegroundColor Green
                    }
                    Write-Host '  提示：winget 装完后需要重新打开 PowerShell 让 PATH 生效' -ForegroundColor Yellow
                }
            } else {
                Write-Host ''
                Write-Host '  本机没有 winget，请手动重装 Node.js（选 LTS，自带 npm）：https://nodejs.org/' -ForegroundColor Yellow
            }
            # 重装或不重装，统一让后续步骤尝试重连
            $needsNpm = $false
        }
        Write-Host ''
    }

    # 2. pnpm（双路径：corepack 优先，npm 兜底）
    if ($needsPnpm) {
        Write-Host '--- 步骤: pnpm ---' -ForegroundColor Cyan
        $pnpmInstalled = $false

        # 路径 A：corepack（Node 16.9+ 内置，不依赖 npm）
        $cp = Get-Command corepack -ErrorAction SilentlyContinue
        if ($cp) {
            try {
                Write-Host '  尝试 corepack 安装...' -ForegroundColor Gray
                $null = corepack prepare pnpm@latest --activate 2>&1
                if (Get-Command pnpm -ErrorAction SilentlyContinue) {
                    Write-Host "  [OK] pnpm 已通过 corepack 安装 ($(pnpm --version))" -ForegroundColor Green
                    $pnpmInstalled = $true
                }
            } catch {
                Write-Host "  corepack 失败：$_" -ForegroundColor Yellow
            }
        }

        # 路径 B：npm（传统方式）
        if (-not $pnpmInstalled) {
            $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
            if ($npmCmd) {
                try {
                    Write-Host '  尝试 npm 安装...' -ForegroundColor Gray
                    $null = npm install -g pnpm 2>&1
                    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
                        Write-Host "  [OK] pnpm 已通过 npm 安装 ($(pnpm --version))" -ForegroundColor Green
                        $pnpmInstalled = $true
                    }
                } catch {
                    $errMsg = "$_"
                    if ($errMsg -match 'EACCES|EPERM|permission') {
                        Write-Host '  [X]  权限不足，无法全局安装 pnpm' -ForegroundColor Red
                        Write-Host '       请在终端手动执行（可能需要 sudo）：' -ForegroundColor Yellow
                    } else {
                        Write-Host "  [X]  npm 安装 pnpm 失败：$errMsg" -ForegroundColor Red
                    }
                }
            }
        }

        # 最终还是没装上
        if (-not $pnpmInstalled) {
            Write-Host '  [X]  pnpm 自动安装失败，请手动执行以下任一命令：' -ForegroundColor Red
            Write-Host '        corepack prepare pnpm@latest --activate' -ForegroundColor Cyan
            Write-Host '        npm install -g pnpm' -ForegroundColor Cyan
            Write-Host '        或重装 Node.js（自带 npm）：https://nodejs.org/' -ForegroundColor Cyan
        }
        Write-Host ''
    }

    # 3. express（三路径：pnpm → npm → corepack→pnpm）
    if ($needsExpress) {
        Write-Host '--- 步骤: express ---' -ForegroundColor Cyan
        $expressInstalled = $false

        $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue

        if ($pnpmCmd) {
            try {
                Write-Host '  尝试 pnpm install...' -ForegroundColor Gray
                $null = pnpm install 2>&1
                $expressPath = Join-Path $ScriptDir 'node_modules\express\package.json'
                if (Test-Path $expressPath) {
                    $expressVer = (Get-Content $expressPath -Raw | ConvertFrom-Json).version
                    Write-Host "  [OK] express 已安装 ($expressVer，通过 pnpm)" -ForegroundColor Green
                    $expressInstalled = $true
                }
            } catch {
                Write-Host "  pnpm install 失败：$_" -ForegroundColor Yellow
            }
        }

        if (-not $expressInstalled -and $npmCmd) {
            try {
                Write-Host '  尝试 npm install...' -ForegroundColor Gray
                $null = npm install 2>&1
                $expressPath = Join-Path $ScriptDir 'node_modules\express\package.json'
                if (Test-Path $expressPath) {
                    $expressVer = (Get-Content $expressPath -Raw | ConvertFrom-Json).version
                    Write-Host "  [OK] express 已安装 ($expressVer，通过 npm)" -ForegroundColor Green
                    $expressInstalled = $true
                }
            } catch {
                Write-Host "  npm install 失败：$_" -ForegroundColor Yellow
            }
        }

        if (-not $expressInstalled) {
            Write-Host '  [X]  express 安装失败，请手动执行：' -ForegroundColor Red
            Write-Host '        cd 到项目目录后，运行 pnpm install（或 npm install）' -ForegroundColor Cyan
            Write-Host '        如 pnpm/npm 都不在，先执行：corepack prepare pnpm@latest --activate' -ForegroundColor Cyan
        }
        Write-Host ''
    }

    Write-Host '=== 部署完成，最新状态： ===' -ForegroundColor Cyan
    Write-Host ''
    Show-Status
    Read-Host '按 Enter 键返回菜单'
}

function Show-Uninstall {
    Clear-Host
    Write-Host '===== 卸载指南 =====' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '本项目用完即丢，依赖（express 等 67 个包）全部装在 node_modules 里。' -ForegroundColor Gray
    Write-Host '删项目文件夹就能清掉项目依赖，Node.js 和 pnpm 不受任何影响。' -ForegroundColor Gray
    Write-Host ''
    Write-Host '按需选择要执行的步骤（步骤 1 是必须的，2-4 是可选）：' -ForegroundColor Yellow
    Write-Host ''

    Write-Host '  1) 删除项目文件夹（必做）' -ForegroundColor White
    Write-Host '       项目依赖（express 等）会一起清掉' -ForegroundColor Gray
    Write-Host "       本项目路径：$ScriptDir" -ForegroundColor Gray
    Write-Host ''
    Write-Host '       PowerShell:' -ForegroundColor Gray
    Write-Host "         Remove-Item -Recurse -Force `"$ScriptDir`"" -ForegroundColor Cyan
    Write-Host '       cmd:' -ForegroundColor Gray
    Write-Host "         rmdir /s /q `"$ScriptDir`"" -ForegroundColor Cyan
    Write-Host '       Mac/Linux (bash):' -ForegroundColor Gray
    Write-Host "         rm -rf `"$ScriptDir`"" -ForegroundColor Cyan
    Write-Host ''

    Write-Host '  2) （可选）清理 pnpm 全局缓存' -ForegroundColor White
    Write-Host '       pnpm store prune' -ForegroundColor Cyan
    Write-Host "       （如不需要 pnpm 可跳过，电脑里若有其他 pnpm 项目则不要执行）" -ForegroundColor Gray
    Write-Host ''

    Write-Host '  3) （可选）卸 pnpm 本身' -ForegroundColor White
    Write-Host '       npm uninstall -g pnpm' -ForegroundColor Cyan
    Write-Host ''

    Write-Host '  4) （可选）卸 Node.js 本身' -ForegroundColor White
    Write-Host '       Windows: 控制面板 → 程序 → 卸载 Node.js' -ForegroundColor Gray
    Write-Host '       Mac:    brew uninstall node   或   官网卸载工具' -ForegroundColor Gray
    Write-Host '       Linux:  sudo apt remove nodejs   (按你的发行版)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  ⚠ 步骤 3 和 4 只在电脑不再需要 Node.js / pnpm 时才做' -ForegroundColor Yellow
    Write-Host '     否则会破坏其他 Node.js 项目的开发环境' -ForegroundColor Yellow
    Write-Host ''

    Read-Host '按 Enter 键返回菜单'
}

function Change-Port {
    Clear-Host
    Write-Host '===== 修改运行端口 =====' -ForegroundColor Cyan
    $current = Get-Port
    Write-Host ''
    Write-Host "  当前端口：$current" -ForegroundColor Yellow
    Write-Host '  监听地址：http://0.0.0.0:<新端口>' -ForegroundColor Blue
    Write-Host ''
    $newPort = Read-Host '请输入新端口（1-65535，留空取消）'

    if ([string]::IsNullOrWhiteSpace($newPort)) {
        Write-Host '已取消' -ForegroundColor Yellow
        Read-Host '按 Enter 键返回菜单'
        return
    }

    # 数字校验
    if ($newPort -notmatch '^\d+$') {
        Write-Host '错误：端口必须是纯数字' -ForegroundColor Red
        Read-Host '按 Enter 键返回菜单'
        return
    }

    $newPortInt = [int]$newPort
    if ($newPortInt -lt 1 -or $newPortInt -gt 65535) {
        Write-Host '错误：端口范围 1-65535' -ForegroundColor Red
        Read-Host '按 Enter 键返回菜单'
        return
    }

    # 端口占用检查
    if (-not (Test-PortFree $newPortInt)) {
        Write-Host "错误：端口 $newPortInt 已被占用" -ForegroundColor Red
        Read-Host '按 Enter 键返回菜单'
        return
    }

    # 写 .env（用 .NET API 强制无 BOM；PowerShell 5.1 的 Set-Content -Encoding UTF8 会加 BOM，
    # 会导致 grep '^PORT=' 这种锚点正则失败）
    [System.IO.File]::WriteAllText($EnvFile, "PORT=$newPort", (New-Object System.Text.UTF8Encoding $false))
    Write-Host "[OK] 已将端口设置为 $newPort（写入 .env）" -ForegroundColor Green
    Read-Host '按 Enter 键返回菜单'
}

function Start-Service {
    Clear-Host
    $port = Get-Port
    Write-Host '===== 启动服务 =====' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  监听地址：http://0.0.0.0:$port" -ForegroundColor Blue

    # 列出本机所有非 loopback 的 IPv4 地址（Kindle 用内网 IP 访问）
    $ips = @(Get-LocalIPs)
    if ($ips.Count -gt 0) {
        Write-Host ''
        Write-Host '  Kindle 访问：浏览器打开以下任一地址' -ForegroundColor Cyan
        foreach ($ip in $ips) {
            Write-Host "     http://${ip}:$port" -ForegroundColor Cyan
        }
    } else {
        Write-Host ''
        Write-Host '  ⚠ 未检测到内网 IP，请手动运行 ipconfig 查看' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  关闭行为：关闭此窗口 / Ctrl+C = 关闭服务' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '3 秒后启动...（按 Ctrl+C 取消）' -ForegroundColor Gray
    Start-Sleep -Seconds 3

    # 依赖兜底：node_modules 缺失或损坏时自动安装
    $nmPath = Join-Path $ScriptDir 'node_modules'
    $expressPkg = Join-Path $nmPath 'express\package.json'
    if (-not (Test-Path $expressPkg)) {
        Write-Host '检测到依赖缺失，自动安装...' -ForegroundColor Yellow

        $installed = $false
        $pm = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($pm) {
            try { $null = pnpm install 2>&1; if (Test-Path $expressPkg) { $installed = $true; Write-Host '已通过 pnpm 安装依赖' -ForegroundColor Green } } catch {}
        }
        if (-not $installed) {
            $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
            if ($npmCmd) {
                try { $null = npm install 2>&1; if (Test-Path $expressPkg) { $installed = $true; Write-Host '已通过 npm 安装依赖' -ForegroundColor Green } } catch {}
            }
        }
        if (-not $installed) {
            $cp = Get-Command corepack -ErrorAction SilentlyContinue
            if ($cp) {
                try {
                    $null = corepack prepare pnpm@latest --activate 2>&1
                    $null = pnpm install 2>&1
                    if (Test-Path $expressPkg) { $installed = $true; Write-Host '已通过 corepack→pnpm 安装依赖' -ForegroundColor Green }
                } catch {}
            }
        }
        if (-not $installed) {
            Write-Host '依赖安装失败，请手动在项目目录执行 pnpm install 或 npm install' -ForegroundColor Red
            Read-Host '按 Enter 键退出'
            return
        }
    }

    # 前台启动 node；关闭 PowerShell 窗口 = 关闭 node 进程 = 端口释放
    $env:PORT = $port
    node (Join-Path $ScriptDir 'api\index.js')
}

# ---------- 主菜单（仅在脚本被直接运行时执行，dot-source 时跳过） ----------

if ($MyInvocation.InvocationName -eq $MyInvocation.MyCommand.Path -or
    $MyInvocation.InvocationName -eq '&') {
    # 启动时显示一次标题
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host '  Winterbreak2 一键管理部署脚本' -ForegroundColor Cyan
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host ''

    # 启动时自动跑一次状态检查（只读、不阻塞）
    Show-Status

    while ($true) {
        $port = Get-Port
        Write-Host "  当前端口：$port" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  [1] 自动部署'
        Write-Host '  [2] 修改运行端口'
        Write-Host '  [3] 本机运行网页'
        Write-Host '  [4] 卸载指南'
        Write-Host '  [0] 退出'
        Write-Host ''
        $choice = Read-Host '请选择 [0-4]'

        switch ($choice) {
            '1' { Show-AutoDeploy }
            '2' { Change-Port }
            '3' { Start-Service; return }  # 启动服务后脚本退出
            '4' { Show-Uninstall }
            '0' { Write-Host 'Bye!'; return }
            default { Write-Host '无效选择' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}
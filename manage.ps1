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

# ---------- 菜单项 ----------

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

    # 2. pnpm
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

    # 3. express
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

    # 4. 入口文件
    $indexPath = Join-Path $ScriptDir 'api\index.js'
    if (Test-Path $indexPath) {
        Write-Host '  [OK] 入口文件      api\index.js' -ForegroundColor Green
    } else {
        Write-Host '  [X]  入口文件      缺失（无法自动修复）' -ForegroundColor Red
    }

    # 5. 资源目录
    $mobiPath = Join-Path $ScriptDir 'assets\placeholder.mobi'
    if (Test-Path $mobiPath) {
        $mobiSize = (Get-Item $mobiPath).Length
        Write-Host "  [OK] 资源目录      assets\ (placeholder.mobi = $mobiSize 字节)" -ForegroundColor Green
    } else {
        Write-Host '  [X]  资源目录      缺失（无法自动修复）' -ForegroundColor Red
    }

    # 6. 端口
    $port = Get-Port
    Write-Host "  [i]  当前端口      $port" -ForegroundColor Gray
    if (Test-PortFree $port) {
        Write-Host "  [OK] 端口空闲      $port 可绑定" -ForegroundColor Green
    } else {
        Write-Host "  [X]  端口被占用    $port 已被其他程序占用" -ForegroundColor Red
    }

    # 7. .env
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
    $needsPnpm = $false
    $needsExpress = $false
    $needsIndex = $false
    $needsAssets = $false

    # Node.js
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        Write-Host "  [OK] Node.js       $(node --version)" -ForegroundColor Green
    } else {
        Write-Host '  [X]  Node.js       未安装' -ForegroundColor Red
        $needsNode = $true
    }

    # pnpm / express
    if (-not $needsNode) {
        $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($pnpm) {
            Write-Host "  [OK] pnpm          $(pnpm --version)" -ForegroundColor Green
        } else {
            Write-Host '  [X]  pnpm          未安装' -ForegroundColor Red
            $needsPnpm = $true
        }

        $expressPath = Join-Path $ScriptDir 'node_modules\express\package.json'
        if (Test-Path $expressPath) {
            $expressVer = (Get-Content $expressPath -Raw | ConvertFrom-Json).version
            Write-Host "  [OK] express       $expressVer" -ForegroundColor Green
        } else {
            Write-Host '  [X]  express       未安装' -ForegroundColor Red
            $needsExpress = $true
        }
    } else {
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
    if ($needsPnpm) {
        Write-Host '  [•] pnpm     → 自动 npm install -g pnpm' -ForegroundColor Yellow
    }
    if ($needsExpress) {
        Write-Host '  [•] express  → 自动 pnpm install（fallback npm install）' -ForegroundColor Yellow
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

    # 1. Node.js（敏感动作）
    if ($needsNode) {
        Write-Host '--- 步骤 1: Node.js ---' -ForegroundColor Cyan
        Install-NodeJsInteractive
        $node = Get-Command node -ErrorAction SilentlyContinue
        if ($node) {
            Write-Host "Node.js 已可用 ($(node --version))" -ForegroundColor Green
        } else {
            Write-Host 'Node.js 仍未安装，停止后续步骤' -ForegroundColor Yellow
            Read-Host '按 Enter 键返回菜单'
            return
        }
        Write-Host ''
    }

    # 2. pnpm
    if ($needsPnpm) {
        Write-Host '--- 步骤: pnpm ---' -ForegroundColor Cyan
        $npm = Get-Command npm -ErrorAction SilentlyContinue
        if ($npm) {
            try {
                $null = npm install -g pnpm 2>&1
                if (Get-Command pnpm -ErrorAction SilentlyContinue) {
                    Write-Host "pnpm 已自动安装 ($(pnpm --version))" -ForegroundColor Green
                } else {
                    Write-Host 'pnpm 自动安装失败（请手动 npm install -g pnpm）' -ForegroundColor Red
                }
            } catch {
                Write-Host "pnpm 自动安装失败：$_" -ForegroundColor Red
            }
        } else {
            Write-Host 'npm 也不存在，无法自动装 pnpm' -ForegroundColor Red
        }
        Write-Host ''
    }

    # 3. express
    if ($needsExpress) {
        Write-Host '--- 步骤: express ---' -ForegroundColor Cyan
        $useNpm = $false
        $pm = Get-Command pnpm -ErrorAction SilentlyContinue
        if (-not $pm) {
            $pm = Get-Command npm -ErrorAction SilentlyContinue
            $useNpm = $true
        }
        if ($pm) {
            try {
                if ($useNpm) {
                    $null = npm install 2>&1
                } else {
                    $null = pnpm install 2>&1
                }
                $expressPath = Join-Path $ScriptDir 'node_modules\express\package.json'
                if (Test-Path $expressPath) {
                    $expressVer = (Get-Content $expressPath -Raw | ConvertFrom-Json).version
                    Write-Host "express 已自动安装 ($expressVer)" -ForegroundColor Green
                } else {
                    Write-Host 'express 安装后仍找不到，请看上面的报错' -ForegroundColor Red
                }
            } catch {
                Write-Host "express 安装失败：$_" -ForegroundColor Red
            }
        } else {
            Write-Host '无包管理器可用' -ForegroundColor Red
        }
        Write-Host ''
    }

    Write-Host '=== 部署完成，最新状态： ===' -ForegroundColor Cyan
    Write-Host ''
    Show-Status
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
    Write-Host "  访问方式：浏览器打开 http://localhost:$port/" -ForegroundColor Gray
    Write-Host '  关闭行为：关闭此窗口 / Ctrl+C = 关闭服务' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '3 秒后启动...（按 Ctrl+C 取消）' -ForegroundColor Gray
    Start-Sleep -Seconds 3

    # 依赖兜底
    $nmPath = Join-Path $ScriptDir 'node_modules'
    if (-not (Test-Path $nmPath)) {
        Write-Host '检测到 node_modules 缺失，自动执行 npm install...' -ForegroundColor Red
        npm install
    }

    # 前台启动 node；关闭 PowerShell 窗口 = 关闭 node 进程 = 端口释放
    $env:PORT = $port
    node (Join-Path $ScriptDir 'api\index.js')
}

# ---------- 主菜单（仅在脚本被直接运行时执行，dot-source 时跳过） ----------

if ($MyInvocation.InvocationName -eq $MyInvocation.MyCommand.Path -or
    $MyInvocation.InvocationName -eq '&') {
    # 启动时自动跑一次状态检查（只读、不阻塞）
    Show-Status

    while ($true) {
        $port = Get-Port
        Write-Host '=================================' -ForegroundColor Cyan
        Write-Host '  Winterbreak2 一键管理脚本' -ForegroundColor Cyan
        Write-Host '=================================' -ForegroundColor Cyan
        Write-Host "  当前端口：$port" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  [1] 自动部署（缺啥列出来，确认后再装）'
        Write-Host '  [2] 修改运行端口'
        Write-Host '  [3] 运行（前台启动，关闭窗口即关服务）'
        Write-Host '  [0] 退出'
        Write-Host ''
        $choice = Read-Host '请选择 [0-3]'

        switch ($choice) {
            '1' { Show-AutoDeploy }
            '2' { Change-Port }
            '3' { Start-Service; return }  # 启动服务后脚本退出
            '0' { Write-Host 'Bye!'; return }
            default { Write-Host '无效选择' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}
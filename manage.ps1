# =============================================================================
#  Winterbreak2 一键管理脚本 (Windows PowerShell 版)
# =============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$EnvFile = Join-Path $ScriptDir ".env"
$DefaultPort = 3000

# ---------- 常用辅助工具函数 ----------

function Get-Port {
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile | Where-Object { $_ -match '^PORT=' } | Select-Object -First 1
        if ($line) {
            $v = ($line -split '=')[1].Trim()
            if ($v -as [int] -and [int]$v -gt 0) {
                return [int]$v
            }
        }
    }
    return $DefaultPort
}

function Test-PortFree ($port) {
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Get-LocalIPs {
    try {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike '*Loopback*' } |
            Select-Object -ExpandProperty IPAddress
    } catch {
        [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -ne '127.0.0.1' } |
            Select-Object -ExpandProperty IPAddressToString
    }
}

function Ask-Confirm ($msg) {
    $choice = Read-Host "$msg [Y/n]"
    if ($choice -match '^[Nn]') { return $false }
    return $true
}

function Press-Enter {
    Write-Host ''
    Read-Host '按 Enter 键返回菜单...'
}

# 刷新环境变量 PATH
function Refresh-EnvPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# ---------- 状态检查模块 ----------

function Get-Status {
    Refresh-EnvPath
    Write-Host '===== 部署状态检查 =====' -ForegroundColor Cyan
    Write-Host ''

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nodeVer = node -v 2>$null
        Write-Host "  ✓ Node.js       $nodeVer" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Node.js       未安装" -ForegroundColor Red
    }

    if ($nodeCmd) {
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
        if ($npmCmd) {
            $npmVer = npm -v 2>$null
            Write-Host "  ✓ npm           v$npmVer" -ForegroundColor Green
        } else {
            Write-Host "  ! npm           未安装" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  - npm           （跳过：Node.js 缺失）" -ForegroundColor Gray
    }

    if ($nodeCmd) {
        $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($pnpmCmd) {
            $pnpmVer = pnpm -v 2>$null
            Write-Host "  ✓ pnpm          v$pnpmVer" -ForegroundColor Green
        } else {
            Write-Host "  ✗ pnpm          未安装或版本不可用" -ForegroundColor Red
        }
    } else {
        Write-Host "  - pnpm           （跳过：Node.js 缺失）" -ForegroundColor Gray
    }

    if ($nodeCmd) {
        $expressPkg = Join-Path $ScriptDir "node_modules\express\package.json"
        if (Test-Path $expressPkg) {
            $exprVer = node -p "try{require('./node_modules/express/package.json').version}catch(e){'未安装'}" 2>$null
            Write-Host "  ✓ express       v$exprVer" -ForegroundColor Green
        } else {
            Write-Host "  ✗ express       未安装" -ForegroundColor Red
        }
    } else {
        Write-Host "  - express       （跳过：Node.js 缺失）" -ForegroundColor Gray
    }

    $entryFile = Join-Path $ScriptDir "api\index.js"
    if (Test-Path $entryFile) {
        Write-Host "  ✓ 入口文件      api/index.js" -ForegroundColor Green
    } else {
        Write-Host "  ✗ 入口文件      缺失" -ForegroundColor Red
    }

    $port = Get-Port
    if (Test-PortFree $port) {
        Write-Host "  ✓ 端口空闲      $port 可绑定" -ForegroundColor Green
    } else {
        Write-Host "  ✗ 端口被占用    $port 已被占用" -ForegroundColor Red
    }
    Write-Host ''
}

# ---------- 核心功能模块 ----------

function Start-AutoDeploy {
    Clear-Host
    Write-Host '===== 自动部署 =====' -ForegroundColor Cyan
    Write-Host ''

    Refresh-EnvPath

    $hasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
    $hasNpm = [bool](Get-Command npm -ErrorAction SilentlyContinue)
    $hasPnpm = [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
    $expressPkg = Join-Path $ScriptDir "node_modules\express\package.json"
    $hasExpress = Test-Path $expressPkg

    if ($hasNode -and $hasNpm -and $hasPnpm -and $hasExpress) {
        Write-Host '所有组件均已安装完成，环境就绪！' -ForegroundColor Green
        Press-Enter
        return
    }

    if (-not (Ask-Confirm "确定开始自动修复并安装缺失组件？")) {
        Write-Host '已取消自动部署' -ForegroundColor Yellow
        Press-Enter
        return
    }

    # 1. 安装 Node.js
    if (-not $hasNode) {
        Write-Host "`n--- 步骤 1/4: 安装 Node.js ---" -ForegroundColor Cyan
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host '正在使用 winget 安装 Node.js LTS...' -ForegroundColor Cyan
            winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
            Refresh-EnvPath
        } else {
            Write-Host '未检测到 winget，请前往 https://nodejs.org/ 手动下载安装 Node.js' -ForegroundColor Yellow
            Start-Process "https://nodejs.org/"
            Press-Enter
            return
        }
    }

    # 2. 检查 npm
    Refresh-EnvPath
    $hasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
    $hasNpm = [bool](Get-Command npm -ErrorAction SilentlyContinue)

    if ($hasNode -and -not $hasNpm) {
        Write-Host "`n--- 步骤 2/4: 检查 npm 环境 ---" -ForegroundColor Cyan
        Write-Host '警告：检测到 Node 已安装但 npm 异常，请尝试重新安装 Node.js。' -ForegroundColor Yellow
    }

    # 3. 安装 pnpm
    if ($hasNode -and -not $hasPnpm) {
        Write-Host "`n--- 步骤 3/4: 安装适配版 pnpm ---" -ForegroundColor Cyan
        if (Ask-Confirm "是否自动安装 pnpm 包管理器？") {
            $nodeMajor = node -e "console.log(process.versions.node.split('.')[0])" 2>$null
            $targetPnpm = "pnpm"
            if ($nodeMajor -and [int]$nodeMajor -lt 22) {
                Write-Host "当前 Node.js 版本为 v$nodeMajor，将为你安装兼容版 pnpm@9..." -ForegroundColor Yellow
                $targetPnpm = "pnpm@9"
            }

            if ($hasNpm) {
                npm install -g $targetPnpm | Out-Null
            }
            Refresh-EnvPath
            
            if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
                $corepack = Get-Command corepack -ErrorAction SilentlyContinue
                if ($corepack) {
                    corepack prepare "$targetPnpm" --activate | Out-Null
                    Refresh-EnvPath
                }
            }
        }
    }

    # 4. 安装项目依赖 express
    if (-not $hasExpress) {
        Write-Host "`n--- 步骤 4/4: 安装项目依赖包 (express) ---" -ForegroundColor Cyan
        if (Ask-Confirm "是否安装项目需要的 Node 依赖包？") {
            $installed = $false
            if (Get-Command pnpm -ErrorAction SilentlyContinue) {
                Write-Host '正在使用 pnpm 安装依赖...' -ForegroundColor Gray
                try { pnpm install; $installed = $true } catch {}
            }
            if (-not $installed -and (Get-Command npm -ErrorAction SilentlyContinue)) {
                Write-Host '切换为 npm 自动进行依赖安装...' -ForegroundColor Yellow
                try { npm install; $installed = $true } catch {}
            }
        }
    }

    Write-Host "`n=== 部署流程完毕，最新状态： ===" -ForegroundColor Cyan
    Write-Host ''
    Get-Status
    Press-Enter
}

function Set-PortConfig {
    Clear-Host
    Write-Host '===== 修改运行端口 =====' -ForegroundColor Cyan
    $current = Get-Port
    Write-Host "当前端口：$current" -ForegroundColor Yellow
    
    $newPort = Read-Host "请输入新端口（1-65535，留空取消）"
    if ([string]::IsNullOrWhiteSpace($newPort)) { return }

    if ($newPort -notmatch '^\d+$' -or [int]$newPort -lt 1 -or [int]$newPort -gt 65535) {
        Write-Host '错误：请输入有效端口号 (1-65535)' -ForegroundColor Red
        Press-Enter
        return
    }

    if (-not (Test-PortFree ([int]$newPort))) {
        Write-Host "错误：端口 $newPort 已被占用" -ForegroundColor Red
        Press-Enter
        return
    }

    "PORT=$newPort" | Out-File -FilePath $EnvFile -Encoding utf8
    Write-Host '✓ 已保存端口修改' -ForegroundColor Green
    Press-Enter
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
        Write-Host '  Kindle / 手机访问：浏览器打开以下任一地址' -ForegroundColor Cyan
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

    # 依赖兜底检测
    $expressPkg = Join-Path $ScriptDir "node_modules\express\package.json"
    if (-not (Test-Path $expressPkg)) {
        Write-Host '检测到依赖缺失，自动安装...' -ForegroundColor Yellow
        $installed = $false
        if (Get-Command pnpm -ErrorAction SilentlyContinue) {
            try { pnpm install; $installed = $true } catch {}
        }
        if (-not $installed -and (Get-Command npm -ErrorAction SilentlyContinue)) {
            try { npm install; $installed = $true } catch {}
        }
        if (-not $installed) {
            Write-Host '依赖安装失败，请手动在项目目录执行 pnpm install 或 npm install' -ForegroundColor Red
            Press-Enter
            return
        }
    }

    $env:PORT = $port
    node (Join-Path $ScriptDir 'api\index.js')
}

# ---------- 卸载模块 ----------

function Uninstall-Dependencies {
    Write-Host '正在清理项目依赖与本地缓存...' -ForegroundColor Cyan
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$ScriptDir\node_modules", "$ScriptDir\pnpm-lock.yaml", "$ScriptDir\package-lock.json"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:USERPROFILE\.npm\_cacache", "$env:USERPROFILE\.pnpm-store"
    Write-Host '✓ 项目依赖及缓存清理完成！' -ForegroundColor Green
    Press-Enter
}

function Uninstall-GlobalEnv {
    Write-Host '====================================================' -ForegroundColor Red
    Write-Host ' 警告：这将卸载全局环境中的 Node.js, npm 和 pnpm！' -ForegroundColor Red
    Write-Host ' 这可能会导致您电脑上的其他 Node.js 项目不可用！' -ForegroundColor Red
    Write-Host '====================================================' -ForegroundColor Red
    Write-Host ''

    $confirm = Read-Host "请输入大写 'YES' 确认卸载全局环境（输入其他取消）"
    if ($confirm -ne 'YES') {
        Write-Host '已取消全局卸载' -ForegroundColor Yellow
        Press-Enter
        return
    }

    Write-Host "`n正在卸载全局 pnpm..." -ForegroundColor Cyan
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        npm uninstall -g pnpm 2>$null
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:LOCALAPPDATA\pnpm", "$env:USERPROFILE\.pnpm-store"

    Write-Host '正在卸载系统 Node.js 与 npm...' -ForegroundColor Cyan
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        winget uninstall --id OpenJS.NodeJS.LTS -e 2>$null
        winget uninstall --id OpenJS.NodeJS -e 2>$null
    } else {
        Write-Host '请前往 Windows “设置 -> 应用 -> 已安装的应用” 中手动卸载 Node.js' -ForegroundColor Yellow
    }

    # 清理残留配置
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$env:APPDATA\npm", "$env:APPDATA\npm-cache", "$env:USERPROFILE\.npmrc"

    Refresh-EnvPath
    Write-Host '✓ 全局 Node.js/npm/pnpm 环境已清理完毕！' -ForegroundColor Green
    Press-Enter
}

function Show-UninstallMenu {
    while ($true) {
        Clear-Host
        Write-Host '===== 卸载与清理菜单 =====' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  [1] 卸载项目依赖 & 缓存 (只删 node_modules / 缓存)'
        Write-Host '  [2] 卸载全局 Node/npm/pnpm (系统级清理，需手动确认 YES)'
        Write-Host '  [0] 返回主菜单'
        Write-Host ''
        $unChoice = Read-Host '请选择 [0-2]'

        switch ($unChoice) {
            '1' { Uninstall-Dependencies; break }
            '2' { Uninstall-GlobalEnv; break }
            '0' { return }
            default { Write-Host '无效选择' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

# ---------- 主菜单循环 ----------

while ($true) {
    Clear-Host
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host '  Winterbreak2 一键管理部署脚本' -ForegroundColor Cyan
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host ''

    Get-Status

    Write-Host '  [1] 自动部署'
    Write-Host '  [2] 修改运行端口'
    Write-Host '  [3] 本机运行网页'
    Write-Host '  [4] 卸载与清理'
    Write-Host '  [0] 退出'
    Write-Host ''
    $choice = Read-Host '请选择 [0-4]'

    switch ($choice) {
        '1' { Start-AutoDeploy }
        '2' { Set-PortConfig }
        '3' { Start-Service }
        '4' { Show-UninstallMenu }
        '0' { Write-Host 'Bye!'; exit }
        default { Write-Host '无效选择' -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
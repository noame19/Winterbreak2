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

function Show-Deploy {
    Clear-Host
    Write-Host '===== 部署状态检查 =====' -ForegroundColor Cyan
    Write-Host ''

    # 1. Node.js
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $nodeVer = node --version
        Write-Host "  [OK] Node.js       $nodeVer" -ForegroundColor Green
    } else {
        Write-Host '  [X]  Node.js       未安装（请到 https://nodejs.org 下载）' -ForegroundColor Red
    }

    # 2. express
    $expressPath = Join-Path $ScriptDir 'node_modules\express\package.json'
    if (Test-Path $expressPath) {
        $expressVer = (Get-Content $expressPath -Raw | ConvertFrom-Json).version
        Write-Host "  [OK] express       $expressVer" -ForegroundColor Green
    } else {
        Write-Host '  [X]  express       未安装（请运行 pnpm install 或 npm install）' -ForegroundColor Red
    }

    # 3. 入口文件
    $indexPath = Join-Path $ScriptDir 'api\index.js'
    if (Test-Path $indexPath) {
        Write-Host '  [OK] 入口文件      api\index.js' -ForegroundColor Green
    } else {
        Write-Host '  [X]  入口文件      缺失' -ForegroundColor Red
    }

    # 4. 资源目录
    $mobiPath = Join-Path $ScriptDir 'assets\placeholder.mobi'
    if (Test-Path $mobiPath) {
        $mobiSize = (Get-Item $mobiPath).Length
        Write-Host "  [OK] 资源目录      assets\ (placeholder.mobi = $mobiSize 字节)" -ForegroundColor Green
    } else {
        Write-Host '  [X]  资源目录      缺失' -ForegroundColor Red
    }

    # 5. 端口信息
    $port = Get-Port
    Write-Host "  [i]  当前端口      $port" -ForegroundColor Gray

    # 6. 端口可用性
    if (Test-PortFree $port) {
        Write-Host "  [OK] 端口空闲      $port 可绑定" -ForegroundColor Green
    } else {
        Write-Host "  [X]  端口被占用    $port 已被其他程序占用（请用 [2] 改端口）" -ForegroundColor Red
    }

    # 7. .env 状态
    if (Test-Path $EnvFile) {
        Write-Host '  [i]  端口配置      .env（已存在）' -ForegroundColor Gray
    } else {
        Write-Host "  [i]  端口配置      .env（未创建，运行时用默认 $DefaultPort）" -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host '======================' -ForegroundColor Cyan
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

    # 写 .env（UTF-8 无 BOM，因为 dotenv 不需要 BOM）
    "PORT=$newPort" | Set-Content -Encoding UTF8 $EnvFile
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
    while ($true) {
        Clear-Host
        $port = Get-Port
        Write-Host '=================================' -ForegroundColor Cyan
        Write-Host '  Winterbreak2 一键管理脚本' -ForegroundColor Cyan
        Write-Host '=================================' -ForegroundColor Cyan
        Write-Host "  当前端口：$port" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  [1] 部署状态检查'
        Write-Host '  [2] 修改运行端口'
        Write-Host '  [3] 运行（前台启动，关闭窗口即关服务）'
        Write-Host '  [0] 退出'
        Write-Host ''
        $choice = Read-Host '请选择 [0-3]'

        switch ($choice) {
            '1' { Show-Deploy }
            '2' { Change-Port }
            '3' { Start-Service; return }  # 启动服务后脚本退出
            '0' { Write-Host 'Bye!'; return }
            default { Write-Host '无效选择' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}
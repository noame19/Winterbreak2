@echo off
REM =============================================================================
REM  Winterbreak2 一键管理脚本 (Windows 原生 cmd 版)
REM =============================================================================
REM  功能菜单：
REM    [1] 部署状态检查  —— 检查 Node / 依赖 / 端口
REM    [2] 修改运行端口  —— 交互式改端口并写入 .env
REM    [3] 运行服务      —— 前台启动 node api/index.js（关闭窗口即关服务）
REM
REM  用法：双击运行，或在 cmd 里 cd 到本目录后输入 manage.bat
REM =============================================================================

chcp 65001 >nul 2>&1
setlocal EnableDelayedExpansion

cd /d "%~dp0"
set "ENV_FILE=.env"
set "DEFAULT_PORT=3000"

:menu
cls
echo =================================
echo   Winterbreak2 一键管理脚本
echo =================================
echo.

REM 读当前端口
set "CURRENT_PORT=%DEFAULT_PORT%"
if exist "%ENV_FILE%" (
    for /f "usebackq tokens=1* delims==" %%a in ("%ENV_FILE%") do (
        if "%%a"=="PORT" set "CURRENT_PORT=%%b"
    )
)

echo   当前端口：!CURRENT_PORT!
echo.
echo   [1] 部署状态检查
echo   [2] 修改运行端口
echo   [3] 运行（前台启动，关闭窗口即关服务）
echo   [0] 退出
echo.
set /p "choice=请选择 [0-3]: "

if "!choice!"=="1" goto :action_deploy
if "!choice!"=="2" goto :action_change
if "!choice!"=="3" goto :action_run
if "!choice!"=="0" goto :exit
echo 无效选择
timeout /t 1 /nobreak >nul
goto :menu

:action_deploy
cls
echo ===== 部署状态检查 =====
echo.

REM 1. Node.js
where node >nul 2>&1
if !errorlevel!==0 (
    for /f "delims=" %%v in ('node --version') do echo   [√] Node.js         %%v
) else (
    echo   [X] Node.js         未安装
)

REM 2. express 依赖
if exist "node_modules" (
    for /f "delims=" %%v in ('node -p "try{require('express/package.json').version}catch(e){'未安装'}" 2^>nul') do echo   [√] express         %%v
) else (
    echo   [X] express         未安装
)

REM 3. 入口文件
if exist "api\index.js" (
    echo   [√] 入口文件        api\index.js
) else (
    echo   [X] 入口文件        缺失
)

REM 4. 资源目录
if exist "assets\placeholder.mobi" (
    for %%f in ("assets\placeholder.mobi") do echo   [√] 资源目录        assets\ (placeholder.mobi = %%~zf 字节)
) else (
    echo   [X] 资源目录        缺失
)

REM 5. 端口信息
echo   [i] 当前端口        !CURRENT_PORT!

REM 6. 端口占用检查（用 Node 内置 net 跨平台一致）
node -e "const n=require('net');const s=n.createServer();s.on('error',()=>process.exit(1));s.listen(!CURRENT_PORT!,'0.0.0.0',()=>s.close(()=>process.exit(0)));" >nul 2>&1
if !errorlevel!==0 (
    echo   [√] 端口空闲        !CURRENT_PORT! 可绑定
) else (
    echo   [X] 端口被占用      !CURRENT_PORT! 已被其他程序占用
)

REM 7. .env 状态
if exist "%ENV_FILE%" (
    echo   [i] 端口配置        .env （已存在）
) else (
    echo   [i] 端口配置        .env （未创建，运行时用默认 !DEFAULT_PORT!）
)

echo.
echo ======================
echo 按任意键返回菜单...
pause >nul
goto :menu

:action_change
cls
echo ===== 修改运行端口 =====
echo.
echo   当前端口：!CURRENT_PORT!
echo   监听地址：http://0.0.0.0:^<新端口^>
echo.
set /p "new_port=请输入新端口（1-65535，留空取消）: "
if "!new_port!"=="" (
    echo 已取消
    pause >nul
    goto :menu
)

REM 数字校验
set "is_num=1"
for /f "delims=0123456789" %%x in ("!new_port!") do set "is_num="
if defined is_num if "!is_num!"=="1" goto :check_range
echo 错误：端口必须是纯数字
pause >nul
goto :menu

:check_range
if !new_port! lss 1 (
    echo 错误：端口必须 ^>= 1
    pause >nul
    goto :menu
)
if !new_port! gtr 65535 (
    echo 错误：端口必须 ^<= 65535
    pause >nul
    goto :menu
)

REM 端口占用检查
node -e "const n=require('net');const s=n.createServer();s.on('error',()=>process.exit(1));s.listen(!new_port!,'0.0.0.0',()=>s.close(()=>process.exit(0)));" >nul 2>&1
if !errorlevel! neq 0 (
    echo 错误：端口 !new_port! 已被占用
    pause >nul
    goto :menu
)

REM 写 .env
echo PORT=!new_port!> "%ENV_FILE%"
echo [√] 已将端口设置为 !new_port!（写入 .env）
pause >nul
goto :menu

:action_run
cls
echo ===== 启动服务 =====
echo.
echo   监听地址：http://0.0.0.0:!CURRENT_PORT!
echo   访问方式：浏览器打开 http://localhost:!CURRENT_PORT!/
echo   关闭行为：关闭此窗口 / Ctrl+C = 关闭服务
echo.
echo 3 秒后启动...（按 Ctrl+C 取消）
timeout /t 3 /nobreak >nul

REM 依赖兜底
if not exist "node_modules" (
    echo 检测到 node_modules 缺失，自动执行 npm install...
    call npm install
)

REM 前台启动 node；关闭 cmd 窗口 → cmd 进程退出 → node 进程收到终止信号 → 端口释放
set "PORT=!CURRENT_PORT!"
node api\index.js

:exit
echo Bye!
pause >nul
endlocal
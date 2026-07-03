@echo off
chcp 65001 >nul
:: Spoken 完整构建脚本（Windows CMD）
:: 流程：生成图标 → PyInstaller 打包 → Inno Setup 制作安装包

echo ========================================
echo Spoken 完整构建流程
echo ========================================

:: ══════════════════════════════════════════════════════════════════════
:: 配置
:: ══════════════════════════════════════════════════════════════════════
set VENV_PYTHON=..\.venv\Scripts\python.exe
set ICON_FILE=spoken.ico
set ISS_FILE=setup.iss
:: 桌面路径（安装包输出目录）
for /f "usebackq tokens=3*" %%a in (`reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v Desktop 2^>nul`) do set DESKTOP=%%a
if "%DESKTOP%"=="" set DESKTOP=%USERPROFILE%\Desktop
set OUTPUT_INSTALLER=%DESKTOP%\Spoken-Build

:: ══════════════════════════════════════════════════════════════════════
:: 1. 检查环境
:: ══════════════════════════════════════════════════════════════════════
echo.
echo [1/5] 检查构建环境...

:: 检查虚拟环境 Python
if not exist "%VENV_PYTHON%" (
    echo [ERROR] 虚拟环境 Python 未找到: %VENV_PYTHON%
    echo 请先创建虚拟环境并安装依赖:
    echo   uv venv  或  python -m venv .venv
    echo   uv pip install -r requirements.txt
    exit /b 1
)

:: 检查 PyInstaller
%VENV_PYTHON% -c "import PyInstaller" 2>nul
if errorlevel 1 (
    echo [ERROR] PyInstaller 未安装，请先运行:
    echo   %VENV_PYTHON% -m pip install pyinstaller
    exit /b 1
)

:: 检查 Pillow（生成图标需要）
%VENV_PYTHON% -c "import PIL" 2>nul
if errorlevel 1 (
    echo [ERROR] Pillow 未安装，请先运行:
    echo   %VENV_PYTHON% -m pip install Pillow
    exit /b 1
)

echo [OK] 环境检查通过

:: ══════════════════════════════════════════════════════════════════════
:: 2. 清理旧构建
:: ══════════════════════════════════════════════════════════════════════
echo.
echo [2/5] 清理旧构建...

if exist "dist" rmdir /s /q "dist"
if exist "build" rmdir /s /q "build"
:: 桌面输出目录由 Inno Setup 管理，不在此清理
if exist "%ICON_FILE%" del /f /q "%ICON_FILE%"

echo [OK] 清理完成

:: ══════════════════════════════════════════════════════════════════════
:: 3. 生成应用图标
:: ══════════════════════════════════════════════════════════════════════
echo.
echo [3/5] 生成应用图标...

%VENV_PYTHON% generate_icon.py
if errorlevel 1 (
    echo [ERROR] 生成图标失败
    exit /b 1
)
if not exist "%ICON_FILE%" (
    echo [ERROR] 图标文件生成失败: %ICON_FILE%
    exit /b 1
)
echo [OK] 图标已生成: %ICON_FILE%

:: ══════════════════════════════════════════════════════════════════════
:: 4. PyInstaller 打包
:: ══════════════════════════════════════════════════════════════════════
echo.
echo [4/5] 执行 PyInstaller 打包...

%VENV_PYTHON% -m PyInstaller spoken.spec --clean --noconfirm
if errorlevel 1 (
    echo [ERROR] PyInstaller 打包失败
    exit /b 1
)

if not exist "dist\Spoken\Spoken.exe" (
    echo [ERROR] 打包产物未找到: dist\Spoken\Spoken.exe
    exit /b 1
)
echo [OK] 打包完成: dist\Spoken\Spoken.exe

:: ══════════════════════════════════════════════════════════════════════
:: 5. Inno Setup 制作安装包
:: ══════════════════════════════════════════════════════════════════════
echo.
echo [5/5] 制作安装包...

:: 查找 ISCC（Inno Setup Compiler）
set ISCC=
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe
) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
    set ISCC=C:\Program Files\Inno Setup 6\ISCC.exe
)

if "%ISCC%"=="" (
    echo [WARN] Inno Setup 未安装，跳过安装包制作
    echo   下载地址: https://jrsoftware.org/isdl.php
    echo   安装后重新运行此脚本
    echo.
    echo ========================================
    echo 打包完成（无安装包）
    echo ========================================
    echo 输出目录: dist\Spoken\
    echo 启动入口: dist\Spoken\Spoken.exe
    pause
    exit /b 0
)

:: 执行 ISCC 编译
"%ISCC%" %ISS_FILE%
if errorlevel 1 (
    echo [ERROR] Inno Setup 编译失败
    exit /b 1
)

:: 检查安装包
if not exist "%OUTPUT_INSTALLER%\*.exe" (
    echo [ERROR] 安装包未生成
    exit /b 1
)

:: ══════════════════════════════════════════════════════════════════════
:: 完成
:: ══════════════════════════════════════════════════════════════════════
echo.
echo ========================================
echo 构建完成！
echo ========================================
echo.
echo 安装包: %OUTPUT_INSTALLER%\Spoken-Setup-*.exe
echo 便携版: dist\Spoken\
echo.
echo 安装包功能:
echo   - 开始菜单快捷方式
echo   - 桌面快捷方式（可选）
echo   - 开机自动启动
echo   - 完整卸载（保留用户配置）
pause

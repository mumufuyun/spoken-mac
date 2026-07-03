﻿# Spoken 完整构建脚本（PowerShell）
# 流程：生成图标 → PyInstaller 打包 → Inno Setup 制作安装包

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Spoken 完整构建流程" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ══════════════════════════════════════════════════════════════════════
# 配置
# ══════════════════════════════════════════════════════════════════════
$VENV_PYTHON = "..\.venv\Scripts\python.exe"
$ICON_FILE = "spoken.ico"
$ISS_FILE = "setup.iss"
$OUTPUT_INSTALLER = "$([Environment]::GetFolderPath('Desktop'))\Spoken-Build"

# ══════════════════════════════════════════════════════════════════════
# 1. 检查环境
# ══════════════════════════════════════════════════════════════════════
Write-Host "`n[1/5] 检查构建环境..." -ForegroundColor Yellow

# 检查虚拟环境 Python
if (-not (Test-Path $VENV_PYTHON)) {
    Write-Host "[ERROR] 虚拟环境 Python 未找到: $VENV_PYTHON" -ForegroundColor Red
    Write-Host "请先创建虚拟环境并安装依赖:" -ForegroundColor Red
    Write-Host "  uv venv  或  python -m venv .venv" -ForegroundColor Yellow
    Write-Host "  uv pip install -r requirements.txt" -ForegroundColor Yellow
    exit 1
}

# 检查 PyInstaller
try {
    & $VENV_PYTHON -c "import PyInstaller" | Out-Null
} catch {
    Write-Host "[ERROR] PyInstaller 未安装，请先运行:" -ForegroundColor Red
    Write-Host "  $VENV_PYTHON -m pip install pyinstaller" -ForegroundColor Yellow
    exit 1
}

# 检查 Pillow（生成图标需要）
try {
    & $VENV_PYTHON -c "import PIL" | Out-Null
} catch {
    Write-Host "[ERROR] Pillow 未安装，请先运行:" -ForegroundColor Red
    Write-Host "  $VENV_PYTHON -m pip install Pillow" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] 环境检查通过" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════════════
# 2. 清理旧构建
# ══════════════════════════════════════════════════════════════════════
Write-Host "`n[2/5] 清理旧构建..." -ForegroundColor Yellow

$dirsToClean = @("dist", "build")  # 桌面输出目录由 Inno Setup 管理
foreach ($dir in $dirsToClean) {
    if (Test-Path $dir) {
        Remove-Item -Recurse -Force $dir
        Write-Host "  已清理: $dir"
    }
}

# 图标文件（重新生成）
if (Test-Path $ICON_FILE) {
    Remove-Item -Force $ICON_FILE
    Write-Host "  已清理: $ICON_FILE"
}

Write-Host "[OK] 清理完成" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════════════
# 3. 生成应用图标
# ══════════════════════════════════════════════════════════════════════
Write-Host "`n[3/5] 生成应用图标..." -ForegroundColor Yellow

try {
    & $VENV_PYTHON "generate_icon.py"
    if (-not (Test-Path $ICON_FILE)) {
        throw "图标文件生成失败: $ICON_FILE"
    }
    Write-Host "[OK] 图标已生成: $ICON_FILE" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] 生成图标失败: $_" -ForegroundColor Red
    exit 1
}

# ══════════════════════════════════════════════════════════════════════
# 4. PyInstaller 打包
# ══════════════════════════════════════════════════════════════════════
Write-Host "`n[4/5] 执行 PyInstaller 打包..." -ForegroundColor Yellow

& $VENV_PYTHON -m PyInstaller spoken.spec --clean --noconfirm

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] PyInstaller 打包失败" -ForegroundColor Red
    exit 1
}

$exePath = "dist\Spoken\Spoken.exe"
if (-not (Test-Path $exePath)) {
    Write-Host "[ERROR] 打包产物未找到: $exePath" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] 打包完成: $exePath" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════════════
# 5. Inno Setup 制作安装包
# ══════════════════════════════════════════════════════════════════════
Write-Host "`n[5/5] 制作安装包..." -ForegroundColor Yellow

# 查找 ISCC（Inno Setup Compiler）
$ISCC_PATHS = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
)

$ISCC = $null
foreach ($path in $ISCC_PATHS) {
    if (Test-Path $path) {
        $ISCC = $path
        break
    }
}

if ($null -eq $ISCC) {
    Write-Host "[WARN] Inno Setup 未安装，跳过安装包制作" -ForegroundColor Yellow
    Write-Host "  下载地址: https://jrsoftware.org/isdl.php" -ForegroundColor Yellow
    Write-Host "  安装后重新运行此脚本" -ForegroundColor Yellow
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "打包完成（无安装包）" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "输出目录: dist\Spoken\" -ForegroundColor Green
    Write-Host "启动入口: dist\Spoken\Spoken.exe" -ForegroundColor Green
    exit 0
}

# 校验图标文件存在（setup.iss 中独立安装及快捷方式均依赖此文件）
if (-not (Test-Path $ICON_FILE)) {
    Write-Host "[ERROR] 图标文件不存在，无法制作安装包: $ICON_FILE" -ForegroundColor Red
    exit 1
}

# 执行 ISCC 编译
try {
    & $ISCC $ISS_FILE
    if ($LASTEXITCODE -ne 0) {
        throw "ISCC 返回错误码: $LASTEXITCODE"
    }
} catch {
    Write-Host "[ERROR] Inno Setup 编译失败: $_" -ForegroundColor Red
    exit 1
}

# 检查安装包
$installerFiles = Get-ChildItem -Path "$([Environment]::GetFolderPath('Desktop'))\Spoken-Build" -Filter "*.exe" -ErrorAction SilentlyContinue
if ($installerFiles.Count -eq 0) {
    Write-Host "[ERROR] 安装包未生成" -ForegroundColor Red
    exit 1
}

$installerPath = $installerFiles[0].FullName

# ══════════════════════════════════════════════════════════════════════
# 完成
# ══════════════════════════════════════════════════════════════════════
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "构建完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "安装包: $installerPath" -ForegroundColor Green
Write-Host "便携版: dist\Spoken\" -ForegroundColor Green
Write-Host ""
Write-Host "安装包功能:" -ForegroundColor Cyan
Write-Host "  - 开始菜单快捷方式" -ForegroundColor White
Write-Host "  - 桌面快捷方式（可选）" -ForegroundColor White
Write-Host "  - 开机自动启动" -ForegroundColor White
Write-Host "  - 完整卸载（保留用户配置）" -ForegroundColor White

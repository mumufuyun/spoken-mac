# Spoken 图标缓存清除脚本
# 如果安装后图标仍未更新，运行此脚本

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "清除 Windows 图标缓存" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# 检查管理员权限
$isAdmin = [bool]([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups -match "S-1-5-32-544")
if (-not $isAdmin) {
    Write-Host "[WARN] 未以管理员权限运行，某些操作可能失败" -ForegroundColor Yellow
}

Write-Host "[1/4] 停止 Explorer 进程..." -ForegroundColor Yellow
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Host "[2/4] 删除图标缓存文件..." -ForegroundColor Yellow
$localappdata = $env:LOCALAPPDATA
$cachePaths = @(
    "$localappdata\IconCache.db",
    "$localappdata\Microsoft\Windows\Explorer\iconcache_*.db"
)

foreach ($path in $cachePaths) {
    Get-Item -Path $path -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "  已清除: $path"
}

Write-Host "[3/4] 清除 Windows 图标缓存..." -ForegroundColor Yellow
Invoke-Expression 'cmd.exe /c ie4uinit.exe -show 2>nul' | Out-Null
Invoke-Expression 'cmd.exe /c ie4uinit.exe -ClearIconCache 2>nul' | Out-Null

Write-Host "[4/4] 重启 Explorer..." -ForegroundColor Yellow
Start-Process explorer.exe
Start-Sleep -Seconds 1

Write-Host ""
Write-Host "[OK] 缓存已清除，图标应该立即更新" -ForegroundColor Green
Write-Host "如果图标仍未更新，请重启计算机或手动刷新（F5）文件夹视图" -ForegroundColor Cyan
Write-Host ""

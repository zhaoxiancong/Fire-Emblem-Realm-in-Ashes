# ============================================================
# 《山河烬》WSL2 + FE8 改版环境搭建脚本
# ------------------------------------------------------------
# 用法：右键本文件 → "使用 PowerShell 运行"
#       或在管理员 PowerShell 中执行：
#       powershell -ExecutionPolicy Bypass -File .\1-install-wsl.ps1
#
# 作用：安装 WSL2 + Ubuntu。安装完成后需要【重启电脑】。
# 注意：需要管理员权限。
# ============================================================

# 注意：本脚本大量调用外部命令（wsl.exe / dism.exe），这类命令常把普通提示写到
# stderr 并以非零码返回。若用 'Stop'，任何一句提示都会中断整个脚本（这正是初版 bug）。
# 因此这里用 'Continue'，由脚本自己判断每一步的成败。
$ErrorActionPreference = 'Continue'

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[X] $msg" -ForegroundColor Red }

# 安全调用外部命令：临时放宽 ErrorActionPreference 并捕获输出，
# 避免外部命令把提示写到 stderr 时被当成致命异常中断整个脚本。
function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Command @Arguments 2>&1
        $code = $LASTEXITCODE
        if ($out) { $out | ForEach-Object { Write-Host "    $_" } }
    } catch {
        Write-Warn "调用 $Command 出错：$($_.Exception.Message)"
        $code = -1
    } finally {
        $ErrorActionPreference = $prev
    }
    return $code
}

# ---------- 0. 检查管理员权限 ----------
Write-Step "0. 检查权限与环境"
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Err "需要管理员权限。请右键本文件 → 使用 PowerShell 运行（以管理员身份）。"
    Read-Host "按回车退出"
    exit 1
}
Write-Ok "管理员权限已确认"

# ---------- 1. 检查 Windows 版本 ----------
$osVer = [System.Environment]::OSVersion.Version
Write-Host "系统版本：$($osVer.Major).$($osVer.Minor).Build $($osVer.Build)"

if ($osVer.Build -lt 19041) {
    Write-Err "Windows 版本过低（Build $($osVer.Build)）。WSL2 需要 Windows 10 Build 19041 或更高。"
    Read-Host "按回车退出"
    exit 1
}
Write-Ok "Windows 版本满足 WSL2 要求"

# ---------- 2. 检查是否已装 WSL ----------
Write-Step "1. 检查现有 WSL"
$wslExists = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
if ($wslExists) {
    # 注意：wsl.exe 常把提示信息写到 stderr 并以非零码返回（例如"未安装 WSL"），
    # 在 $ErrorActionPreference='Stop' 下会被当成致命异常。故统一走 Invoke-Native。
    $distros = @()
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $distros = @((& wsl.exe -l -q 2>&1) | Where-Object {
            $_ -isnot [System.Management.Automation.ErrorRecord]
        })
        $wslExit = $LASTEXITCODE
    } catch {
        $wslExit = 1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $clean = @($distros | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($wslExit -eq 0 -and $clean.Count -gt 0) {
        Write-Ok "WSL 已就绪，现有发行版："
        $clean | ForEach-Object { Write-Host "    - $_" }
        Write-Host ""
        Write-Warn "如果列表里已有 Ubuntu，可以跳过本脚本，直接运行 2-setup-project.sh"
        $go = Read-Host "仍要继续安装/更新 WSL？(y/N)"
        if ($go -ne 'y' -and $go -ne 'Y') { exit 0 }
    } else {
        Write-Warn "检测到 wsl.exe，但 WSL 尚未安装/启用（下文的 wsl --install 会处理）"
    }
} else {
    Write-Host "未检测到 wsl.exe"
}

# ---------- 3. 启用所需 Windows 功能 ----------
Write-Step "2. 启用 Windows 功能（WSL + 虚拟机平台）"
foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
    try {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop).State
        if ($state -eq 'Enabled') {
            Write-Ok "$feat 已启用"
        } else {
            Write-Host "正在启用 $feat ..."
            Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart | Out-Null
            Write-Ok "$feat 已启用（待重启生效）"
        }
    } catch {
        Write-Warn "无法查询/启用 $feat：$($_.Exception.Message)"
        Write-Warn "将交由 wsl --install 处理"
    }
}

# ---------- 4. 安装 WSL + Ubuntu ----------
Write-Step "3. 安装 WSL2 与 Ubuntu"
Write-Host "执行：wsl --install -d Ubuntu --no-launch --web-download"
Write-Host "  （--web-download 关键：改从 GitHub 下载，绕开 Microsoft Store 渠道的 403/龟速）"
Write-Host "  （这一步可能需要几分钟，请耐心等待）"
$code = Invoke-Native "wsl.exe" @('--install', '-d', 'Ubuntu', '--no-launch', '--web-download')
if ($code -ne 0) {
    Write-Warn "wsl --install 返回码 $code，尝试不带 --web-download 再试一次..."
    $code = Invoke-Native "wsl.exe" @('--install', '-d', 'Ubuntu', '--no-launch')
}
if ($code -ne 0) {
    Write-Warn "仍未成功（返回码 $code）。可尝试："
    Write-Host "  1) 先启用功能再装："
    Write-Host "    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart"
    Write-Host "    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart"
    Write-Host "  2) 重启后执行：wsl --install -d Ubuntu --no-launch --web-download"
    Write-Host "  3) 若报「已禁止(403)」= 商店接口拒绝代理 IP，务必加 --web-download"
    Write-Host "  4) 若下载极慢 = 未走代理，检查 Clash 的系统代理/虚拟网卡模式是否开启"
} else {
    Write-Ok "WSL + Ubuntu 安装指令已下发"
}

# ---------- 5. 设置为 WSL2 默认 ----------
Write-Step "4. 设置 WSL2 为默认版本"
[void](Invoke-Native "wsl.exe" @('--set-default-version', '2'))
Write-Ok "已尝试设置默认版本为 WSL2"

# ---------- 6. 完成 ----------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  下一步：重启电脑" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "重启后 Ubuntu 会自动启动并要求设置："
Write-Host "  1) 用户名（建议全小写英文，如 shanhe）"
Write-Host "  2) 密码（输入时不显示，正常现象）"
Write-Host ""
Write-Host "Ubuntu 初始化完成后，在 Windows 终端里执行："
Write-Host "  wsl -d Ubuntu" -ForegroundColor Yellow
Write-Host "然后按 2-setup-project.sh 的说明继续。" -ForegroundColor Yellow
Write-Host ""
Read-Host "按回车退出"

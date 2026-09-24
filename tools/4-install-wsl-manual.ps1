# ============================================================
# 《山河烬》WSL 手动安装脚本（完全绕开 Microsoft Store）
# ------------------------------------------------------------
# 适用场景：
#   wsl --install 反复报「已禁止(403)」/ 下载极慢 / 提示需提升
#
# 原理：
#   1) WSL 本体  —— 从 GitHub Releases 下载 MSI 直接装
#   2) Ubuntu    —— 从清华镜像下载官方 .wsl 镜像后 wsl --import
#   全程不碰 Microsoft Store 渠道
#
# 用法（建议：管理员 PowerShell）
#   powershell -ExecutionPolicy Bypass -File "D:\workbuddy\FireEmblem Realm-in-Ashes\tools\4-install-wsl-manual.ps1"
#
# 参数（都有合理默认值，可全部不传）：
#   -DistroName   发行版注册名，默认 Ubuntu-24.04
#   -InstallDir   WSL 磁盘存放目录（建议放非系统盘），默认 D:\WSL\Ubuntu-24.04
#   -UserName     Linux 用户名，默认 shanhe
#   -SkipWsl      已装好 WSL 本体时跳过第一步
#   -SkipUbuntu   只装 WSL 本体，不装发行版
# ============================================================

param(
    [string]$DistroName = "Ubuntu-24.04",
    [string]$InstallDir = "D:\WSL\Ubuntu-24.04",
    [string]$UserName   = "shanhe",
    [switch]$SkipWsl,
    [switch]$SkipUbuntu,
    [switch]$Force
)

# 注意：本脚本大量调用外部命令（curl.exe / wsl.exe / msiexec），
# 这类命令常把普通提示写到 stderr 并以非零码返回。
# 若用 'Stop'，任何一句提示都会中断整个脚本，故用 'Continue'。
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'Continue'

# ---------- 常量 ----------
$WSL_MSI_URL   = 'https://github.com/microsoft/WSL/releases/download/2.7.14/wsl.2.7.14.0.x64.msi'
$WSL_MSI_SHA256= 'db084e536279a59e90a26ec598d8aa8a4dff8309f41d078fd06242953ac1ebcd'
$TUNA_NOBLE    = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/noble/'
$CLOUD_ROOTFS  = 'https://cloud-images.ubuntu.com/wsl/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'

$DownloadDir   = Join-Path $env:USERPROFILE 'Downloads'

# ---------- 工具函数 ----------
function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "[!] $m"  -ForegroundColor Yellow }
function Write-Err2($m) { Write-Host "[X] $m"  -ForegroundColor Red }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    param([Parameter(Mandatory=$true)][string]$Command, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Command @Arguments 2>&1
        $code = $LASTEXITCODE
        if ($out) { $out | ForEach-Object { Write-Host "    $_" } }
    } catch {
        Write-Warn2 "调用 $Command 出错：$($_.Exception.Message)"
        $code = -1
    } finally {
        $ErrorActionPreference = $prev
    }
    return $code
}

function Get-Url {
    param([string]$Url, [string]$OutFile)
    # 优先用系统自带 curl.exe（带进度条、大文件快）
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        $code = Invoke-Native $curl @('-L', '--fail', '--retry', '3', '--retry-delay', '2', '-o', $OutFile, $Url)
        return ($code -eq 0) -and (Test-Path $OutFile)
    }
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $OutFile)
        return (Test-Path $OutFile)
    } catch {
        Write-Err2 "下载失败：$($_.Exception.Message)"
        return $false
    }
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-FreeGB {
    param([string]$Path)
    $root = [System.IO.Path]::GetPathRoot($Path)
    $d = Get-PSDrive -Name $root.TrimEnd(':\') -ErrorAction SilentlyContinue
    if ($d) { return [math]::Round($d.Free / 1GB, 1) }
    return 999
}

# ---------- 0. 自动提权 ----------
Write-Step "0. 权限检查"

if (-not (Test-Admin)) {
    Write-Warn2 "当前不是管理员，正在请求提权（会弹出 UAC，请点「是」）..."
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-DistroName', $DistroName,
        '-InstallDir', $InstallDir,
        '-UserName', $UserName
    )
    if ($SkipWsl)    { $argList += '-SkipWsl' }
    if ($SkipUbuntu) { $argList += '-SkipUbuntu' }
    if ($Force)      { $argList += '-Force' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Err2 "提权失败：$($_.Exception.Message)"
        Read-Host "按回车退出"
    }
    exit
}
Write-Ok "管理员权限已确认"

if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }

# ---------- 1. 检查现有 WSL ----------
Write-Step "1. 检查 WSL 组件状态"

$wslProgramDir = Join-Path $env:ProgramFiles 'WSL'
$wslInstalled  = (Test-Path (Join-Path $wslProgramDir 'wsl.exe')) -or
                 (Test-Path (Join-Path $env:SystemRoot 'System32\lxss\tools\kernel'))
if ($wslInstalled) {
    Write-Ok "检测到 WSL 本体已安装：$wslProgramDir"
} else {
    Write-Warn2 "未检测到 WSL 本体（只有 Windows 自带的 wsl.exe 存根）"
}

# ---------- 1.5 虚拟化就绪检查（关键） ----------
# 真正的门槛是「功能性判据」，不是「待重启标记」：
#   功能判据 = vmcompute 服务存在 且 HypervisorPresent=True
# RebootPending 标记可能被 Windows 更新单独置位并长期滞留，
# 只看该标记会把已经重启过的用户错误拦下（实测踩过）。
Write-Step "1.5 虚拟化就绪检查"

$vmcompute = Get-Service -Name 'vmcompute' -ErrorAction SilentlyContinue
$hvPresent = $false
try { $hvPresent = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { }

$needReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
              (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

$cpu = $null
try { $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 } catch { }

if ($cpu) {
    # 重要：一旦 hypervisor 已启动（HypervisorPresent=True），
    # Win32_Processor 的 VirtualizationFirmwareEnabled 与
    # SecondLevelAddressTranslationExtensions 都会返回 False ——
    # 因为 VT-x 已被 hypervisor 接管，WMI 不再暴露原始能力位。
    # 这是 WMI 的已知行为，不代表 BIOS 关了虚拟化。
    # 故仅在 hypervisor「未运行」时，才据该字段判定 BIOS 是否禁用虚拟化。
    if ($hvPresent) {
        Write-Ok "CPU 虚拟化已生效（hypervisor 运行中：$($cpu.Name)）"
    } elseif ($cpu.VirtualizationFirmwareEnabled -eq $false) {
        Write-Err2 "CPU 虚拟化在 BIOS/UEFI 中被禁用，且 hypervisor 未运行。"
        Write-Host "    请进 BIOS/UEFI 开启 Intel VT-x / AMD-V 后重来。"
        Read-Host "按回车退出"; exit 1
    } else {
        Write-Ok "CPU 虚拟化已开启（$($cpu.Name)）"
    }
}

$vmState = if ($vmcompute) { $vmcompute.Status } else { '缺失' }
Write-Host "    vmcompute = $vmState ; HypervisorPresent = $hvPresent ; 待重启标记 = $needReboot"

$ready = ($null -ne $vmcompute) -and $hvPresent

if ($ready) {
    Write-Ok "虚拟化层已就绪"
    if ($needReboot) {
        Write-Warn2 "系统仍有其他待重启项（多半是 Windows 更新），但不影响 WSL，继续。"
    }
    # vmcompute 未运行则尝试拉起
    if ($vmcompute -and $vmcompute.Status -ne 'Running') {
        try { Start-Service vmcompute -ErrorAction Stop; Write-Ok "已启动 vmcompute" }
        catch { Write-Warn2 "vmcompute 启动失败（可能需要重启）：$($_.Exception.Message)" }
    }
} else {
    Write-Host ""
    Write-Err2 "虚拟化层尚未就绪 —— 直接导入发行版会报 HCS_E_SERVICE_NOT_AVAILABLE"
    Write-Host ""
    Write-Host "    常见原因（按概率排序）：" -ForegroundColor Yellow
    Write-Host "      1) 虚拟机平台功能其实还没启用成功（需管理员复查）"
    Write-Host "      2) 有 Windows 更新在待安装，阻塞了功能启用"
    Write-Host "      3) hypervisorlaunchtype 被设为 off"
    Write-Host ""
    Write-Host "    请先运行专用修复脚本（会自动提权）：" -ForegroundColor Cyan
    Write-Host "      powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\5-fix-virtualization.ps1`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    若你确认已处理过，可加 -Force 跳过本检查继续尝试：" -ForegroundColor DarkGray
    Write-Host "      ... -Force" -ForegroundColor DarkGray
    Write-Host ""
    if (-not $Force) { Read-Host "按回车退出"; exit 1 }
    Write-Warn2 "-Force 已指定，跳过检查继续（可能仍会失败）"
}

# ---------- 2. 安装 WSL 本体 ----------
if (-not $SkipWsl -and -not $wslInstalled) {
    Write-Step "2. 下载并安装 WSL 本体"
    $msi = Join-Path $DownloadDir 'wsl.2.7.14.0.x64.msi'
    Write-Host "来源：$WSL_MSI_URL"
    Write-Host "大小：约 247 MB"

    if ((Test-Path $msi) -and ((Get-FileSha256 $msi) -eq $WSL_MSI_SHA256)) {
        Write-Ok "已存在且校验通过的安装包，跳过下载"
    } else {
        Write-Host "开始下载..."
        if (-not (Get-Url -Url $WSL_MSI_URL -OutFile $msi)) {
            Write-Err2 "MSI 下载失败。可改用浏览器手动下载：$WSL_MSI_URL"
            Write-Host "  下载后双击安装，再重新运行本脚本并加 -SkipWsl"
            Read-Host "按回车退出"; exit 1
        }
        $sha = Get-FileSha256 $msi
        if ($sha -eq $WSL_MSI_SHA256) {
            Write-Ok "SHA256 校验通过"
        } else {
            Write-Warn2 "SHA256 不匹配（期望 $WSL_MSI_SHA256，实际 $sha）"
            $go = Read-Host "仍要继续安装？(y/N)"
            if ($go -notin @('y','Y')) { exit 1 }
        }
    }

    Write-Host "安装 MSI（可能弹出 UAC 或需要一两分钟）..."
    $code = Invoke-Native 'msiexec.exe' @('/i', $msi, '/qb', '/norestart')
    if ($code -in @(0, 3010)) {
        Write-Ok "WSL 本体安装完成$(if ($code -eq 3010) { '（建议重启生效）' })"
        $wslInstalled = $true
    } else {
        Write-Warn2 "msiexec 返回码 $code，尝试交互式安装..."
        Invoke-Native 'msiexec.exe' @('/i', $msi) | Out-Null
    }
} else {
    Write-Host "跳过 WSL 本体安装"
}

if ($SkipUbuntu) {
    Write-Step "完成"
    Write-Ok "已跳过发行版安装（-SkipUbuntu）"
    Read-Host "按回车退出"; exit 0
}

# ---------- 3. 下载 Ubuntu 镜像 ----------
Write-Step "3. 下载 Ubuntu 24.04 WSL 镜像"

$wslImage = $null
$useImport = $false

# 先尝试清华镜像（国内直连最快，无需代理）
Write-Host "查询清华镜像目录... $TUNA_NOBLE"
$listing = ''
try {
    $listing = (& curl.exe -s --max-time 20 $TUNA_NOBLE 2>$null) -join "`n"
} catch { }

$tunaFile = $null
if ($listing) {
    $m = [regex]::Matches($listing, 'href="(ubuntu-([\d.]+)-wsl-amd64\.wsl)"')
    if ($m.Count -gt 0) {
        $best = $m | Sort-Object { [version]$_.Groups[2].Value } -Descending | Select-Object -First 1
        $tunaFile = $best.Groups[1].Value
    }
}

if ($tunaFile) {
    $wslImage = Join-Path $DownloadDir $tunaFile
    Write-Ok "找到清华镜像：$tunaFile"
    if (Test-Path $wslImage) {
        Write-Ok "本地已存在，跳过下载"
    } else {
        Write-Host "开始下载（约 300+ MB，清华源通常很快）..."
        if (-not (Get-Url -Url ($TUNA_NOBLE + $tunaFile) -OutFile $wslImage)) {
            Write-Warn2 "清华镜像下载失败，回退官方源"
            $wslImage = $null
        }
    }
}

if (-not $wslImage) {
    # 回退：官方 cloud-images 的 rootfs（用 wsl --import 导入）
    $name = 'ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
    $wslImage = Join-Path $DownloadDir $name
    Write-Host "回退官方源：$CLOUD_ROOTFS"
    if (-not (Test-Path $wslImage)) {
        if (-not (Get-Url -Url $CLOUD_ROOTFS -OutFile $wslImage)) {
            Write-Err2 "镜像下载失败。请用浏览器手动下载后重跑："
            Write-Host "  $CLOUD_ROOTFS"
            Write-Host "  或 $TUNA_NOBLE"
            Read-Host "按回车退出"; exit 1
        }
    }
    $useImport = $true
}

Write-Ok "镜像就绪：$wslImage"

# ---------- 4. 导入发行版 ----------
Write-Step "4. 安装/导入发行版：$DistroName"

# 已存在同名发行版？
$existing = @()
try {
    $existing = @((& wsl.exe -l -q 2>&1) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ })
} catch { }
if ($existing -contains $DistroName) {
    Write-Warn2 "发行版 $DistroName 已存在。"
    $go = Read-Host "是否注销并重新导入？(y/N)"
    if ($go -in @('y','Y')) {
        Invoke-Native 'wsl.exe' @('--terminate', $DistroName) | Out-Null
        Invoke-Native 'wsl.exe' @('--unregister', $DistroName) | Out-Null
    } else {
        Write-Host "保留现有发行版，跳过导入。"
        $SkipUbuntu = $true
    }
}

if (-not $SkipUbuntu) {
    $freeGB = Get-FreeGB $InstallDir
    Write-Host "安装目录：$InstallDir（可用 $freeGB GB）"
    if ($freeGB -lt 20) { Write-Warn2 "可用空间偏小，建议 ≥20 GB" }
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    # 优先用新版 --install --from-file；失败则用 --import
    $code = -1
    if (-not $useImport) {
        Write-Host "尝试：wsl --install --from-file ..."
        $code = Invoke-Native 'wsl.exe' @('--install', '--from-file', $wslImage, '--name', $DistroName, '--location', $InstallDir, '--no-launch')
    }
    if ($code -ne 0) {
        Write-Host "改用：wsl --import $DistroName $InstallDir <镜像>"
        $code = Invoke-Native 'wsl.exe' @('--import', $DistroName, $InstallDir, $wslImage, '--version', '2')
    }

    if ($code -eq 0) {
        Write-Ok "发行版导入完成"
    } else {
        Write-Err2 "导入失败（返回码 $code）"
        Write-Host ""
        # 针对最常见的 HCS_E_SERVICE_NOT_AVAILABLE 给出定向建议
        $vmc = Get-Service -Name 'vmcompute' -ErrorAction SilentlyContinue
        $hv2 = $false
        try { $hv2 = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { }
        if (-not $vmc -or -not $hv2) {
            Write-Warn2 "推断：虚拟机平台尚未生效（vmcompute=$(if($vmc){$vmc.Status}else{'缺失'}), HypervisorPresent=$hv2）"
            Write-Host "    若上面报的是 HCS_E_SERVICE_NOT_AVAILABLE —— 请先重启电脑，再重跑本脚本。" -ForegroundColor Yellow
        }
        Write-Host "  也可手动执行：wsl --import $DistroName `"$InstallDir`" `"$wslImage`" --version 2"
        Read-Host "按回车退出"; exit 1
    }
}

# ---------- 5. 创建 Linux 用户 ----------
Write-Step "5. 创建 Linux 用户：$UserName"

$safeName = ($UserName -replace '[^a-z0-9_-]', '')
if ($safeName -ne $UserName -or -not $safeName) {
    Write-Warn2 "用户名只允许小写字母/数字/下划线/连字符，已修正为：$safeName"
    $UserName = $safeName
}

Invoke-Native 'wsl.exe' @('-d', $DistroName, '-u', 'root', '-e', 'bash', '-lc',
    "id -u $UserName >/dev/null 2>&1 || useradd -m -G sudo -s /bin/bash $UserName") | Out-Null

# 设默认用户
$confCmd = "printf '[user]\ndefault=$UserName\n' > /etc/wsl.conf"
Invoke-Native 'wsl.exe' @('-d', $DistroName, '-u', 'root', '-e', 'bash', '-lc', $confCmd) | Out-Null
Write-Ok "默认用户已设为 $UserName"

Write-Host ""
Write-Warn2 "还需要为 $UserName 设置密码（下面会进入交互，输入两次）"
Invoke-Native 'wsl.exe' @('-d', $DistroName, '-u', 'root', '-e', 'passwd', $UserName) | Out-Null

# 重启发行版让 wsl.conf 生效
Invoke-Native 'wsl.exe' @('--terminate', $DistroName) | Out-Null

# ---------- 6. 完成 ----------
Write-Step "安装完成"
Write-Host ""
Write-Host "  发行版名：$DistroName"
Write-Host "  磁盘位置：$InstallDir"
Write-Host "  Linux 用户：$UserName"
Write-Host ""
Write-Host "接下来：" -ForegroundColor Yellow
Write-Host "  1) 进入 WSL：      wsl -d $DistroName"
Write-Host "  2) 确认版本：      wsl -l -v"
Write-Host "  3) 装项目环境：    bash /mnt/d/workbuddy/FireEmblem\ Realm-in-Ashes/tools/2-setup-project.sh"
Write-Host ""
Write-Host "  提示：仓库必须放在 WSL 内（~/projects/），不要放 /mnt/d 下" -ForegroundColor Yellow
Write-Host "  提示：apt/git 需要配代理，见「环境搭建指引.md」第四步" -ForegroundColor Yellow
Write-Host ""
Read-Host "按回车退出"

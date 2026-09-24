# ============================================================
# 《山河烬》WSL 虚拟化问题诊断与修复
# ------------------------------------------------------------
# 症状：
#   导入发行版报 Wsl/Service/RegisterDistro/CreateVm/HCS/HCS_E_SERVICE_NOT_AVAILABLE
#   或 vmcompute 服务缺失 / HypervisorPresent = False
#
# 本脚本会：
#   1) 全面体检：功能状态 / 服务 / hypervisor 启动开关 / 待重启项
#   2) 修复 hypervisorlaunchtype（设为 auto）
#   3) 若「虚拟机平台」未启用则启用；被卡住时可 -Toggle 重刷一遍
#
# 用法（会自动提权）：
#   powershell -ExecutionPolicy Bypass -File "...\5-fix-virtualization.ps1"
#   powershell -ExecutionPolicy Bypass -File "...\5-fix-virtualization.ps1" -DiagnoseOnly
#   powershell -ExecutionPolicy Bypass -File "...\5-fix-virtualization.ps1" -Toggle
# ============================================================

param(
    [switch]$DiagnoseOnly,
    [switch]$Toggle
)

$ErrorActionPreference = 'Continue'

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
    } catch {
        $out = @("调用出错：$($_.Exception.Message)"); $code = -1
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Output = @($out); Code = $code }
}

# ---------- 自动提权 ----------
if (-not (Test-Admin)) {
    Write-Warn2 "当前不是管理员，正在请求提权（会弹出 UAC，请点「是」）..."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($DiagnoseOnly) { $argList += '-DiagnoseOnly' }
    if ($Toggle)       { $argList += '-Toggle' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList }
    catch { Write-Err2 "提权失败：$($_.Exception.Message)"; Read-Host "按回车退出" }
    exit
}

# ============================================================
# 日志：提权后输出会写到这里，便于把结果回传（含 -DiagnoseOnly）
# ============================================================
$LogFile = Join-Path $env:TEMP 'shanhe-wsl-fix-report.txt'
try {
    Start-Transcript -Path $LogFile -Force | Out-Null
    Write-Host "（日志同步写入：$LogFile）" -ForegroundColor DarkGray
} catch {
    Write-Warn2 "无法启动日志记录：$($_.Exception.Message)"
}

# ============================================================
# 1. 体检
# ============================================================
Write-Step "1. 系统与硬件"

$os = Get-CimInstance Win32_OperatingSystem
Write-Host "  系统      : $($os.Caption) $($os.Version) (Build $($os.BuildNumber))"
Write-Host "  开机时间  : $($os.LastBootUpTime)"
Write-Host "  已运行    : $([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes,1)) 分钟"

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-Host "  CPU       : $($cpu.Name)"
Write-Host "  VT-x/AMD-V: $($cpu.VirtualizationFirmwareEnabled)"
Write-Host "  SLAT      : $($cpu.SecondLevelAddressTranslationExtensions)"

$cs = Get-CimInstance Win32_ComputerSystem
Write-Host "  HypervisorPresent = $($cs.HypervisorPresent)"

if ($cpu.VirtualizationFirmwareEnabled -eq $false) {
    Write-Err2 "CPU 虚拟化在 BIOS/UEFI 中被禁用！请进 BIOS 开启 Intel VT-x / AMD-V。"
}

Write-Step "2. 可选功能状态"

$featureState = @{}
foreach ($feat in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux', 'Microsoft-Hyper-V')) {
    $res = Invoke-Native 'dism.exe' @('/online', '/get-featureinfo', "/featurename:$feat")
    $joined = ($res.Output | ForEach-Object { "$_" }) -join "`n"
    $state = '(未识别)'
    if ($joined -match '(?m)^\s*状态\s*[:：]\s*(.+?)\s*$') { $state = $Matches[1].Trim() }
    elseif ($joined -match '(?m)^\s*State\s*[:：]\s*(.+?)\s*$') { $state = $Matches[1].Trim() }
    elseif ($res.Code -ne 0) { $state = "(查询失败 rc=$($res.Code)，该功能可能不存在)" }
    $featureState[$feat] = $state
    Write-Host ("  {0,-36} {1}" -f $feat, $state)
}

Write-Step "3. 关键服务"

foreach ($s in @('vmcompute', 'HvHost', 'WslService', 'vmms', 'CimFS')) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-14} Status={1,-9} StartType={2}" -f $s, $svc.Status, $svc.StartType) -ForegroundColor $color
    } else {
        Write-Host ("  {0,-14} (不存在)" -f $s) -ForegroundColor Red
    }
}

Write-Step "4. hypervisor 启动开关（bcdedit）"

$bcd = Invoke-Native 'bcdedit.exe' @('/enum')
$bcdText = ($bcd.Output | ForEach-Object { "$_" }) -join "`n"
$launchType = $null
if ($bcdText -match '(?m)^hypervisorlaunchtype\s+(\w+)') { $launchType = $Matches[1] }
if (-not $launchType) {
    # 中文系统可能显示为 虚拟机监控程序启动类型
    if ($bcdText -match '(?m)^\S*hypervisor\S*\s+(\w+)') { $launchType = $Matches[1] }
}
if ($launchType) {
    Write-Host "  hypervisorlaunchtype = $launchType"
    if ($launchType -ieq 'Off') { Write-Err2 "    → 这是关闭状态，hypervisor 不会启动！需改为 Auto。" }
} else {
    Write-Warn2 "  未读到 hypervisorlaunchtype（用 /set 显式设置一次即可）"
}

Write-Step "5. 待重启与待安装更新"

$pendingCbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$pendingWU  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
Write-Host "  CBS RebootPending = $pendingCbs"
Write-Host "  WU  RebootRequired = $pendingWU"

$pendingCount = 0
try {
    $pendingCount = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending' -ErrorAction SilentlyContinue).Count
} catch { }
Write-Host "  PackagesPending 项数 = $pendingCount"
if ($pendingCount -gt 200) {
    Write-Warn2 "  待处理包数量异常多，很可能有 Windows 更新挂起。"
    Write-Warn2 "  建议先到「设置 → Windows 更新」检查并安装完所有更新，再重启。"
}

# ============================================================
# 6. 诊断结论
# ============================================================
Write-Step "6. 诊断结论"

$vmcompute = Get-Service -Name 'vmcompute' -ErrorAction SilentlyContinue
$ready = ($null -ne $vmcompute) -and $cs.HypervisorPresent

if ($ready) {
    Write-Ok "虚拟化层已就绪！可以直接运行 4-install-wsl-manual.ps1 导入发行版。"
} else {
    Write-Err2 "虚拟化层未就绪：vmcompute=$(if($vmcompute){'存在'}else{'缺失'})，HypervisorPresent=$($cs.HypervisorPresent)"
}

if ($DiagnoseOnly) {
    Write-Host "`n（-DiagnoseOnly：不做任何修改）" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host "`n按回车退出"
    exit 0
}

# ============================================================
# 7. 修复
# ============================================================
Write-Step "7. 执行修复"

$needReboot = $false

# 7.1 hypervisorlaunchtype 设为 auto
if ($launchType -and ($launchType -ine 'Auto')) {
    Write-Host "  设置 hypervisorlaunchtype = auto ..."
    $r = Invoke-Native 'bcdedit.exe' @('/set', 'hypervisorlaunchtype', 'auto')
    if ($r.Code -eq 0) { Write-Ok "已设置为 auto"; $needReboot = $true }
    else { Write-Err2 "设置失败（rc=$($r.Code)）" }
} elseif (-not $launchType) {
    Write-Host "  显式写入 hypervisorlaunchtype = auto ..."
    $r = Invoke-Native 'bcdedit.exe' @('/set', 'hypervisorlaunchtype', 'auto')
    if ($r.Code -eq 0) { Write-Ok "已写入 auto"; $needReboot = $true }
} else {
    Write-Ok "hypervisorlaunchtype 已是 auto，无需修改"
}

# 7.2 确保虚拟机平台已启用
$vmpState = $featureState['VirtualMachinePlatform']
if ($vmpState -match '已启用' -and $vmpState -notmatch '挂起') {
    Write-Ok "虚拟机平台已启用"
} else {
    Write-Host "  虚拟机平台当前状态：$vmpState，正在启用 ..."
    if ($Toggle -or $vmpState -match '挂起') {
        Write-Host "  → 先禁用再启用（清除卡住状态）"
        Invoke-Native 'dism.exe' @('/online', '/disable-feature', '/featurename:VirtualMachinePlatform', '/norestart') | Out-Null
    }
    $r = Invoke-Native 'dism.exe' @('/online', '/enable-feature', '/featurename:VirtualMachinePlatform', '/all', '/norestart')
    if ($r.Code -in @(0, 3010)) { Write-Ok "虚拟机平台已启用（待重启生效）"; $needReboot = $true }
    else { Write-Err2 "启用失败（rc=$($r.Code)），请把上面输出发我" }
}

# 7.3 WSL 可选组件
$wslState = $featureState['Microsoft-Windows-Subsystem-Linux']
if ($wslState -match '已启用' -and $wslState -notmatch '挂起') {
    Write-Ok "WSL 可选组件已启用"
} else {
    Write-Host "  WSL 可选组件当前：$wslState，正在启用 ..."
    $r = Invoke-Native 'dism.exe' @('/online', '/enable-feature', '/featurename:Microsoft-Windows-Subsystem-Linux', '/all', '/norestart')
    if ($r.Code -in @(0, 3010)) { Write-Ok "WSL 组件已启用（待重启生效）"; $needReboot = $true }
    else { Write-Err2 "启用失败（rc=$($r.Code)）" }
}

# ============================================================
# 8. 收尾
# ============================================================
Write-Step "8. 下一步"

if ($needReboot) {
    Write-Host "  本次做了修改，需要重启后才生效：" -ForegroundColor Yellow
    Write-Host "    Restart-Computer" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  重启后先验证：" -ForegroundColor Yellow
    Write-Host "    Get-Service vmcompute" -ForegroundColor Cyan
    Write-Host "    (Get-CimInstance Win32_ComputerSystem).HypervisorPresent   # 应为 True" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  两项都正常后，再运行 4-install-wsl-manual.ps1 导入发行版。" -ForegroundColor Yellow
} else {
    Write-Host "  未做修改。若虚拟化层仍不就绪，可能是 Windows 更新阻塞：" -ForegroundColor Yellow
    Write-Host "    1) 设置 → Windows 更新 → 检查更新 → 安装完 → 重启" -ForegroundColor Cyan
    Write-Host "    2) 若仍不行，用 -Toggle 重刷虚拟机平台：5-fix-virtualization.ps1 -Toggle" -ForegroundColor Cyan
}

Write-Host ""
try { Stop-Transcript | Out-Null } catch { }
Write-Host "日志已保存：$LogFile" -ForegroundColor DarkGray
Read-Host "按回车退出"

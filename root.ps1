# ================= 配置 =================
$NcPort           = 34567
$WslDistro        = $null
$WaitSec          = 300
$Marker           = 'exploit chain complete pid='
$CrashMsg         = '[!] 内核崩溃，请重试（EXP 抢内核竞态可能会崩）'
$PrebuiltNames    = @('exploit_static')
$GhostlockDirName = 'Ghostlock-HonorPad9Pro-main'

$ScriptDir = (Get-Location).Path
if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
$logFile    = Join-Path $ScriptDir 'exp_output.log'
$markerFile = Join-Path $ScriptDir 'exp_done.marker'
$GhostlockFallback = $ScriptDir
# =======================================

# ---------- ADB 定位：优先项目自带 ADB，否则用 PATH 里的 adb ----------
$adbLocal = Join-Path $ScriptDir 'tools\adb.exe'
$adbPath  = $null
if (Test-Path $adbLocal) {
    $adbPath = $adbLocal
    Write-Host "使用项目自带 ADB: $adbPath" -ForegroundColor DarkGray
}
else {
    $adbPath = (Get-Command adb -ErrorAction SilentlyContinue).Source
    if (-not $adbPath) {
        Write-Error "未找到 adb: 项目 adb-fastboot-tools\adb.exe 不存在，且 PATH 中也没有 adb"
        exit 1
    }
    Write-Host "未找到项目自带 ADB, 使用 PATH 中的 adb: $adbPath" -ForegroundColor DarkGray
}
function adb { & $script:adbPath @args }

# ---------- 本地 nc 定位：优先项目自带 nc/ncat ----------
$localNcPath  = $null
$localNcNames = @('nc.exe', 'ncat.exe')
$ncSearchDirs = @(
    (Join-Path $ScriptDir 'tools'),
    (Join-Path $ScriptDir 'nc'),
    $ScriptDir
)
foreach ($dir in $ncSearchDirs) {
    foreach ($name in $localNcNames) {
        $candidate = Join-Path $dir $name
        if (Test-Path $candidate) {
            $localNcPath = (Resolve-Path $candidate).Path
            Write-Host "找到项目自带 nc: $localNcPath" -ForegroundColor DarkGray
            break
        }
    }
    if ($localNcPath) { break }
}
if (-not $localNcPath) {
    Write-Host "未找到项目自带 nc, 将尝试 WSL / 系统 ncat / 内置 TCP" -ForegroundColor DarkGray
}

# ---------- 工具函数 ----------
function ConvertTo-WslPath {
    param([string]$WinPath)
    $p = $WinPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return "/mnt/$($Matches[1].ToLower())/$($Matches[2])"
    }
    return $p
}

function Find-GhostlockDir {
    param([string]$BaseDir, [string]$DirName, [string]$Fallback)
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add((Join-Path $BaseDir $DirName))
    $parent = Split-Path $BaseDir -Parent -ErrorAction SilentlyContinue
    if ($parent) { $candidates.Add((Join-Path $parent $DirName)) }
    if ($Fallback) { $candidates.Add($Fallback) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Test-WslReady {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        $out = & wsl.exe -e bash -c "echo __WSL_OK__" 2>$null
        $text = (($out | Out-String) -replace "`0", '').Trim()
        return ($LASTEXITCODE -eq 0 -and $text -match '__WSL_OK__')
    } catch { return $false }
}

function Test-TcpPort {
    param($TargetIp, $TargetPort, $TimeoutMs = 3000)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect($TargetIp, $TargetPort, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.EndConnect($ar)
            return $true
        }
        return $false
    } catch { return $false }
    finally { if ($client) { $client.Close() } }
}

# ---------- 1. 获取设备 IP ----------
$deviceLines = @(adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\s+device\s*$' })
if ($deviceLines.Count -eq 0) { Write-Error "没有找到处于 device 状态的 ADB 设备"; exit 1 }
$serial = ($deviceLines[0].Trim() -split '\s+')[0]

$ips = @()
foreach ($line in $deviceLines) {
    if ($line -match '(\d{1,3}(?:\.\d{1,3}){3}):\d+') { $ips += $Matches[1] }
}
if ($ips.Count -eq 0) {
    if ($deviceLines.Count -eq 1) {
        $route = (adb -s $serial shell ip route 2>$null) -join "`n"
        if ($route -match 'src (\d{1,3}(?:\.\d{1,3}){3})') { $ips += $Matches[1] }
    } else { Write-Error "存在多个 USB 设备, 无法自动确定 IP"; exit 1 }
}
if ($ips.Count -eq 0) { Write-Error "无法获取设备 IP"; exit 1 }
$deviceIp = @($ips)[0]
Write-Host "已获取设备 IP: $deviceIp (serial: $serial)" -ForegroundColor Green
Write-Host "脚本目录: $ScriptDir" -ForegroundColor DarkGray

# ---------- 2. 定位 Ghostlock 源码 + WSL 编译优先 ----------
Write-Host "`n===== [1/5] 获取 EXP 二进制 =====" -ForegroundColor Cyan

$ghostlockRoot = Find-GhostlockDir -BaseDir $ScriptDir -DirName $GhostlockDirName -Fallback $GhostlockFallback
if ($ghostlockRoot) {
    Write-Host "Ghostlock 源码: $ghostlockRoot" -ForegroundColor DarkGray
    $WslBuildOut = Join-Path $ghostlockRoot 'exploit\build\mtk-SDY-AN00_8.0.0.220\bin\exploit_static'
} else {
    Write-Host "未找到 Ghostlock 源码目录 " -ForegroundColor Yellow
    $WslBuildOut = $null
}

$binWin = $null
Write-Host "探测 WSL 可用性..." -NoNewline
$wslReady = Test-WslReady
if ($wslReady) { Write-Host " 可用" -ForegroundColor Green } else { Write-Host " 不可用" -ForegroundColor Yellow }

if ($wslReady -and $ghostlockRoot) {
    Write-Host "使用 WSL 实时编译..." -ForegroundColor Cyan
    $wslRoot = ConvertTo-WslPath $ghostlockRoot
    $buildCmd = "cd $wslRoot/exploit && touch src/slide.c && make CC=aarch64-linux-gnu-gcc PROJECT=mtk-SDY-AN00_8.0.0.220 bin 2>&1 | tail -5"
    $buildOut = wsl bash -c "$buildCmd" 2>&1
    $buildOut | ForEach-Object { Write-Host $_ }

    if ($WslBuildOut -and (Test-Path $WslBuildOut)) {
        $binWin = (Resolve-Path $WslBuildOut).Path
        Write-Host "WSL 编译成功: $binWin" -ForegroundColor Green
    } else {
        Write-Warning "WSL 编译未生成产物, 回退到预编译"
    }
}
elseif ($wslReady -and -not $ghostlockRoot) {
    Write-Warning "WSL 可用但 Ghostlock 源码不在附近, 回退到预编译产物"
}

# 回退：脚本目录 / 当前目录 / WSL 历史产物
if (-not $binWin) {
    $searchDirs = @($ScriptDir)
    if ($PWD.Path -ne $ScriptDir) { $searchDirs += $PWD.Path }

    foreach ($dir in $searchDirs) {
        foreach ($name in $PrebuiltNames) {
            $c = Join-Path $dir $name
            if (Test-Path $c) { $binWin = (Resolve-Path $c).Path; break }
        }
        if ($binWin) { break }
    }
    if (-not $binWin -and $WslBuildOut -and (Test-Path $WslBuildOut)) {
        $binWin = (Resolve-Path $WslBuildOut).Path
    }
    if ($binWin) { Write-Host "使用预编译产物: $binWin" -ForegroundColor Green }
}

if (-not $binWin) {
    Write-Error "既无法通过 WSL 编译, 也未找到预编译产物。请启用 WSL 或把 exploit_static 放到 $ScriptDir"
    exit 1
}

# ---------- 2.5 推送前确认已阅读 README ----------
$readmePath = Join-Path $ScriptDir 'README.md'
Write-Host "`n===== [确认] 运行前请先阅读 README =====" -ForegroundColor Yellow
Write-Host "本工具会获取设备临时 root 权限并关闭 SELinux 与模块签名校验；" -ForegroundColor Yellow
Write-Host "失败时可能导致平板重启（内核启用了 CONFIG_PANIC_ON_OOPS=y）。" -ForegroundColor Yellow
Write-Host "请在确认设备版本精确匹配、并已备份重要数据后再继续。" -ForegroundColor Yellow
if (Test-Path $readmePath) {
    Write-Host "README 路径: $readmePath" -ForegroundColor DarkGray
}
else {
    Write-Host "未找到 README.md，请确认你已了解本工具的风险。" -ForegroundColor Red
}

$answer = Read-Host "是否已阅读 README.md 并确认继续？(输入 Y 继续，其他任意键退出)"
if ($answer -notmatch '^(y|yes)$') {
    Write-Host "已取消。请先阅读 README.md 再运行本脚本。" -ForegroundColor Red
    exit 1
}
Write-Host "已确认，继续推送。" -ForegroundColor Green

# ---------- 3. 推送 ----------
Write-Host "`n===== [2/5] 推送并赋权 =====" -ForegroundColor Cyan
adb push $binWin /data/local/tmp/gl_sdy
adb shell "chmod 755 /data/local/tmp/gl_sdy"
adb shell "sync"

# ---------- 4. 启动 EXP ----------
Write-Host "`n===== [3/5] 启动 EXP（新窗口）=====" -ForegroundColor Cyan
Remove-Item $logFile, $markerFile -ErrorAction SilentlyContinue

$runCmd = 'cd /data/local/tmp && env KSU_RUNDIR=/data/local/tmp/glrun_sdy SLIDE_MCAST_SHIFT=15 SLIDE_MCAST_OPT=44 /data/local/tmp/gl_sdy 2>&1'
$tempPs1 = Join-Path $env:TEMP 'run_exp.ps1'

$ps1Body = @"
`$ErrorActionPreference = 'Continue'
`$logFile = '$logFile'
`$markerFile = '$markerFile'
`$fs = `$null
`$sw = `$null
try {
    `$fs = [System.IO.File]::Open(`$logFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    `$sw = New-Object System.IO.StreamWriter(`$fs)
    `$sw.AutoFlush = `$true
    & '$adbPath' shell "$runCmd" 2>&1 | ForEach-Object {
        Write-Host `$_
        try { `$sw.WriteLine(`$_) } catch {}
        if (`$_.Contains('$Marker')) {
            try { [System.IO.File]::WriteAllText(`$markerFile, `$_) } catch {}
        }
    }
}
finally {
    if (`$sw) { `$sw.Close() }
    if (`$fs) { `$fs.Close() }
}
Write-Host ''
Write-Host '=== EXP ended, press any key ===' -ForegroundColor Yellow
`$null = `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
"@
Set-Content -Path $tempPs1 -Value $ps1Body -Encoding UTF8
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$tempPs1 -WindowStyle Minimized

# ---------- 5. 轮询 marker / 日志 / ADB 状态 ----------
Write-Host "`n===== [4/5] 等待 EXP 成功标记 =====" -ForegroundColor Cyan
Write-Host "匹配: $Marker（最长等 ${WaitSec}s, 每 3s 检测 ADB 状态）" -ForegroundColor DarkGray

function Read-LogLines {
    param($Path)
    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        return $sr.ReadToEnd()
    } catch { return $null }
    finally { if ($sr) { $sr.Close() }; if ($fs) { $fs.Close() } }
}

$found = $false; $crashed = $false
$deadline = (Get-Date).AddSeconds($WaitSec)
$lastLineCnt = 0; $adbCheckCounter = 0; $adbOffCount = 0

while ((Get-Date) -lt $deadline) {
    if (Test-Path $markerFile) { $found = $true; break }

    if (Test-Path $logFile) {
        $content = Read-LogLines -Path $logFile
        if ($null -ne $content -and $content.Length -gt 0) {
            $complete = $content
            if (-not $content.EndsWith("`n")) {
                $idx = $content.LastIndexOf("`n")
                if ($idx -ge 0) { $complete = $content.Substring(0, $idx + 1) } else { $complete = "" }
            }
            if ($complete) {
                $lines = @($complete -split "`r?`n" | Where-Object { $_ -ne '' })
                for ($i = $lastLineCnt; $i -lt $lines.Count; $i++) {
                    Write-Host "[EXP] $($lines[$i])" -ForegroundColor DarkGray
                    if ($lines[$i].Contains($Marker)) { $found = $true }
                }
                $lastLineCnt = $lines.Count
            }
        }
    }
    if ($found) { break }

    $adbCheckCounter++
    if ($adbCheckCounter -ge 6) {
        $adbCheckCounter = 0
        $state = ''
        try { $state = (adb -s $serial get-state 2>$null) -join '' } catch {}
        if ($state -ne 'device') {
            $adbOffCount++
            Write-Host "`n[!] ADB 断开 ($adbOffCount/2)，可能内核崩溃" -ForegroundColor Yellow
            if ($adbOffCount -ge 2) { $crashed = $true; break }
        } else { $adbOffCount = 0 }
    }
    Start-Sleep -Milliseconds 500
}

if (Test-Path $logFile) {
    $content = Read-LogLines -Path $logFile
    if ($content) {
        $lines = @($content -split "`r?`n" | Where-Object { $_ -ne '' })
        for ($i = $lastLineCnt; $i -lt $lines.Count; $i++) {
            Write-Host "[EXP] $($lines[$i])" -ForegroundColor DarkGray
            if ($lines[$i].Contains($Marker)) { $found = $true }
        }
    }
}

if ($found) {
    Write-Host "`n检测到成功标记，准备连接 $($deviceIp):$NcPort" -ForegroundColor Green
    Start-Sleep -Milliseconds 500
}
elseif ($crashed) {
    Write-Host "`n$CrashMsg" -ForegroundColor Red
    Write-Host "EXP 窗口仍保留（已最小化），可点开查看最后输出。" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Warning "等待 ${WaitSec}s 未检测到标记，仍尝试打开 nc 窗口"
}

# ---------- 6. 连接设备（降级链：本地 nc > WSL > 系统 ncat/nc > 内置 TCP） ----------
Write-Host "`n===== [5/5] 连接 $($deviceIp):$NcPort =====" -ForegroundColor Cyan

# 6.1 选择客户端
$clientKind = 'ps'
if ($localNcPath) {
    $clientKind = 'local'
}
elseif ($wslReady) {
    $clientKind = 'wsl'
}
else {
    $sysNcat = Get-Command ncat -ErrorAction SilentlyContinue
    if (-not $sysNcat) { $sysNcat = Get-Command nc -ErrorAction SilentlyContinue }
    if ($sysNcat) {
        $clientKind = 'ncat'
        $ncatPath = $sysNcat.Source
    }
}
Write-Host "连接方式: $clientKind" -ForegroundColor DarkGray

# 6.2 预检（统一用 TcpClient, 不依赖 nc 参数差异）
Write-Host "连通性预检..." -NoNewline
$probeOk = Test-TcpPort -TargetIp $deviceIp -TargetPort $NcPort -TimeoutMs 3000
if ($probeOk) {
    Write-Host " 通过" -ForegroundColor Green
    Write-Host "  $($deviceIp):$NcPort 可连" -ForegroundColor DarkGray
} else {
    Write-Host " 失败" -ForegroundColor Yellow
    Write-Warning "预检失败: 端口未开放 / 网络不通, 仍尝试打开连接窗口 (EXP 可能还没真正监听, 或 WSL2 NAT 阻挡)"
}

# 6.3 启动对应客户端
if ($clientKind -eq 'local') {
    Write-Host "打开本地 nc 窗口: $localNcPath" -ForegroundColor Cyan
    Start-Process -FilePath $localNcPath -ArgumentList @($deviceIp, $NcPort) -WindowStyle Normal
}
elseif ($clientKind -eq 'wsl') {
    $connectSh = Join-Path $env:TEMP 'gl_connect.sh'
    $shLines = @(
        '#!/bin/bash'
        "nc $deviceIp $NcPort"
        'echo'
        'echo "=== nc closed, dropping to bash ==="'
        'exec bash'
    )
    [System.IO.File]::WriteAllText($connectSh, (($shLines -join "`n") + "`n"), [System.Text.Encoding]::ASCII)

    $drive = $connectSh.Substring(0,1).ToLower()
    $rest  = $connectSh.Substring(2).Replace('\','/')
    $wslSh = "/mnt/$drive$rest"

    $argList = @()
    if ($WslDistro) { $argList += @('-d', $WslDistro) }
    $argList += @('bash', "`"$wslSh`"")
    Write-Host "打开 WSL 窗口: $wslSh" -ForegroundColor Cyan
    Start-Process -FilePath 'wsl.exe' -ArgumentList $argList -WindowStyle Normal
}
elseif ($clientKind -eq 'ncat') {
    Write-Host "打开系统 ncat 窗口: $ncatPath" -ForegroundColor Cyan
    Start-Process -FilePath $ncatPath -ArgumentList @($deviceIp, $NcPort) -WindowStyle Normal
}
else {
    $tcpPs1 = Join-Path $env:TEMP 'gl_tcp_client.ps1'
    $tcpBody = @'
param([string]$DeviceIp, [int]$Port)
$ErrorActionPreference = 'Continue'
$client = $null
try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($DeviceIp, $Port)
    $stream = $client.GetStream()
    $stdout = [Console]::OpenStandardOutput()
    $stdin  = [Console]::OpenStandardInput()
    Write-Host "已连接 $DeviceIp`:$Port (Ctrl+C 退出)" -ForegroundColor Green
    $readTask  = $stream.CopyToAsync($stdout)
    $writeTask = $stdin.CopyToAsync($stream)
    [System.Threading.Tasks.Task]::WaitAny(@($readTask, $writeTask)) | Out-Null
}
catch {
    Write-Host "连接/通信失败: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($client) { $client.Close() }
}
Write-Host ''
Write-Host '=== 连接已断开, 按任意键关闭 ===' -ForegroundColor Yellow
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
'@
    Set-Content -Path $tcpPs1 -Value $tcpBody -Encoding UTF8
    Write-Host "打开 PowerShell 内置 TCP 客户端: $tcpPs1" -ForegroundColor Cyan
    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tcpPs1`"",'-DeviceIp',$deviceIp,'-Port',$NcPort)
    Start-Process powershell -ArgumentList $psArgs -WindowStyle Normal
}

Write-Host "`n完成。" -ForegroundColor Green
Write-Host "连接窗口是独立进程, 主脚本退出后仍保留; 关闭它请手动操作。" -ForegroundColor Yellow
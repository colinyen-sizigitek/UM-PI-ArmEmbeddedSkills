<#
.SYNOPSIS
  Read-only check of the Windows dev host for TX8 / MX3 development.

.DESCRIPTION
  Checks: RAM, WSL2 + Ubuntu 22.04, AVX2 (inside WSL), git, cmake (>= 3.16), Python 3.11
  (Microsoft Store stub counts as MISSING), OpenSSH client, ed25519 key, ~/.ssh/config "Host umpi",
  key-based reachability (ssh -o BatchMode=yes umpi true, with timeout), mx_nc inside WSL,
  optional aarch64-linux-gnu-g++-11 inside WSL.
  Prints a table OK / MISSING / FAIL / WARN / SKIP plus advice. Never installs or changes anything.
  Exit code: 0 if all required items are OK (or WARN), 1 otherwise.

.PARAMETER HostAlias
  SSH alias of the board (default: umpi).

.PARAMETER Distro
  WSL distribution to use (default: Ubuntu-22.04 if present, else the default distribution).

.PARAMETER SkipSsh
  Skip the network reachability test.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File host_env_check.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File host_env_check.ps1 -HostAlias umpi -SkipSsh
#>
[CmdletBinding()]
param(
    [string]$HostAlias = 'umpi',
    [string]$Distro = '',
    [switch]$SkipSsh,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

if ($Help) { Get-Help -Detailed $PSCommandPath; exit 0 }

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Item, [string]$Status, [string]$Detail, [string]$Advice, [bool]$Required = $true) {
    $results.Add([pscustomobject]@{ Item = $Item; Status = $Status; Required = $Required; Detail = $Detail; Advice = $Advice })
}

# Run a native program with a timeout; capture stdout/stderr without PowerShell stream wrapping.
function Invoke-Native([string]$File, [string]$Arguments, [int]$TimeoutSec = 20) {
    $r = [pscustomobject]@{ ExitCode = -1; Out = ''; Err = ''; TimedOut = $false; Started = $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    if ([IO.Path]::GetFileNameWithoutExtension($File) -ieq 'wsl') {
        # Ask wsl.exe for UTF-8 instead of UTF-16 (honoured by current WSL builds only).
        $psi.EnvironmentVariables['WSL_UTF8'] = '1'
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start(); $r.Started = $true } catch { $r.Err = $_.Exception.Message; return $r }
    try { $p.StandardInput.Close() } catch { }
    # Read raw bytes: wsl.exe may emit UTF-16LE, everything else UTF-8/ASCII.
    $outMs = New-Object System.IO.MemoryStream
    $errMs = New-Object System.IO.MemoryStream
    $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outMs)
    $errTask = $p.StandardError.BaseStream.CopyToAsync($errMs)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $r.TimedOut = $true
        try { $p.Kill() } catch { }
        return $r
    }
    $p.WaitForExit()
    try { [void]$outTask.Wait(5000); [void]$errTask.Wait(5000) } catch { }
    $r.ExitCode = $p.ExitCode
    $r.Out = (ConvertFrom-Bytes $outMs.ToArray()).Trim()
    $r.Err = (ConvertFrom-Bytes $errMs.ToArray()).Trim()
    return $r
}

# Decode process output: UTF-16LE if it contains NUL bytes (wsl.exe), else UTF-8.
function ConvertFrom-Bytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $hasNul = $false
    foreach ($b in $Bytes) { if ($b -eq 0) { $hasNul = $true; break } }
    if ($hasNul) { $s = [Text.Encoding]::Unicode.GetString($Bytes) } else { $s = [Text.Encoding]::UTF8.GetString($Bytes) }
    return ($s -replace "`0", '').TrimStart([char]0xFEFF)
}

function Get-FirstLine([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return ($s -split "`r?`n")[0].Trim()
}

function Find-Exe([string]$Name) {
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $c) { return $null }
    return $c.Source
}

Write-Host "TX8 dev host check (read-only) - $(Get-Date -Format s)"
Write-Host ""

# --- RAM -------------------------------------------------------------------------------------
try {
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1)
    if ($ramGb -ge 15) { Add-Result 'RAM' 'OK' "$ramGb GB" '' }
    elseif ($ramGb -ge 7.5) { Add-Result 'RAM' 'WARN' "$ramGb GB" '16 GB recommended for mx_nc model compilation' }
    else { Add-Result 'RAM' 'FAIL' "$ramGb GB" '>= 8 GB required for mx_nc; compile models on another x86 host' }
} catch { Add-Result 'RAM' 'WARN' 'could not query' '' $false }

# --- WSL ---------------------------------------------------------------------------------------
$wslExe = Find-Exe 'wsl'
$wslDistro = ''
if ($null -eq $wslExe) {
    Add-Result 'WSL2' 'MISSING' 'wsl.exe not found' 'Engineer runs (admin): wsl --install -d Ubuntu-22.04, then reboot'
} else {
    $w = Invoke-Native $wslExe '-l -v' 30
    if ($w.TimedOut -or $w.ExitCode -ne 0 -or $w.Out -eq '') {
        Add-Result 'WSL2' 'MISSING' (Get-FirstLine ($w.Out + ' ' + $w.Err)) 'Engineer runs (admin): wsl --install -d Ubuntu-22.04'
    } else {
        $lines = $w.Out -split "`r?`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' }
        $distros = @()
        foreach ($l in $lines) {
            $isDefault = $l.TrimStart().StartsWith('*')
            $parts = ($l -replace '^\s*\*?\s*', '') -split '\s+'
            if ($parts.Count -ge 3) {
                $distros += [pscustomobject]@{ Name = $parts[0]; Version = $parts[$parts.Count - 1]; Default = $isDefault }
            }
        }
        $pick = $null
        if ($Distro -ne '') { $pick = $distros | Where-Object { $_.Name -eq $Distro } | Select-Object -First 1 }
        if ($null -eq $pick) { $pick = $distros | Where-Object { $_.Name -match '^Ubuntu-22\.04' } | Select-Object -First 1 }
        if ($null -eq $pick) { $pick = $distros | Where-Object { $_.Default } | Select-Object -First 1 }
        if ($null -eq $pick) {
            Add-Result 'WSL2' 'MISSING' 'no distribution installed' 'Engineer runs: wsl --install -d Ubuntu-22.04'
        } else {
            $wslDistro = $pick.Name
            $names = ($distros | ForEach-Object { "$($_.Name)(v$($_.Version))" }) -join ', '
            if ($pick.Version -ne '2') {
                Add-Result 'WSL2' 'FAIL' "using $wslDistro is WSL$($pick.Version); all: $names" "Engineer runs: wsl --set-version $wslDistro 2"
            } elseif ($wslDistro -notmatch '22\.04') {
                $rel = Invoke-Native $wslExe "-d $wslDistro -e lsb_release -rs" 30
                if ($rel.Out -match '^22\.04') { Add-Result 'WSL2' 'OK' "$wslDistro (v2, Ubuntu 22.04)" '' }
                else { Add-Result 'WSL2' 'WARN' "$wslDistro (v2, release $(Get-FirstLine $rel.Out)); all: $names" 'Ubuntu 22.04 recommended (matches board glibc 2.35): wsl --install -d Ubuntu-22.04' }
            } else {
                Add-Result 'WSL2' 'OK' "$wslDistro (v2); all: $names" ''
            }
        }
    }
}

function Invoke-Wsl([string]$Snippet, [int]$TimeoutSec = 60) {
    $a = ''
    if ($wslDistro -ne '') { $a = "-d $wslDistro " }
    return Invoke-Native $wslExe ($a + '-e bash -lc "' + $Snippet + '"') $TimeoutSec
}

# --- AVX2 (needed by mx_nc on x86) -------------------------------------------------------------
if ($wslDistro -ne '') {
    $avx = Invoke-Wsl 'grep -c -m1 -w avx2 /proc/cpuinfo || true' 60
    if ($avx.TimedOut) { Add-Result 'CPU AVX2' 'WARN' 'WSL timed out' 'Re-run; first WSL start can be slow' $false }
    elseif ($avx.Out -match '^[1-9]') { Add-Result 'CPU AVX2' 'OK' 'avx2 present' '' }
    else { Add-Result 'CPU AVX2' 'FAIL' 'avx2 not reported in WSL' 'mx_nc needs AVX2: compile models on another x86 host or ARM64 Linux (not on the TX8)' }
} else {
    Add-Result 'CPU AVX2' 'SKIP' 'needs WSL to check' '' $false
}

# --- git -----------------------------------------------------------------------------------------
$git = Find-Exe 'git'
if ($null -eq $git) { Add-Result 'git' 'MISSING' '' 'Install Git for Windows (also provides Git Bash for deploy.sh)' }
else {
    $g = Invoke-Native $git '--version' 15
    $acrlf = Invoke-Native $git 'config --global core.autocrlf' 15
    $adv = ''
    if ($acrlf.Out -eq 'true') { $adv = 'core.autocrlf=true converts .sh to CRLF; use input or .gitattributes "*.sh text eol=lf"' }
    if ($adv -eq '') { Add-Result 'git' 'OK' (Get-FirstLine $g.Out) '' }
    else { Add-Result 'git' 'WARN' (Get-FirstLine $g.Out) $adv }
}

# --- cmake ---------------------------------------------------------------------------------------
$cmake = Find-Exe 'cmake'
if ($null -eq $cmake) {
    Add-Result 'cmake (Windows)' 'MISSING' '' 'Optional on Windows if you build on the board/WSL; else winget install Kitware.CMake' $false
} else {
    $c = Invoke-Native $cmake '--version' 15
    $v = Get-FirstLine $c.Out
    $ok = $false
    if ($v -match '(\d+)\.(\d+)') { $ok = ([int]$Matches[1] -gt 3) -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 16) }
    if ($ok) { Add-Result 'cmake (Windows)' 'OK' $v '' $false } else { Add-Result 'cmake (Windows)' 'FAIL' $v 'CMake >= 3.16 required' $false }
}
if ($wslDistro -ne '') {
    $cw = Invoke-Wsl 'cmake --version 2>/dev/null | head -1' 60
    if ($cw.Out -match 'cmake version (\d+)\.(\d+)') {
        $ok = ([int]$Matches[1] -gt 3) -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 16)
        if ($ok) { Add-Result 'cmake (WSL)' 'OK' $cw.Out '' $false } else { Add-Result 'cmake (WSL)' 'FAIL' $cw.Out 'In WSL: sudo apt install cmake (>= 3.16)' $false }
    } else { Add-Result 'cmake (WSL)' 'MISSING' '' 'In WSL (engineer runs): sudo apt install cmake' $false }
}

# --- Python 3.11 (Windows) -------------------------------------------------------------------
$pyOk = $false; $pyDetail = ''
$pyLauncher = Find-Exe 'py'
if ($null -ne $pyLauncher) {
    $p = Invoke-Native $pyLauncher '-3.11 --version' 15
    if ($p.ExitCode -eq 0 -and ($p.Out + $p.Err) -match 'Python 3\.11') { $pyOk = $true; $pyDetail = "py -3.11: $(Get-FirstLine ($p.Out + $p.Err))" }
}
if (-not $pyOk) {
    $python = Find-Exe 'python'
    if ($null -ne $python) {
        $isStub = $python -match '\\WindowsApps\\'
        $p = Invoke-Native $python '--version' 15
        $txt = Get-FirstLine ($p.Out + ' ' + $p.Err)
        if ($p.ExitCode -eq 0 -and $txt -match 'Python 3\.11') { $pyOk = $true; $pyDetail = "python: $txt" }
        elseif ($p.ExitCode -eq 0 -and $txt -match 'Python 3\.(\d+)') { $pyDetail = "python: $txt (not 3.11)" }
        elseif ($isStub) { $pyDetail = 'only the Microsoft Store stub (WindowsApps\python.exe)' }
        else { $pyDetail = "python failed: $txt" }
    } else { $pyDetail = 'not found' }
}
if ($pyOk) { Add-Result 'Python 3.11 (Windows)' 'OK' $pyDetail '' }
else { Add-Result 'Python 3.11 (Windows)' 'MISSING' $pyDetail 'Install 3.11 from python.org or winget install Python.Python.3.11; disable Store alias (Settings > Apps > App execution aliases)' }

# --- OpenSSH -----------------------------------------------------------------------------------
$ssh = Find-Exe 'ssh'
if ($null -eq $ssh) {
    Add-Result 'OpenSSH client' 'MISSING' '' 'Enable Windows optional feature "OpenSSH Client" (engineer, Settings > Optional features)'
} else {
    $s = Invoke-Native $ssh '-V' 15
    Add-Result 'OpenSSH client' 'OK' (Get-FirstLine ($s.Err + ' ' + $s.Out)) ''
}

$sshDir = Join-Path $HOME '.ssh'
$keyFiles = @('id_ed25519', 'id_ecdsa', 'id_rsa') | Where-Object { Test-Path (Join-Path $sshDir $_) }
if (@($keyFiles).Count -gt 0) {
    $st = 'OK'; $adv = ''
    if (-not (@($keyFiles) -contains 'id_ed25519')) { $st = 'WARN'; $adv = 'ed25519 recommended: ssh-keygen -t ed25519' }
    Add-Result 'SSH key' $st (@($keyFiles) -join ', ') $adv
} else {
    Add-Result 'SSH key' 'MISSING' "no key in $sshDir" 'ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519, then copy the .pub to the board (see dev-host-setup.md 2.6)'
}

$cfg = Join-Path $sshDir 'config'
$aliasFound = $false
if (Test-Path $cfg) {
    $pattern = '^\s*Host\s+(.*\s)?' + [regex]::Escape($HostAlias) + '(\s|$)'
    $aliasFound = $null -ne (Select-String -Path $cfg -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -First 1)
}
if ($aliasFound) { Add-Result "ssh alias $HostAlias" 'OK' $cfg '' }
else { Add-Result "ssh alias $HostAlias" 'MISSING' "no 'Host $HostAlias' in $cfg" 'Add Host block (HostName, User, IdentityFile, ServerAliveInterval) - see dev-host-setup.md 2.7' }

if ($SkipSsh) {
    Add-Result "$HostAlias reachable" 'SKIP' '-SkipSsh' '' $false
} elseif ($null -eq $ssh -or -not $aliasFound) {
    Add-Result "$HostAlias reachable" 'SKIP' 'ssh or alias missing' ''
} else {
    $r = Invoke-Native $ssh "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes $HostAlias true" 20
    if ($r.TimedOut) { Add-Result "$HostAlias reachable" 'FAIL' 'timed out after 20 s' 'Check board power/network/IP; ssh -v umpi true' }
    elseif ($r.ExitCode -eq 0) { Add-Result "$HostAlias reachable" 'OK' 'key auth works' '' }
    else {
        $e = Get-FirstLine $r.Err
        $adv = 'Run ssh -v ' + $HostAlias + ' true'
        if ($e -match 'Permission denied') { $adv = 'Copy your public key to the board (dev-host-setup.md 2.6)' }
        elseif ($e -match 'Host key verification failed|REMOTE HOST IDENTIFICATION') { $adv = 'Host key unknown/changed: connect once interactively or, after confirming a re-flash, ssh-keygen -R <host>' }
        elseif ($e -match 'timed out|No route|Could not resolve') { $adv = 'Check HostName/IP and network' }
        Add-Result "$HostAlias reachable" 'FAIL' $e $adv
    }
}

# --- mx_nc and cross g++ inside WSL ------------------------------------------------------------
if ($wslDistro -ne '') {
    $snip = 'p=$(command -v mx_nc || ls ~/mx/bin/mx_nc ~/.venv/bin/mx_nc ~/memryx/bin/mx_nc 2>/dev/null | head -1); [ -z $p ] && exit 127; echo path=$p; $p --version 2>&1 | head -2; exit 0'
    $m = Invoke-Wsl $snip 90
    if ($m.TimedOut) { Add-Result 'mx_nc (WSL)' 'WARN' 'timed out' 'Re-run' }
    elseif ($m.ExitCode -eq 0) { Add-Result 'mx_nc (WSL)' 'OK' (($m.Out -split "`r?`n") -join ' | ') 'Match SDK version to board runtime (dpkg -l | grep memx)' }
    else { Add-Result 'mx_nc (WSL)' 'MISSING' '' 'In WSL venv: pip install --extra-index-url https://developer.memryx.com/pip memryx (see skill um-pi-mx3-model-compile)' }

    $x = Invoke-Wsl 'aarch64-linux-gnu-g++-11 --version 2>/dev/null | head -1' 60
    if ($x.Out -ne '') { Add-Result 'aarch64 g++-11 (WSL)' 'OK' $x.Out '' $false }
    else { Add-Result 'aarch64 g++-11 (WSL)' 'SKIP' 'not installed (optional)' 'Only for cross-compile: sudo apt install g++-11-aarch64-linux-gnu' $false }
} else {
    Add-Result 'mx_nc (WSL)' 'MISSING' 'WSL not available' 'Install WSL2 Ubuntu 22.04 first'
    Add-Result 'aarch64 g++-11 (WSL)' 'SKIP' 'WSL not available' '' $false
}

# --- Report ---------------------------------------------------------------------------------------
$results | Select-Object Item, Status, @{ n = 'Req'; e = { if ($_.Required) { 'yes' } else { 'opt' } } }, Detail, Advice |
    Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host

$bad = @($results | Where-Object { $_.Required -and ($_.Status -eq 'MISSING' -or $_.Status -eq 'FAIL') })
if ($bad.Count -gt 0) {
    Write-Host ("{0} required item(s) need attention. Nothing was installed or changed." -f $bad.Count)
    exit 1
}
Write-Host 'All required items OK. Nothing was installed or changed.'
exit 0

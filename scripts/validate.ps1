<#
.SYNOPSIS
  Validate the TX8 / MX3 Agent Skills suite (PowerShell 5.1; same checks as validate.py).

.DESCRIPTION
  For every skills/*/SKILL.md:
    - YAML frontmatter present; only keys name, description, license, compatibility, metadata
    - name: ^[a-z0-9]+(-[a-z0-9]+)*$, <= 64 chars, equals the folder name
    - description: 1..1024 chars, contains "Use when" (warn if not a double-quoted single line)
    - compatibility <= 500 chars; metadata is a flat map of string values
    - body line count 80..150 (warning outside), error above 500
    - relative markdown links in SKILL.md and references/*.md resolve to existing files, stay inside
      the skill folder, and SKILL.md links go at most one directory deep
    - no file under skills/ larger than 500 KB (*.csv: warning only)
  Plus: shared/AGENTS.tx8.md smaller than 24 KB.
  Exit code: 0 = no errors, 1 = errors, 2 = usage problem.

.EXAMPLE
  powershell -NoProfile -File scripts\validate.ps1
  powershell -NoProfile -File scripts\validate.ps1 -Skill um-pi-platform
#>
[CmdletBinding()]
param(
    [string]$Repo = '',
    [string[]]$Skill = @(),
    [switch]$Quiet,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help -Detailed $PSCommandPath; exit 0 }

if ($Repo -eq '') { $Repo = Split-Path -Parent $PSScriptRoot }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$SkillsRoot = Join-Path $Repo 'skills'
if (-not (Test-Path -LiteralPath $SkillsRoot -PathType Container)) { Write-Host "error: $SkillsRoot not found"; exit 2 }

$AllowedKeys = @('name', 'description', 'license', 'compatibility', 'metadata')
$NameRe = '^[a-z0-9]+(-[a-z0-9]+)*$'
$LinkRe = '!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+["''][^"'']*["''])?\s*\)'
$NonStringRe = '^(?i)(-?\d+(\.\d+)?([eE][-+]?\d+)?|true|false|yes|no|on|off|null|~)$'
$MaxFile = 500 * 1024
$MaxAgents = 24 * 1024
$BodyMin = 80; $BodyMax = 150; $BodyHard = 500
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function New-Report([string]$Name) {
    return [pscustomobject]@{ Name = $Name; Errors = (New-Object System.Collections.Generic.List[string]); Warnings = (New-Object System.Collections.Generic.List[string]); BodyLines = 0 }
}

# Returns @(value, wasQuoted)
function Get-Scalar([string]$Raw, $Rep, [string]$Key) {
    $v = $Raw.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        $inner = $v.Substring(1, $v.Length - 2)
        $inner = $inner.Replace('\"', '"').Replace('\\', '\')
        return @($inner, $true)
    }
    if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
        return @($v.Substring(1, $v.Length - 2).Replace("''", "'"), $true)
    }
    if ($v.StartsWith('"') -or $v.StartsWith("'")) { $Rep.Errors.Add("frontmatter '$Key': unterminated quoted string") }
    $v = [regex]::Replace($v, '\s+#.*$', '')
    return @($v, $false)
}

function Remove-Code([string[]]$Lines) {
    $out = New-Object System.Collections.Generic.List[string]
    $inFence = $false
    foreach ($ln in $Lines) {
        if ($ln -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $out.Add([regex]::Replace($ln, '`[^`]*`', ''))
    }
    return ($out -join "`n")
}

function Test-Links([string]$MdPath, [string]$SkillDir, $Rep, [bool]$FromSkillMd) {
    $lines = [IO.File]::ReadAllLines($MdPath, $Utf8)
    $text = Remove-Code $lines
    $skillFull = [IO.Path]::GetFullPath($SkillDir).TrimEnd('\') + '\'
    $relName = $MdPath.Substring($skillFull.Length).Replace('\', '/')
    $mdDir = Split-Path -Parent $MdPath
    foreach ($m in [regex]::Matches($text, $LinkRe)) {
        $target = $m.Groups[1].Value
        if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -or $target.StartsWith('#')) { continue }
        $pathPart = ($target -split '#', 2)[0]
        $pathPart = ($pathPart -split '\?', 2)[0]
        if ($pathPart -eq '') { continue }
        $resolved = [IO.Path]::GetFullPath((Join-Path $mdDir ($pathPart.Replace('/', '\'))))
        if (-not $resolved.StartsWith($skillFull, [StringComparison]::OrdinalIgnoreCase)) {
            $Rep.Errors.Add("${relName}: link '$target' leaves the skill folder (name the sibling skill instead)")
            continue
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            $Rep.Errors.Add("${relName}: broken link '$target'")
            continue
        }
        $inside = $resolved.Substring($skillFull.Length).TrimEnd('\')
        $depth = @($inside.Split('\') | Where-Object { $_ -ne '' }).Count
        if ($FromSkillMd -and $depth -gt 2) {
            $Rep.Errors.Add("${relName}: link '$target' is more than one level deep (use references/<file>)")
        }
    }
}

function Test-Skill([IO.DirectoryInfo]$Dir) {
    $rep = New-Report $Dir.Name
    $skillMd = Join-Path $Dir.FullName 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) { $rep.Errors.Add('SKILL.md missing'); return $rep }

    $bytes = [IO.File]::ReadAllBytes($skillMd)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $rep.Warnings.Add('SKILL.md has a UTF-8 BOM') }
    $text = $Utf8.GetString($bytes).TrimStart([char]0xFEFF)
    $lines = $text -split "`r?`n"
    # split() leaves a trailing empty element for a final newline; drop it
    if ($lines.Count -gt 1 -and $lines[$lines.Count - 1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }

    $parsed = $false
    $top = @{}; $raw = @{}; $meta = @{}; $body = @()
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') {
        $rep.Errors.Add("missing YAML frontmatter (file must start with '---')")
    } else {
        $end = -1
        for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $end = $i; break } }
        if ($end -lt 0) { $rep.Errors.Add("frontmatter not closed with '---'") }
        else {
            $parsed = $true
            $fm = @(); if ($end -gt 1) { $fm = $lines[1..($end - 1)] }
            if ($end + 1 -le $lines.Count - 1) { $body = @($lines[($end + 1)..($lines.Count - 1)]) }
            $current = $null; $blockStyle = $null; $blockLines = New-Object System.Collections.Generic.List[string]
            $flush = {
                if ($null -ne $current -and $null -ne $blockStyle) {
                    $sep = ' '; if ($blockStyle.StartsWith('|')) { $sep = "`n" }
                    $top[$current] = (($blockLines | ForEach-Object { $_.Trim() }) -join $sep).Trim()
                }
            }
            foreach ($ln in $fm) {
                if ($ln.Trim() -eq '' -or $ln.TrimStart().StartsWith('#')) { continue }
                if ($ln[0] -ne ' ' -and $ln[0] -ne "`t") {
                    . $flush; $blockStyle = $null; $blockLines.Clear()
                    $m = [regex]::Match($ln, '^([A-Za-z0-9_-]+):(.*)$')
                    if (-not $m.Success) { $rep.Errors.Add("cannot parse frontmatter line: '$ln'"); $current = $null; continue }
                    $key = $m.Groups[1].Value; $rest = $m.Groups[2].Value.Trim()
                    if ($top.ContainsKey($key)) { $rep.Errors.Add("duplicate frontmatter key '$key'") }
                    $current = $key; $raw[$key] = $rest
                    if (@('|', '>', '|-', '>-', '|+', '>+') -contains $rest) { $blockStyle = $rest; $top[$key] = '' }
                    elseif ($rest -eq '') { if ($key -eq 'metadata') { $top[$key] = $meta } else { $top[$key] = '' } }
                    else { $top[$key] = (Get-Scalar $rest $rep $key)[0] }
                } else {
                    if ($null -ne $blockStyle) { $blockLines.Add($ln) }
                    elseif ($current -eq 'metadata') {
                        $m = [regex]::Match($ln, '^\s+([A-Za-z0-9_.-]+):(.*)$')
                        if (-not $m.Success) { $rep.Errors.Add("cannot parse metadata line: '$ln'"); continue }
                        $k = $m.Groups[1].Value; $rest = $m.Groups[2].Value.Trim()
                        if ($rest -eq '') { $rep.Errors.Add("metadata.${k}: nested maps/lists are not allowed (values must be strings)"); continue }
                        if ($rest -match '^(\[|\{|- |\||>)') { $rep.Errors.Add("metadata.${k}: value must be a string"); continue }
                        $sv = Get-Scalar $rest $rep "metadata.$k"
                        if (-not $sv[1] -and $sv[0] -match $NonStringRe) { $rep.Errors.Add("metadata.${k}: '$($sv[0])' is not a YAML string; quote it") }
                        $meta[$k] = $sv[0]
                    } else { $rep.Errors.Add("unexpected indented line in frontmatter: '$ln'") }
                }
            }
            . $flush
        }
    }

    if ($parsed) {
        foreach ($k in $top.Keys) { if ($AllowedKeys -notcontains $k) { $rep.Errors.Add("frontmatter key '$k' not allowed (allowed: $($AllowedKeys -join ', '))") } }
        $name = ''; if ($top.ContainsKey('name')) { $name = [string]$top['name'] }
        if ($name -eq '') { $rep.Errors.Add('name missing') }
        else {
            if ($name -cnotmatch $NameRe) { $rep.Errors.Add("name '$name' does not match ^[a-z0-9]+(-[a-z0-9]+)*$") }
            if ($name.Length -gt 64) { $rep.Errors.Add("name longer than 64 chars ($($name.Length))") }
            if ($name -cne $Dir.Name) { $rep.Errors.Add("name '$name' != folder name '$($Dir.Name)'") }
        }
        $desc = ''; if ($top.ContainsKey('description')) { $desc = [string]$top['description'] }
        if ($desc.Trim() -eq '') { $rep.Errors.Add('description missing or empty') }
        else {
            if ($desc.Length -gt 1024) { $rep.Errors.Add("description longer than 1024 chars ($($desc.Length))") }
            if (-not $desc.Contains('Use when')) { $rep.Errors.Add("description does not contain 'Use when'") }
            if (-not ([string]$raw['description']).StartsWith('"')) { $rep.Warnings.Add('description should be a single-line double-quoted string') }
        }
        if ($top.ContainsKey('compatibility')) {
            $c = [string]$top['compatibility']
            if ($c.Length -gt 500) { $rep.Errors.Add("compatibility longer than 500 chars ($($c.Length))") }
        }
        if ($top.ContainsKey('metadata') -and -not ($top['metadata'] -is [hashtable])) { $rep.Errors.Add('metadata must be a map of string values') }

        $n = $body.Count
        while ($n -gt 0 -and $body[$n - 1].Trim() -eq '') { $n-- }
        $rep.BodyLines = $n
        if ($n -gt $BodyHard) { $rep.Errors.Add("body has $n lines (> $BodyHard)") }
        elseif ($n -lt $BodyMin -or $n -gt $BodyMax) { $rep.Warnings.Add("body has $n lines (target $BodyMin-$BodyMax)") }
    }

    Test-Links $skillMd $Dir.FullName $rep $true
    $refDir = Join-Path $Dir.FullName 'references'
    if (Test-Path -LiteralPath $refDir -PathType Container) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $refDir -Directory)) { $rep.Errors.Add("references/$($sub.Name)/ is a subfolder; references must be one level deep") }
        foreach ($md in @(Get-ChildItem -LiteralPath $refDir -File -Filter '*.md' | Sort-Object Name)) { Test-Links $md.FullName $Dir.FullName $rep $false }
    }

    $skillFull = $Dir.FullName.TrimEnd('\') + '\'
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir.FullName -Recurse -File -Force)) {
        if ($f.Length -gt $MaxFile) {
            $rel = $f.FullName.Substring($skillFull.Length).Replace('\', '/')
            $kb = [math]::Floor($f.Length / 1024)
            if ($f.Extension -ieq '.csv') { $rep.Warnings.Add("$rel is $kb KB (> 500 KB, csv allowed)") }
            else { $rep.Errors.Add("$rel is $kb KB (> 500 KB)") }
        }
    }
    return $rep
}

# ---- main ------------------------------------------------------------------------------------
$totalErr = 0; $totalWarn = 0
$agents = Join-Path $Repo 'shared\AGENTS.tx8.md'
if (-not (Test-Path -LiteralPath $agents -PathType Leaf)) { Write-Host 'ERROR shared/AGENTS.tx8.md missing'; $totalErr++ }
else {
    $len = (Get-Item -LiteralPath $agents).Length
    if ($len -ge $MaxAgents) { Write-Host "ERROR shared/AGENTS.tx8.md is $len bytes (must be < $MaxAgents)"; $totalErr++ }
    elseif (-not $Quiet) { Write-Host "OK    shared/AGENTS.tx8.md ($len bytes)" }
}

$dirs = @(Get-ChildItem -LiteralPath $SkillsRoot -Directory | Sort-Object Name)
if ($Skill.Count -gt 0) {
    $want = @($Skill | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    foreach ($w in $want) { if (-not ($dirs | Where-Object { $_.Name -eq $w })) { Write-Host "ERROR skill '$w' not found"; $totalErr++ } }
    $dirs = @($dirs | Where-Object { $want -contains $_.Name })
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($d in $dirs) {
    $rep = Test-Skill $d
    $totalErr += $rep.Errors.Count; $totalWarn += $rep.Warnings.Count
    foreach ($e in $rep.Errors) { Write-Host "ERROR [$($rep.Name)] $e" }
    foreach ($w in $rep.Warnings) { Write-Host "WARN  [$($rep.Name)] $w" }
    $status = 'OK'
    if ($rep.Errors.Count -gt 0) { $status = 'FAIL' } elseif ($rep.Warnings.Count -gt 0) { $status = 'WARN' }
    $rows.Add([pscustomobject]@{ Skill = $rep.Name; Status = $status; Body = $rep.BodyLines; Err = $rep.Errors.Count; Warn = $rep.Warnings.Count })
}

Write-Host ''
Write-Host ('{0,-28} {1,-6} {2,5} {3,4} {4,5}' -f 'Skill', 'Status', 'Body', 'Err', 'Warn')
Write-Host ('{0,-28} {1,-6} {2,5} {3,4} {4,5}' -f ('-' * 28), ('-' * 6), ('-' * 5), ('-' * 4), ('-' * 5))
foreach ($r in $rows) { Write-Host ('{0,-28} {1,-6} {2,5} {3,4} {4,5}' -f $r.Skill, $r.Status, $r.Body, $r.Err, $r.Warn) }
Write-Host ''
Write-Host "$($rows.Count) skill(s), $totalErr error(s), $totalWarn warning(s)"
if ($totalErr -gt 0) { exit 1 }
exit 0

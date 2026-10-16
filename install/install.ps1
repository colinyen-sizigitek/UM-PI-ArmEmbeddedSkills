<#
.SYNOPSIS
  Install the TX8 / MX3 Agent Skills into Claude Code, OpenAI Codex and/or Google Antigravity.

.DESCRIPTION
  Copies <repo>/skills/<name> folders (no symlinks) to the agent skill locations:

    Project scope (-Scope project, default):
      Claude Code          <proj>/.claude/skills/<name>
      Codex, Antigravity   <proj>/.agents/skills/<name>
      + merges shared/AGENTS.tx8.md into <proj>/AGENTS.md (managed block between
        "<!-- tx8-skills:begin" and "<!-- tx8-skills:end -->"; replaced if present, else appended)
      + Claude target: ensures <proj>/CLAUDE.md contains a line "@AGENTS.md"

    User scope (-Scope user):
      Claude Code          ~/.claude/skills/<name>
      Codex                ~/.agents/skills/<name>
      Antigravity          ~/.gemini/config/skills/<name>
                           (older Antigravity builds used ~/.gemini/antigravity/skills; this
                            installer does not write there -- copy manually if your build needs it)
      Always-on rules (AGENTS.md) are NOT installed in user scope; merge them per project.

  Every installed skill folder gets a marker file ".tx8-skills" (version + source path). An existing
  destination folder is overwritten only if it carries the marker or -Force is given; otherwise it
  is skipped with a warning. Text files are written as UTF-8 without BOM.

.PARAMETER Target
  claude | codex | antigravity | all (default all)
.PARAMETER Scope
  project | user (default project)
.PARAMETER ProjectPath
  Target project directory for project scope (default: current directory). Must exist.
.PARAMETER Skills
  Optional subset of skill names, e.g. -Skills tx8-platform,mx3-model-compile
.PARAMETER DryRun
  Print what would be done; write nothing.
.PARAMETER Force
  Overwrite destination skill folders that were not installed by this installer.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1 -ProjectPath C:\work\drone-app -DryRun
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1 -Target claude -Scope user
#>
[CmdletBinding()]
param(
    [ValidateSet('claude', 'codex', 'antigravity', 'all')]
    [string]$Target = 'all',
    [ValidateSet('project', 'user')]
    [string]$Scope = 'project',
    [string]$ProjectPath = '',
    [string[]]$Skills = @(),
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help -Detailed $PSCommandPath; exit 0 }

$SuiteVersion = '1.0.0'
$MarkerName = '.tx8-skills'
$BeginTag = '<!-- tx8-skills:begin'
$EndTag = '<!-- tx8-skills:end -->'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SkillsRoot = Join-Path $RepoRoot 'skills'
$SharedAgents = Join-Path $RepoRoot 'shared\AGENTS.tx8.md'
$versionFile = Join-Path $RepoRoot 'VERSION'
if (Test-Path $versionFile) { $SuiteVersion = ([IO.File]::ReadAllText($versionFile)).Trim() }

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}
function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }

# ---- resolve skills ---------------------------------------------------------------------------
if (-not (Test-Path $SkillsRoot)) { throw "skills folder not found: $SkillsRoot" }
$available = @(Get-ChildItem -Path $SkillsRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object { $_.Name })
$selected = @()
$expanded = @()
foreach ($s in $Skills) { $expanded += ($s -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } }
if ($expanded.Count -gt 0) {
    foreach ($s in $expanded) {
        if ($available -contains $s) { $selected += $s } else { Write-Warning "skill '$s' not found in $SkillsRoot (skipped)" }
    }
} else { $selected = $available }
if ($selected.Count -eq 0) { throw 'no skills to install' }

# ---- resolve destinations ---------------------------------------------------------------------
$targets = @()
if ($Target -eq 'all') { $targets = @('claude', 'codex', 'antigravity') } else { $targets = @($Target) }

if ($Scope -eq 'project') {
    if ($ProjectPath -eq '') { $ProjectPath = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { throw "ProjectPath does not exist: $ProjectPath" }
    $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
}

# destination root -> list of agent labels (Codex and Antigravity share .agents/skills in project scope)
$destRoots = New-Object System.Collections.Specialized.OrderedDictionary
foreach ($t in $targets) {
    $root = ''
    if ($Scope -eq 'project') {
        if ($t -eq 'claude') { $root = Join-Path $ProjectPath '.claude\skills' } else { $root = Join-Path $ProjectPath '.agents\skills' }
    } else {
        if ($t -eq 'claude') { $root = Join-Path $HOME '.claude\skills' }
        elseif ($t -eq 'codex') { $root = Join-Path $HOME '.agents\skills' }
        else { $root = Join-Path $HOME '.gemini\config\plugins\arm-embedded-skills\skills' }
    }
    if ($destRoots.Contains($root)) { $destRoots[$root] = $destRoots[$root] + '+' + $t } else { $destRoots.Add($root, $t) }
}

$mode = 'INSTALL'
if ($DryRun) { $mode = 'DRY RUN (nothing is written)' }
Write-Host "TX8 skills installer $SuiteVersion  [$mode]"
Write-Host "  source : $SkillsRoot"
Write-Host "  scope  : $Scope$(if ($Scope -eq 'project') { "  ($ProjectPath)" })"
Write-Host "  targets: $($targets -join ', ')"
Write-Host "  skills : $($selected -join ', ')"
Write-Host ''

$summary = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$Agent, [string]$Item, [string]$Action, [string]$Path) {
    $summary.Add([pscustomobject]@{ Agent = $Agent; Item = $Item; Action = $Action; Path = $Path })
}

function Get-SkillVersion([string]$SkillDir) {
    $md = Read-Utf8 (Join-Path $SkillDir 'SKILL.md')
    $m = [regex]::Match($md, '(?m)^\s+version:\s*"?([^"\r\n]+)"?')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return 'unknown'
}

# ---- copy skills ------------------------------------------------------------------------------
foreach ($root in $destRoots.Keys) {
    $agent = $destRoots[$root]
    foreach ($name in $selected) {
        $src = Join-Path $SkillsRoot $name
        $dst = Join-Path $root $name
        $action = 'install'
        if (Test-Path -LiteralPath $dst) {
            $managed = Test-Path -LiteralPath (Join-Path $dst $MarkerName)
            if ($managed) { $action = 'update' }
            elseif ($Force) { $action = 'overwrite (-Force)' }
            else {
                Write-Warning "$dst exists and was not installed by tx8-skills; skipped (use -Force to overwrite)"
                Add-Row $agent $name 'SKIPPED (unmanaged)' $dst
                continue
            }
        }
        if ($DryRun) { Add-Row $agent $name ("would " + $action) $dst; continue }

        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        # $dst does not exist here, so Copy-Item creates it as a full copy of $src (incl. dot files).
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        $marker = @(
            '# tx8-skills marker: this folder is managed by ArmEmbeddedSkills/install (safe to overwrite by the installer)'
            "suite_version=$SuiteVersion"
            "skill=$name"
            "skill_version=$(Get-SkillVersion $src)"
            "source=$src"
            "agent=$agent"
            "scope=$Scope"
            "installed=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        ) -join "`n"
        Write-Utf8 (Join-Path $dst $MarkerName) ($marker + "`n")
        Add-Row $agent $name $action $dst
    }
}

# ---- always-on rules (project scope) ---------------------------------------------------------
if ($Scope -eq 'project') {
    if (-not (Test-Path $SharedAgents)) { throw "missing $SharedAgents" }
    $srcText = (Read-Utf8 $SharedAgents) -replace "`r`n", "`n"
    $bi = $srcText.IndexOf($BeginTag)
    $ei = $srcText.IndexOf($EndTag)
    if ($bi -lt 0 -or $ei -lt $bi) { throw "shared/AGENTS.tx8.md lacks the tx8-skills begin/end markers" }
    $block = $srcText.Substring($bi, $ei + $EndTag.Length - $bi)
    $titleMatch = [regex]::Match($srcText.Substring(0, $bi), '(?m)^# .+$')
    $title = ''
    if ($titleMatch.Success) { $title = $titleMatch.Value.Trim() }

    $agentsPath = Join-Path $ProjectPath 'AGENTS.md'
    $agentsAction = ''
    $newText = $null
    if (-not (Test-Path -LiteralPath $agentsPath)) {
        $agentsAction = 'create'
        $newText = $srcText
    } else {
        $cur = Read-Utf8 $agentsPath
        $nl = "`n"
        if ($cur.Contains("`r`n")) { $nl = "`r`n" }
        $blockNl = $block -replace "`n", $nl
        $cbi = $cur.IndexOf($BeginTag)
        if ($cbi -ge 0) {
            $cei = $cur.IndexOf($EndTag, $cbi)
            if ($cei -lt 0) {
                Write-Warning "$agentsPath has '$BeginTag' but no '$EndTag'; not modified. Fix the file by hand."
                $agentsAction = 'SKIPPED (broken markers)'
            } else {
                $newText = $cur.Substring(0, $cbi) + $blockNl + $cur.Substring($cei + $EndTag.Length)
                if ($newText -eq $cur) { $agentsAction = 'unchanged'; $newText = $null } else { $agentsAction = 'replace block' }
            }
        } else {
            $agentsAction = 'append block'
            $sep = ''
            if (-not $cur.EndsWith("`n")) { $sep = $nl }
            $head = ''
            if ($title -ne '') { $head = $title + $nl + $nl }
            $newText = $cur + $sep + $nl + $head + $blockNl + $nl
        }
    }
    if ($DryRun) { Add-Row 'all' 'AGENTS.md' ("would " + $agentsAction) $agentsPath }
    else {
        if ($null -ne $newText) { Write-Utf8 $agentsPath $newText }
        Add-Row 'all' 'AGENTS.md' $agentsAction $agentsPath
    }

    if ($targets -contains 'claude') {
        $claudePath = Join-Path $ProjectPath 'CLAUDE.md'
        $cAction = ''
        $cText = $null
        if (-not (Test-Path -LiteralPath $claudePath)) {
            $cAction = 'create'
            $cText = "<!-- Claude Code: import the shared project rules (incl. TX8/MX3 rules) from AGENTS.md -->`n@AGENTS.md`n"
        } else {
            $cur = Read-Utf8 $claudePath
            if ([regex]::IsMatch($cur, '(?m)^\s*@AGENTS\.md\s*$')) { $cAction = 'unchanged (has @AGENTS.md)' }
            else {
                $cAction = 'append @AGENTS.md'
                $nl = "`n"
                if ($cur.Contains("`r`n")) { $nl = "`r`n" }
                $sep = ''
                if ($cur.Length -gt 0 -and -not $cur.EndsWith("`n")) { $sep = $nl }
                $cText = $cur + $sep + $nl + '@AGENTS.md' + $nl
            }
        }
        if ($DryRun) { Add-Row 'claude' 'CLAUDE.md' ("would " + $cAction) $claudePath }
        else {
            if ($null -ne $cText) { Write-Utf8 $claudePath $cText }
            Add-Row 'claude' 'CLAUDE.md' $cAction $claudePath
        }
    }
}

if ($Scope -eq 'user' -and ($targets -contains 'antigravity')) {
    $pluginRoot = Join-Path $HOME '.gemini\config\plugins\arm-embedded-skills'
    $rulesPath = Join-Path $pluginRoot 'rules\AGENTS.md'
    $manifestPath = Join-Path $pluginRoot 'plugin.json'
    if ($DryRun) {
        Add-Row 'antigravity' 'rules/AGENTS.md' 'would update' $rulesPath
    } else {
        Write-Utf8 $rulesPath (Read-Utf8 $SharedAgents)
        Add-Row 'antigravity' 'rules/AGENTS.md' 'update' $rulesPath
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            $pj = @"
{
  "name": "arm-embedded-skills",
  "displayName": "TX8 & MemryX MX3 Embedded Skills",
  "version": "$SuiteVersion",
  "description": "UM-PI drone AI platform skills and rules for Unimap TX8 SOM (4x Cortex-A53) and MemryX Cascade 100M (4x MX3)."
}
"@
            Write-Utf8 $manifestPath $pj
            Add-Row 'antigravity' 'plugin.json' 'create' $manifestPath
        }
    }
}

# ---- summary ---------------------------------------------------------------------------------
Write-Host ''
$summary | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
if ($Scope -eq 'user') {
    Write-Host 'NOTE: for Antigravity, user scope installs the full plugin bundle (skills + rules/AGENTS.md).'
    Write-Host '      For Claude/Codex, merge shared/AGENTS.tx8.md per project with -Scope project -ProjectPath <dir>.'
}
if ($DryRun) { Write-Host 'Dry run complete. Nothing was written.' } else { Write-Host 'Done. Restart the agent (or start a new session) to load the skills.' }
$skipped = @($summary | Where-Object { $_.Action -like 'SKIPPED*' })
if ($skipped.Count -gt 0) { exit 3 }
exit 0

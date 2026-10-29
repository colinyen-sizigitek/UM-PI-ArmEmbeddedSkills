<#
.SYNOPSIS
  Apply the TX8 MX3 frequency rule to the MemryX reference matrix (tx8-freq-matrix.csv).

.DESCRIPTION
  Product-owner rule (docs/DESIGN.md section 2.4):
    1. Only frequencies present in the table, <= MaxFreq (default 400 MHz), status PASS.
    2. Pick the LOWEST such frequency where fps >= TargetFps * Safety (default 30 * 1.5 = 45).
    3. If none qualifies -> "not recommended" for this target.
    4. Model or chip count (1-3 chips) not in the table -> run the on-board stability test first
       (skill um-pi-mx3-runtime-integration, scripts/mx3_stability_test.sh).
  The table is MemryX reference data measured with 4 chips (config 4x1), NOT measured on TX8.
  PowerShell 5.1 compatible; read-only; mirrors scripts/freq_query.py.

.PARAMETER ModelRegex
  Case-insensitive regex matched against the model name (e.g. 'YOLO26_nano_640').
.PARAMETER InputSize
  Optional input filter: '640' (= 640x640) or 'HxW' (e.g. '480x640').
.PARAMETER TargetFps
  Required sustained fps (default 30).
.PARAMETER Safety
  Safety factor (default 1.5).
.PARAMETER MaxFreq
  Highest allowed MHz (default 400). Values above 400 need -AllowAbove400 (violates product rule).
.PARAMETER Task
  any | detect | obb | segment | pose | classify | depth | track (track = detect). Name heuristic.
.PARAMETER Csv
  Path to the matrix (default: ..\references\tx8-freq-matrix.csv relative to this script).
.PARAMETER Format
  text (default) or csv.

.EXAMPLE
  powershell -NoProfile -File freq_query.ps1 -ModelRegex 'YOLO26_nano_640' -TargetFps 30
.EXAMPLE
  powershell -NoProfile -File freq_query.ps1 -Task detect -InputSize 640 -Format csv
#>
[CmdletBinding()]
param(
    [string]$ModelRegex = '.',
    [string]$InputSize = '',
    [double]$TargetFps = 30,
    [double]$Safety = 1.5,
    [int]$MaxFreq = 400,
    [ValidateSet('any', 'detect', 'obb', 'segment', 'pose', 'classify', 'depth', 'track')]
    [string]$Task = 'any',
    [string]$Csv = '',
    [ValidateSet('text', 'csv')]
    [string]$Format = 'text',
    [switch]$AllowAbove400,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help -Detailed $MyInvocation.MyCommand.Path; exit 0 }

if ($MaxFreq -gt 400) {
    if (-not $AllowAbove400) {
        [Console]::Error.WriteLine("MaxFreq $MaxFreq exceeds the product rule (MX3 clock <= 400 MHz). Re-run with -AllowAbove400 only for analysis.")
        exit 2
    }
    Write-Warning "!!! MaxFreq $MaxFreq MHz VIOLATES the TX8 product rule (<= 400 MHz). Results are for analysis only, not for deployment. !!!"
}

if ($Csv -eq '') { $Csv = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\references\tx8-freq-matrix.csv' }
if (-not (Test-Path $Csv)) { [Console]::Error.WriteLine("CSV not found: $Csv"); exit 2 }

function Get-TaskOf([string]$name) {
    $n = $name.ToLowerInvariant()
    if ($n -match 'oriented_bounding_boxes|_obb') { return 'obb' }
    if ($n -match 'pose|kpts|keypoint|landmark') { return 'pose' }
    if ($n -match '_cls_|classif|malaria_detector') { return 'classify' }
    if ($n -match '_seg_|segment|deeplab|unet|bisenet|pspnet|lanenet|yolop') { return 'segment' }
    if ($n -match 'depth|midas|dpt_') { return 'depth' }
    if ($n -match '3d|pointpillars|centerpoint|text_detection') { return 'other' }
    if ($n -match 'yolo|ssd|rtmdet|nanodet|damo|efficientdet|centernet|detection|detector|detr|retinanet|fcos|mobiledet|yunet') { return 'detect' }
    return 'other'
}

function Get-InputOf([string]$name) {
    $m = [regex]::Match($name, '_(\d+)_(\d+)_(\d+)_(onnx|tflite|tensorflow|keras)$')
    if ($m.Success) { return ('{0}x{1}' -f $m.Groups[1].Value, $m.Groups[2].Value) }
    return ''
}

$wantTask = $Task
if ($wantTask -eq 'track') { $wantTask = 'detect' }
$wantInput = ''
if ($InputSize -ne '') {
    if ($InputSize -match '^\d+$') { $wantInput = "${InputSize}x${InputSize}" }
    elseif ($InputSize -match '^\d+x\d+$') { $wantInput = $InputSize.ToLowerInvariant() }
    else { [Console]::Error.WriteLine("InputSize must be N or HxW"); exit 2 }
}
$need = $TargetFps * $Safety

$rows = Get-Content -Path $Csv | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } | ConvertFrom-Csv
$groups = $rows | Where-Object { $_.model -match $ModelRegex } | Group-Object model | Sort-Object Name

$results = @()
foreach ($g in $groups) {
    $name = $g.Name
    $mtask = Get-TaskOf $name
    if ($wantTask -ne 'any' -and $mtask -ne $wantTask) { continue }
    $inp = Get-InputOf $name
    if ($wantInput -ne '' -and $inp -ne $wantInput) { continue }

    $pass = @($g.Group | Where-Object { $_.status -eq 'PASS' -and [int]$_.freq_mhz -le $MaxFreq -and $_.fps -ne '' } |
            Sort-Object { [int]$_.freq_mhz })
    $pick = $null
    foreach ($r in $pass) { if ([double]$r.fps -ge $need) { $pick = $r; break } }

    if ($null -ne $pick) {
        $results += [pscustomobject]@{
            model = $name; task = $mtask; input = $inp; recommended_mhz = [int]$pick.freq_mhz
            fps = [double]$pick.fps; power_mw = $pick.power_mw; temp_c = $pick.temp_c; verdict = 'OK'
            reason = ('fps {0} >= {1}' -f $pick.fps, $need)
        }
    }
    else {
        $reason = "no PASS row <= $MaxFreq MHz"
        $bestFps = ''; $bestPow = ''; $bestTemp = ''
        if ($pass.Count -gt 0) {
            $best = $pass | Sort-Object { [double]$_.fps } -Descending | Select-Object -First 1
            $reason = ('best {0} fps @ {1} MHz < {2}' -f $best.fps, $best.freq_mhz, $need)
            $bestFps = [double]$best.fps; $bestPow = $best.power_mw; $bestTemp = $best.temp_c
        }
        $results += [pscustomobject]@{
            model = $name; task = $mtask; input = $inp; recommended_mhz = ''
            fps = $bestFps; power_mw = $bestPow; temp_c = $bestTemp; verdict = 'not recommended'; reason = $reason
        }
    }
}

if ($results.Count -eq 0) {
    Write-Output "No model in the matrix matches regex '$ModelRegex' (task=$Task, input=$InputSize)."
    Write-Output "-> Not in the reference table: run the on-board stability test first (skill um-pi-mx3-runtime-integration)."
    exit 1
}

if ($Format -eq 'csv') {
    $results | ConvertTo-Csv -NoTypeInformation | Write-Output
}
else {
    Write-Output ("Rule: lowest PASS freq <= {0} MHz with fps >= {1} x {2} = {3}. Source: MemryX reference table (4 chips), NOT TX8 data." -f $MaxFreq, $TargetFps, $Safety, $need)
    $results | Format-Table model, task, input, recommended_mhz, fps, power_mw, temp_c, verdict, reason -AutoSize |
        Out-String -Width 260 | Write-Output
    Write-Output "Verify on TX8 before deployment (skill um-pi-mx3-runtime-integration). Chip counts 1-3 are not in the table."
}
exit 0

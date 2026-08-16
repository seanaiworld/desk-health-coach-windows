<#
.SYNOPSIS
  Generates dashboard.html and coach-summary.json for the active mode, on request only.
.DESCRIPTION
  Read-only against config/state/data; writes only the two output files, atomically.
  Never called on a timer -- only when the user asks for the dashboard or coaching.
#>
param(
    [ValidateSet('test', 'live')][string]$Mode,
    [switch]$OpenDashboard
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'scoring.ps1')

$root = Get-DeskHealthRoot
if (-not $Mode) { $Mode = Get-RuntimeMode -Root $root }
if (-not $Mode) { throw "Cannot determine runtime mode (runtime/mode does not agree with data/test-runs/.current)." }
$modeRoot = Get-ModeRoot -Root $root -Mode $Mode

function Get-JsonOrDefault {
    param([string]$Path, $Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$summary = Get-JsonOrDefault -Path (Join-Path $modeRoot 'data\summary.json') -Default ([pscustomobject]@{
        byDay = @{}; byType = @{}; byTimeBucket = @{}; excludedByReason = @{}; score = 0; combo = 0; streak = 0
    })
$settingsRows = Import-Tsv2 -Path (Join-Path $modeRoot 'config\settings.tsv')
$settings = if ($settingsRows.Count -eq 1) { $settingsRows[0] } else { $null }
$routineRows = @(Import-Tsv2 -Path (Join-Path $modeRoot 'config\routine.tsv') | Where-Object { ConvertTo-Bool01 $_.enabled })
$changes = @(Read-Jsonl -Path (Join-Path $modeRoot 'data\changes.jsonl') | Select-Object -Last 10)

$todayKey = (Get-Date).ToString('yyyy-MM-dd')
$todayStats = if ($summary.byDay.PSObject.Properties.Name -contains $todayKey) { $summary.byDay.$todayKey } else { [pscustomobject]@{ done = 0; skipped = 0; excluded = 0 } }
$done = [int]$todayStats.done
$skipped = [int]$todayStats.skipped
$todayExcluded = [int]$todayStats.excluded
$rate = Get-CompletionRate -Done $done -Skipped $skipped

# Last 14 workdays present in byDay, oldest first, for the heatmap-style history table.
$dayKeys = @($summary.byDay.PSObject.Properties.Name | Sort-Object | Select-Object -Last 14)
$allTimeDone = 0; $allTimeSkipped = 0; $allTimeExcluded = 0
foreach ($k in $dayKeys) {
    $allTimeDone += [int]$summary.byDay.$k.done
    $allTimeSkipped += [int]$summary.byDay.$k.skipped
    $allTimeExcluded += [int]$summary.byDay.$k.excluded
}
$allTimeRate = Get-CompletionRate -Done $allTimeDone -Skipped $allTimeSkipped

# ---- dashboard.html ---------------------------------------------------
$e = { param($v) ConvertTo-HtmlEscaped $v }
$routineHtml = ($routineRows | ForEach-Object {
        "<tr><td>$(& $e $_.type)</td><td>$(& $e $_.mode)</td><td>$(& $e $_.cadenceMinutes)</td><td>$(& $e $_.times)</td><td>$(& $e $_.optionId)</td></tr>"
    }) -join "`n"

$gamificationOn = $settings -and (ConvertTo-Bool01 $settings.gamification)
$gamificationHtml = if ($gamificationOn) {
    "<p>Points: $([int]$summary.score) &middot; Combo: $([int]$summary.combo) &middot; Streak: $([int]$summary.streak) day(s)</p>"
} else { '' }

$heatmapHtml = ($dayKeys | ForEach-Object {
        $d = $summary.byDay.$_
        $dRate = Get-CompletionRate -Done ([int]$d.done) -Skipped ([int]$d.skipped)
        "<tr><td>$(& $e $_)</td><td>$([int]$d.done)</td><td>$([int]$d.skipped)</td><td>$([int]$d.excluded)</td><td>$(if ($null -ne $dRate) { "$([math]::Round($dRate*100,0))%" } else { 'n/a' })</td></tr>"
    }) -join "`n"
if (-not $heatmapHtml) { $heatmapHtml = '<tr><td colspan="5" class="small">No days recorded yet.</td></tr>' }

$byTypeHtml = ($summary.byType.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $t = $_.Value
        "<tr><td>$(& $e $_.Name)</td><td>$([int]$t.done)</td><td>$([int]$t.skipped)</td><td>$([int]$t.excluded)</td></tr>"
    }) -join "`n"
if (-not $byTypeHtml) { $byTypeHtml = '<tr><td colspan="4" class="small">No events recorded yet.</td></tr>' }

$html = @"
<title>Desk Health Coach Dashboard</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}
h1{font-size:1.4rem} table{border-collapse:collapse;width:100%;margin:1rem 0}
td,th{border:1px solid #ccc;padding:.4rem .6rem;text-align:left;font-size:.9rem}
.small{color:#666;font-size:.85rem}
</style>
<h1>Desk Health Coach &mdash; Dashboard ($(& $e $Mode) mode)</h1>
<p class="small">as of $((Get-Date).ToString('yyyy-MM-dd HH:mm'))</p>
<h2>Today</h2>
<p>Self-reported Done: $done &middot; Self-reported Skip: $skipped &middot; Completion rate: $(if ($null -ne $rate) { "$([math]::Round($rate*100,1))%" } else { 'n/a' }) &middot; Excluded: $todayExcluded</p>
$gamificationHtml
<p class="small">Completion rate = done / (done + explicit skipped). Excluded slots (paused, asleep, quiet window, dialog busy, error, unshown) are shown separately and never counted in the rate. Response time is measured from prompt to click, not exercise duration -- self-reported Done and Skip only.</p>
<h2>Last $($dayKeys.Count) workday(s)</h2>
<p>Totals: Done $allTimeDone &middot; Skipped $allTimeSkipped &middot; Excluded $allTimeExcluded &middot; Completion rate $(if ($null -ne $allTimeRate) { "$([math]::Round($allTimeRate*100,1))%" } else { 'n/a' })</p>
<table><tr><th>Day</th><th>Done</th><th>Skipped</th><th>Excluded</th><th>Rate</th></tr>
$heatmapHtml
</table>
<h2>Per-type totals (all-time)</h2>
<table><tr><th>Type</th><th>Done</th><th>Skipped</th><th>Excluded</th></tr>
$byTypeHtml
</table>
<h2>Current enabled routine</h2>
<table><tr><th>Type</th><th>Mode</th><th>Cadence (min)</th><th>Times</th><th>Movement</th></tr>
$routineHtml
</table>
<p class="small">This page is read-only. Routine changes happen through Claude Code.</p>
"@

Set-AtomicContent -Path (Join-Path $modeRoot 'dashboard.html') -Content $html
if ($OpenDashboard) { Start-Process (Join-Path $modeRoot 'dashboard.html') }

# ---- coach-summary.json ------------------------------------------------
$priorityArea = $null
$rankOne = $routineRows | Where-Object { $_.priorityRank -eq '1' } | Select-Object -First 1
if ($rankOne) { $priorityArea = $rankOne.type }

$enabledRoutine = @($routineRows | ForEach-Object {
        [ordered]@{
            type         = $_.type
            mode         = $_.mode
            cadenceMinutes = if ($_.mode -eq 'interval') { [int]$_.cadenceMinutes } else { $null }
            # Wrapped in an outer @(...): PowerShell unrolls a single-element array when it's
            # the *output* of an if/else statement being assigned, even with an inner @(...) --
            # a one-entry "times" list would otherwise serialize as a bare string, not an array.
            times        = @(if ($_.mode -eq 'times') { $_.times -split ',' | ForEach-Object { $_.Trim() } })
            enabled      = $true
            optionId     = $_.optionId
            priorityRank = if ($_.priorityRank -and $_.priorityRank -ne '') { [int]$_.priorityRank } else { $null }
        }
    })

$quietWindows = @()
if ($settings -and $settings.quietWindows -and $settings.quietWindows.Trim() -ne '') {
    foreach ($w in ($settings.quietWindows -split ';' | Where-Object { $_.Trim() -ne '' })) {
        $parts = $w -split '\|'
        $quietWindows += [ordered]@{
            days  = @($parts[0] -split ',' | ForEach-Object { $_.Trim() })
            start = $parts[1].Trim()
            end   = $parts[2].Trim()
            label = if ($parts.Count -gt 3) { $parts[3].Trim() } else { $null }
        }
    }
}

$recentChanges = @($changes | ForEach-Object {
        [ordered]@{ timestamp = $_.ts; area = $_.area; changeType = $_.type; before = $_.before; after = $_.after }
    })

# aggregateResults must match sampleWindow's full range (every recorded day), not just
# today -- otherwise "sample size" and "done/skipped" would silently describe different
# windows, which is exactly the kind of thing coach.md's schema check exists to catch.
$allDayKeys = @($summary.byDay.PSObject.Properties.Name | Sort-Object)
$sampleDone = 0; $sampleSkipped = 0; $sampleExcluded = 0
foreach ($k in $allDayKeys) {
    $sampleDone += [int]$summary.byDay.$k.done
    $sampleSkipped += [int]$summary.byDay.$k.skipped
    $sampleExcluded += [int]$summary.byDay.$k.excluded
}
$sampleRate = Get-CompletionRate -Done $sampleDone -Skipped $sampleSkipped

$coachSummary = [ordered]@{
    schemaVersion   = '1.0'
    mode            = $Mode
    generatedAt     = (Get-Date).ToString('o')
    sampleWindow    = [ordered]@{
        start         = ($allDayKeys | Select-Object -First 1)
        end           = $todayKey
        workdayCount  = $allDayKeys.Count
    }
    aggregateResults = [ordered]@{
        done             = $sampleDone
        skipped          = $sampleSkipped
        excluded         = $sampleExcluded
        completionRate   = $sampleRate
        byDay            = $summary.byDay
        byType           = $summary.byType
        byTimeBucket     = $summary.byTimeBucket
        excludedByReason = $summary.excludedByReason
    }
    schedule        = [ordered]@{
        workdays     = @(if ($settings) { $settings.workdays -split ',' | ForEach-Object { $_.Trim() } })
        workStart    = if ($settings) { $settings.workStart } else { $null }
        workEnd      = if ($settings) { $settings.workEnd } else { $null }
        quietWindows = $quietWindows
    }
    enabledRoutine  = $enabledRoutine
    movementLimits  = @(if ($settings) { $settings.movementLimitations -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } })
    priorityArea    = $priorityArea
    workSetting     = if ($settings) { $settings.movementCapacity } else { $null }
    busyContext     = if ($settings) { $settings.withinReach } else { $null }
    statedGoal      = if ($settings -and $settings.statedGoal -and $settings.statedGoal.Trim() -ne '') { $settings.statedGoal } else { $null }
    coachingTone    = if ($settings) { $settings.coachingTone } else { $null }
    gamification    = if ($gamificationOn) {
        [ordered]@{ enabled = $true; score = [int]$summary.score; combo = [int]$summary.combo; streak = [int]$summary.streak }
    } else {
        [ordered]@{ enabled = $false }
    }
    recentChanges   = $recentChanges
}

Set-AtomicJson -Path (Join-Path $modeRoot 'coach-summary.json') -Object $coachSummary -Depth 10
Write-Host "Wrote $(Join-Path $modeRoot 'dashboard.html') and $(Join-Path $modeRoot 'coach-summary.json') ($Mode mode)"

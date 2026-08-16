<#
.SYNOPSIS
  Schema, schedule, and cross-field validation for a Desk Health Coach config set.
.DESCRIPTION
  Validates config/settings.tsv, config/routine.tsv, and config/library.tsv (or a staged
  copy of them), expands the routine into a full daily timeline via schedule.ps1, and
  reports errors/warnings as a structured object. Never writes canonical files -- it is
  read-only. Called before installation and after every approved change, and against
  staging (desk-health/.staging or data/test-runs/.current) before promotion.
.PARAMETER ConfigDir
  Directory containing settings.tsv, routine.tsv, library.tsv. Defaults to <root>/config.
.PARAMETER Json
  Emit the result as JSON on stdout instead of human-readable text.
#>
param(
    [string]$ConfigDir,
    [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'schedule.ps1')

$root = Get-DeskHealthRoot
if (-not $ConfigDir) { $ConfigDir = Join-Path $root 'config' }

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Err([string]$msg) { $errors.Add($msg) }
function Add-Warn([string]$msg) { $warnings.Add($msg) }

$settingsPath = Join-Path $ConfigDir 'settings.tsv'
$routinePath = Join-Path $ConfigDir 'routine.tsv'
$libraryPath = Join-Path $ConfigDir 'library.tsv'

foreach ($p in @($settingsPath, $routinePath, $libraryPath)) {
    if (-not (Test-Path -LiteralPath $p)) { Add-Err "Missing required file: $p" }
}

$result = [ordered]@{
    valid     = $false
    errors    = @()
    warnings  = @()
    timeline  = @()
    orderUsed = $null
}

if ($errors.Count -gt 0) {
    $result.errors = @($errors)
    if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $errors | ForEach-Object { Write-Host "ERROR: $_" } }
    exit 1
}

# ---- library.tsv ---------------------------------------------------------
$libraryRows = Import-Tsv2 -Path $libraryPath
$libRequiredCols = @('optionId', 'type', 'name', 'instruction', 'dose', 'why', 'minSeconds', 'sourceURL', 'restrictions')
if ($libraryRows.Count -gt 0) {
    $cols = $libraryRows[0].PSObject.Properties.Name
    foreach ($c in $libRequiredCols) {
        if ($cols -notcontains $c) { Add-Err "library.tsv missing required column '$c'" }
    }
}
$libraryById = @{}
foreach ($row in $libraryRows) {
    if ([string]::IsNullOrWhiteSpace($row.optionId)) { Add-Err "library.tsv has a row with a blank optionId"; continue }
    if ($libraryById.ContainsKey($row.optionId)) { Add-Err "library.tsv has duplicate optionId '$($row.optionId)'"; continue }
    $libraryById[$row.optionId] = $row
    if ([string]::IsNullOrWhiteSpace($row.name)) { Add-Err "library.tsv row '$($row.optionId)' has a blank name" }
    if ([string]::IsNullOrWhiteSpace($row.instruction)) { Add-Err "library.tsv row '$($row.optionId)' has a blank instruction" }
    if ([string]::IsNullOrWhiteSpace($row.why)) { Add-Err "library.tsv row '$($row.optionId)' has a blank why" }
    $ms = 0
    if (-not [int]::TryParse($row.minSeconds, [ref]$ms) -or $ms -le 0) {
        Add-Err "library.tsv row '$($row.optionId)' has an invalid minSeconds '$($row.minSeconds)' (must be a positive integer)"
    }
    if ($row.sourceURL -notmatch '^https://') {
        Add-Err "library.tsv row '$($row.optionId)' sourceURL must start with https:// (got '$($row.sourceURL)')"
    }
}

# ---- settings.tsv (single data row) --------------------------------------
$settingsRows = Import-Tsv2 -Path $settingsPath
$settings = $null
if ($settingsRows.Count -ne 1) {
    Add-Err "settings.tsv must contain exactly one data row (found $($settingsRows.Count))"
} else {
    $settings = $settingsRows[0]
    $settingsRequiredCols = @('workdays', 'workStart', 'workEnd', 'quietWindows', 'movementLimitations',
        'withinReach', 'movementCapacity', 'coachingTone', 'milestoneCelebration', 'gamification', 'statedGoal')
    foreach ($c in $settingsRequiredCols) {
        if (-not ($settings.PSObject.Properties.Name -contains $c)) { Add-Err "settings.tsv missing required column '$c'" }
    }
}

$validDays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
$workdays = @()
$workStartMin = $null
$workEndMin = $null

if ($settings) {
    $workdays = @($settings.workdays -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($workdays.Count -eq 0) { Add-Err "settings.tsv workdays is empty" }
    foreach ($d in $workdays) {
        if ($validDays -notcontains $d) { Add-Err "settings.tsv workdays contains invalid day '$d' (expected Mon..Sun)" }
    }

    if (-not (Test-TimeOfDay $settings.workStart)) { Add-Err "settings.tsv workStart '$($settings.workStart)' is not a valid 24h HH:mm time" }
    if (-not (Test-TimeOfDay $settings.workEnd)) { Add-Err "settings.tsv workEnd '$($settings.workEnd)' is not a valid 24h HH:mm time" }
    if ((Test-TimeOfDay $settings.workStart) -and (Test-TimeOfDay $settings.workEnd)) {
        $workStartMin = ConvertTo-MinuteOfDay $settings.workStart
        $workEndMin = ConvertTo-MinuteOfDay $settings.workEnd
        if ($workStartMin -ge $workEndMin) { Add-Err "settings.tsv work range must be same-day with start earlier than end (got $($settings.workStart)-$($settings.workEnd))" }
    }

    # quietWindows: "Days|start|end|label" entries separated by ';'; label optional.
    if ($settings.quietWindows -and $settings.quietWindows.Trim() -ne '') {
        foreach ($w in ($settings.quietWindows -split ';' | Where-Object { $_.Trim() -ne '' })) {
            $parts = $w -split '\|'
            if ($parts.Count -lt 3) { Add-Err "settings.tsv quietWindows entry '$w' must be Days|start|end or Days|start|end|label"; continue }
            $wDays = @($parts[0] -split ',' | ForEach-Object { $_.Trim() })
            foreach ($d in $wDays) {
                if ($validDays -notcontains $d) { Add-Err "quiet window '$w' has invalid day '$d'" }
                elseif ($workdays -notcontains $d) { Add-Warn "quiet window '$w' references non-workday '$d'" }
            }
            if (-not (Test-TimeOfDay $parts[1].Trim())) { Add-Err "quiet window '$w' start time invalid" }
            if (-not (Test-TimeOfDay $parts[2].Trim())) { Add-Err "quiet window '$w' end time invalid" }
            if ((Test-TimeOfDay $parts[1].Trim()) -and (Test-TimeOfDay $parts[2].Trim())) {
                if ((ConvertTo-MinuteOfDay $parts[1].Trim()) -ge (ConvertTo-MinuteOfDay $parts[2].Trim())) {
                    Add-Err "quiet window '$w' start must be earlier than end"
                }
            }
        }
    }

    $limitTokens = @($settings.movementLimitations -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' })
    $hasNone = $limitTokens -contains 'none' -or $limitTokens -contains 'no known limitation'
    $hasSpecific = @($limitTokens | Where-Object { $_ -ne 'none' -and $_ -ne 'no known limitation' }).Count -gt 0
    if ($hasNone -and $hasSpecific) {
        Add-Err "settings.tsv movementLimitations conflicts: 'no known limitation' cannot appear alongside a specific limitation ($($settings.movementLimitations))"
    }

    if (-not ($settings.coachingTone -and $settings.coachingTone.Trim() -ne '')) { Add-Err "settings.tsv coachingTone is blank" }
    if (-not (@('0', '1') -contains $settings.milestoneCelebration)) { Add-Err "settings.tsv milestoneCelebration must be 0 or 1" }
    if (-not (@('0', '1') -contains $settings.gamification)) { Add-Err "settings.tsv gamification must be 0 or 1" }
}

# ---- routine.tsv ----------------------------------------------------------
$routineRows = Import-Tsv2 -Path $routinePath
$routineRequiredCols = @('type', 'mode', 'cadenceMinutes', 'phase', 'times', 'enabled', 'optionId', 'priorityRank')
if ($routineRows.Count -gt 0) {
    $cols = $routineRows[0].PSObject.Properties.Name
    foreach ($c in $routineRequiredCols) {
        if ($cols -notcontains $c) { Add-Err "routine.tsv missing required column '$c'" }
    }
}

foreach ($row in $routineRows) {
    if ([string]::IsNullOrWhiteSpace($row.type)) { Add-Err "routine.tsv has a row with a blank type"; continue }
    if (@('interval', 'times') -notcontains $row.mode) { Add-Err "routine.tsv row '$($row.type)' has invalid mode '$($row.mode)' (expected interval or times)"; continue }
    if (-not (@('0', '1') -contains $row.enabled)) { Add-Err "routine.tsv row '$($row.type)' enabled must be 0 or 1"; continue }
    if (-not (ConvertTo-Bool01 $row.enabled)) { continue }  # remaining checks only apply to enabled rows

    if ($row.mode -eq 'interval') {
        $cad = 0
        if (-not [int]::TryParse($row.cadenceMinutes, [ref]$cad) -or $cad -le 0) {
            Add-Err "routine.tsv row '$($row.type)' has invalid cadenceMinutes '$($row.cadenceMinutes)' (an Other/custom type still needs a cadence)"
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($row.times)) {
            Add-Err "routine.tsv row '$($row.type)' mode=times but times is blank (an Other/custom type still needs a schedule)"
        } else {
            foreach ($hhmm in ($row.times -split ',' | ForEach-Object { $_.Trim() })) {
                if (-not (Test-TimeOfDay $hhmm)) { Add-Err "routine.tsv row '$($row.type)' has invalid time '$hhmm' in times" }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($row.optionId)) {
        Add-Err "routine.tsv row '$($row.type)' has a blank optionId"
    } else {
        foreach ($optId in ($row.optionId -split ',' | ForEach-Object { $_.Trim() })) {
            if (-not $libraryById.ContainsKey($optId)) {
                Add-Err "routine.tsv row '$($row.type)' references unknown optionId '$optId' (not in library.tsv)"
                continue
            }
            $libRow = $libraryById[$optId]
            if ($libRow.type -ne $row.type) {
                Add-Err "routine.tsv row '$($row.type)' optionId '$optId' belongs to library type '$($libRow.type)', not '$($row.type)'"
            }
            if ($settings -and $libRow.restrictions -and $libRow.restrictions.Trim() -ne '') {
                foreach ($tok in $limitTokens) {
                    if ($tok -ne '' -and $tok -ne 'none' -and $tok -ne 'no known limitation' -and $libRow.restrictions.ToLower().Contains($tok)) {
                        Add-Warn "routine.tsv row '$($row.type)' optionId '$optId' may conflict with stated limitation '$tok' (library restriction: '$($libRow.restrictions)') -- confirm disable or replace before approval"
                    }
                }
            }
        }
    }

    if ($row.priorityRank -and $row.priorityRank.Trim() -ne '') {
        $rank = 0
        if (-not [int]::TryParse($row.priorityRank, [ref]$rank) -or $rank -le 0) {
            Add-Err "routine.tsv row '$($row.type)' priorityRank '$($row.priorityRank)' must be a positive integer or blank"
        }
    }
}

# ---- timeline / collision check -------------------------------------------
if ($errors.Count -eq 0 -and $null -ne $workStartMin -and $null -ne $workEndMin) {
    $tl = Build-Timeline -Rows $routineRows -WorkStartMin $workStartMin -WorkEndMin $workEndMin
    if (-not $tl.Success) {
        Add-Err "Schedule collision: $($tl.Error)"
    } else {
        $result.timeline = @(Format-Timeline -Slots $tl.Slots)
        $result.orderUsed = $tl.OrderUsed
        if ($tl.Error) { Add-Warn $tl.Error }
    }
}

$result.errors = @($errors)
$result.warnings = @($warnings)
$result.valid = ($errors.Count -eq 0)

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    if ($result.valid) {
        Write-Host "VALID"
        if ($result.orderUsed) { Write-Host "Placement order: $($result.orderUsed)" }
        $result.timeline | ForEach-Object { Write-Host ("  {0}  {1} ({2})" -f $_.time, $_.type, $_.optionId) }
    } else {
        Write-Host "INVALID"
        $errors | ForEach-Object { Write-Host "ERROR: $_" }
    }
    $warnings | ForEach-Object { Write-Host "WARNING: $_" }
}

if (-not $result.valid) { exit 1 } else { exit 0 }

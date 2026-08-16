# scoring.ps1 - gamification points, combo ladder, day streak, milestone line picker.
# Cosmetic-only: never changes scheduling. Dot-source common.ps1 before this file.

$Global:DeskHealthComboLadder = @(1.0, 1.2, 1.5, 2.0)
$Global:DeskHealthComboBase = 10
$Global:DeskHealthStreakMilestones = @(3, 5, 10, 20, 30)

function Get-PointsForDone {
    <# $DoneCountTodayBeforeThis is the number of Done clicks already recorded today,
       BEFORE this one. Returns the points this Done earns. #>
    param([Parameter(Mandatory)][int]$DoneCountTodayBeforeThis)
    $idx = [math]::Min($DoneCountTodayBeforeThis, $Global:DeskHealthComboLadder.Count - 1)
    $multiplier = $Global:DeskHealthComboLadder[$idx]
    return [math]::Round($Global:DeskHealthComboBase * $multiplier)
}

function Test-ComboCapReached {
    <# True on the 4th Done of the day (the multiplier first hits its cap). #>
    param([Parameter(Mandatory)][int]$DoneCountTodayIncludingThis)
    return $DoneCountTodayIncludingThis -eq $Global:DeskHealthComboLadder.Count
}

function Get-NextStreakMilestone {
    param([Parameter(Mandatory)][int]$Streak)
    if ($Streak -lt 3) { return $null }
    if ($Global:DeskHealthStreakMilestones -contains $Streak) { return $Streak }
    if ($Streak -gt 30 -and ($Streak % 10) -eq 0) { return $Streak }
    return $null
}

function Update-DayStreak {
    <# Call once at a workday's end-of-day rollover.
       $Summary must have .streak (int) and .lastEligibleWorkday (yyyy-MM-dd or null).
       A day only counts if it was an eligible workday (a real workday that wasn't
       fully excluded by pause/asleep/no-reminder-shown) AND is not being re-processed. #>
    param($Summary, [Parameter(Mandatory)][string]$WorkdayDate, [Parameter(Mandatory)][bool]$HadAtLeastOneDone, [Parameter(Mandatory)][bool]$WasEligible)
    if ($Summary.lastEligibleWorkday -eq $WorkdayDate) { return $Summary }  # idempotent: already rolled
    if (-not $WasEligible) { return $Summary }  # neither extends nor breaks the streak
    if ($HadAtLeastOneDone) {
        $Summary.streak = [int]$Summary.streak + 1
    } else {
        $Summary.streak = 0
    }
    $Summary.lastEligibleWorkday = $WorkdayDate
    return $Summary
}

function Get-MilestoneLine {
    <# Picks a pre-written line for $MilestoneType ('combo'|'streak'), never repeating
       the immediately previous line for that type. $Lines is a string array (6-8 variants),
       $LastIndexState is a hashtable keyed by type persisted in state.json. #>
    param([Parameter(Mandatory)][string[]]$Lines, [Parameter(Mandatory)][hashtable]$LastIndexState, [Parameter(Mandatory)][string]$MilestoneType)
    if ($Lines.Count -eq 0) { return $null }
    $last = if ($LastIndexState.ContainsKey($MilestoneType)) { [int]$LastIndexState[$MilestoneType] } else { -1 }
    if ($Lines.Count -eq 1) { $LastIndexState[$MilestoneType] = 0; return $Lines[0] }
    do {
        $idx = Get-Random -Minimum 0 -Maximum $Lines.Count
    } while ($idx -eq $last)
    $LastIndexState[$MilestoneType] = $idx
    return $Lines[$idx]
}

function Get-CompletionRate {
    param([Parameter(Mandatory)][int]$Done, [Parameter(Mandatory)][int]$Skipped)
    $denom = $Done + $Skipped
    if ($denom -eq 0) { return $null }
    return [math]::Round($Done / $denom, 4)
}

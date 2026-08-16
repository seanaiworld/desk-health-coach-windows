# schedule.ps1 - timeline expansion and collision/placement algorithm.
# Used by validate.ps1 (to approve a proposed routine) and runner.ps1 (to know what's due).
# Dot-source common.ps1 before this file.

$Global:DeskHealthFloorMinutes = 8      # minimum spacing between any two scheduled slots
$Global:DeskHealthActualShowFloor = 5   # minimum spacing between two actually-shown prompts

function Get-EnabledRoutineRows {
    param([Parameter(Mandatory)]$RoutineRows)
    @($RoutineRows | Where-Object { ConvertTo-Bool01 $_.enabled })
}

function Test-RowSelfSpacing {
    <# A row's own repeat interval must clear the 8-minute floor on its own,
       independent of any other row -- this is a build error, not a search problem. #>
    param($Row)
    if ($Row.mode -eq 'interval') {
        $cadence = [int]$Row.cadenceMinutes
        if ($cadence -lt $Global:DeskHealthFloorMinutes) {
            return "Row '$($Row.type)' cadence ${cadence}min is under the ${Global:DeskHealthFloorMinutes}-minute floor."
        }
        return $null
    } else {
        $times = @($Row.times -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $minutes = @($times | ForEach-Object { ConvertTo-MinuteOfDay $_ } | Sort-Object)
        for ($i = 1; $i -lt $minutes.Count; $i++) {
            if (($minutes[$i] - $minutes[$i - 1]) -lt $Global:DeskHealthFloorMinutes) {
                return "Row '$($Row.type)' has two explicit times under ${Global:DeskHealthFloorMinutes} minutes apart ($($times[$i-1]) / $($times[$i]))."
            }
        }
        return $null
    }
}

function Test-DuplicatePriorityRanks {
    param($Rows)
    $ranked = @($Rows | Where-Object { $_.priorityRank -and $_.priorityRank -ne '' })
    $dupes = $ranked | Group-Object priorityRank | Where-Object { $_.Count -gt 1 }
    if ($dupes) {
        $names = ($dupes | ForEach-Object { "rank $($_.Name): " + (($_.Group | ForEach-Object { $_.type }) -join ', ') }) -join '; '
        return "Duplicate priorityRank across rows: $names"
    }
    return $null
}

function Get-RowOccurrences {
    <# All minute-of-day occurrences for one row, given a phase (interval rows) or its
       fixed times (times rows), clipped to [workStartMin, workEndMin]. #>
    param($Row, [int]$WorkStartMin, [int]$WorkEndMin, [int]$Phase = 0)
    $occ = @()
    if ($Row.mode -eq 'interval') {
        $cadence = [int]$Row.cadenceMinutes
        $t = $WorkStartMin + (($Phase - $WorkStartMin) % $cadence + $cadence) % $cadence
        while ($t -le $WorkEndMin) {
            if ($t -ge $WorkStartMin) { $occ += $t }
            $t += $cadence
        }
    } else {
        foreach ($hhmm in ($Row.times -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
            $m = ConvertTo-MinuteOfDay $hhmm
            if ($m -ge $WorkStartMin -and $m -le $WorkEndMin) { $occ += $m }
        }
    }
    return , @($occ | Sort-Object)
}

function Test-CadencePairFeasible {
    <# Brute-forces both rows' phases to check whether ANY combination clears the
       8-minute floor everywhere across the work window. Used as a fast pre-check
       so an inherently-infeasible pair is reported before the full placement search
       runs (mismatched non-multiple cadences under 40 minutes routinely collide). #>
    param($RowA, $RowB, [int]$WorkStartMin, [int]$WorkEndMin)
    if ($RowA.mode -ne 'interval' -or $RowB.mode -ne 'interval') { return $true }
    $a = [int]$RowA.cadenceMinutes
    $b = [int]$RowB.cadenceMinutes
    if (($a % $b -eq 0) -or ($b % $a -eq 0)) { return $true }  # one evenly divides the other: always phaseable
    for ($pa = 0; $pa -lt $a; $pa++) {
        $occA = Get-RowOccurrences -Row $RowA -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin -Phase $pa
        for ($pb = 0; $pb -lt $b; $pb++) {
            $occB = Get-RowOccurrences -Row $RowB -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin -Phase $pb
            $ok = $true
            foreach ($x in $occA) {
                foreach ($y in $occB) {
                    if ([math]::Abs($x - $y) -lt $Global:DeskHealthFloorMinutes) { $ok = $false; break }
                }
                if (-not $ok) { break }
            }
            if ($ok) { return $true }
        }
    }
    return $false
}

function Find-ValidPhase {
    <# Searches phases 0..cadence-1 for the first phase whose occurrences clear the
       floor against every already-committed slot minute. Returns $null if none work. #>
    param($Row, [int[]]$CommittedMinutes, [int]$WorkStartMin, [int]$WorkEndMin)
    $cadence = [int]$Row.cadenceMinutes
    for ($phase = 0; $phase -lt $cadence; $phase++) {
        $occ = Get-RowOccurrences -Row $Row -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin -Phase $phase
        $ok = $true
        foreach ($o in $occ) {
            foreach ($c in $CommittedMinutes) {
                if ([math]::Abs($o - $c) -lt $Global:DeskHealthFloorMinutes) { $ok = $false; break }
            }
            if (-not $ok) { break }
        }
        if ($ok) { return @{ Phase = $phase; Occurrences = $occ } }
    }
    return $null
}

function Try-PlaceRows {
    <# Places times-rows first (fixed, non-negotiable), then interval rows in the
       given $Order. Returns @{Success; Slots; Failed} without mutating inputs. #>
    param($TimesRows, $IntervalRowsInOrder, [int]$WorkStartMin, [int]$WorkEndMin)
    $slots = @()
    $committed = @()
    foreach ($row in $TimesRows) {
        $occ = Get-RowOccurrences -Row $row -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin
        foreach ($c in $committed) {
            foreach ($o in $occ) {
                if ([math]::Abs($o - $c) -lt $Global:DeskHealthFloorMinutes) {
                    return @{ Success = $false; Failed = $row.type; Slots = @() }
                }
            }
        }
        $committed += $occ
        foreach ($o in $occ) { $slots += [ordered]@{ type = $row.type; optionId = $row.optionId; priorityRank = $row.priorityRank; minute = $o } }
    }
    foreach ($row in $IntervalRowsInOrder) {
        $result = Find-ValidPhase -Row $row -CommittedMinutes $committed -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin
        if ($null -eq $result) {
            return @{ Success = $false; Failed = $row.type; Slots = @() }
        }
        $committed += $result.Occurrences
        foreach ($o in $result.Occurrences) { $slots += [ordered]@{ type = $row.type; optionId = $row.optionId; priorityRank = $row.priorityRank; minute = $o; phase = $result.Phase } }
    }
    return @{ Success = $true; Slots = @($slots | Sort-Object { $_.minute }); Failed = $null }
}

function Build-Timeline {
    <# Main entry point. Tries rank order first, falls back to tightest-cadence-first,
       and only reports a real collision if both orders fail. Never drops a row. #>
    param($Rows, [int]$WorkStartMin, [int]$WorkEndMin)

    $enabled = Get-EnabledRoutineRows -RoutineRows $Rows

    foreach ($row in $enabled) {
        $err = Test-RowSelfSpacing -Row $row
        if ($err) { return @{ Success = $false; Error = $err; Slots = @(); OrderUsed = $null } }
    }
    $dupErr = Test-DuplicatePriorityRanks -Rows $enabled
    if ($dupErr) { return @{ Success = $false; Error = $dupErr; Slots = @(); OrderUsed = $null } }

    $timesRows = @($enabled | Where-Object { $_.mode -eq 'times' })
    $intervalRows = @($enabled | Where-Object { $_.mode -eq 'interval' })

    # Pairwise pre-check: fail fast with a precise culprit pair before the full search.
    for ($i = 0; $i -lt $intervalRows.Count; $i++) {
        for ($j = $i + 1; $j -lt $intervalRows.Count; $j++) {
            if (-not (Test-CadencePairFeasible -RowA $intervalRows[$i] -RowB $intervalRows[$j] -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin)) {
                return @{
                    Success   = $false
                    Error     = "'$($intervalRows[$i].type)' ($($intervalRows[$i].cadenceMinutes)min) and '$($intervalRows[$j].type)' ($($intervalRows[$j].cadenceMinutes)min) have no phase combination that clears the $($Global:DeskHealthFloorMinutes)-minute floor."
                    Collision = @{ RowA = $intervalRows[$i].type; RowB = $intervalRows[$j].type }
                    Slots     = @()
                    OrderUsed = $null
                }
            }
        }
    }

    $rankOrder = @($intervalRows | Where-Object { $_.priorityRank -and $_.priorityRank -ne '' } | Sort-Object { [int]$_.priorityRank })
    $rankOrder += @($intervalRows | Where-Object { -not ($_.priorityRank -and $_.priorityRank -ne '') })

    $rankResult = Try-PlaceRows -TimesRows $timesRows -IntervalRowsInOrder $rankOrder -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin
    if ($rankResult.Success) {
        return @{ Success = $true; Slots = $rankResult.Slots; OrderUsed = 'rank'; Error = $null }
    }

    $cadenceOrder = @($intervalRows | Sort-Object { [int]$_.cadenceMinutes })
    $cadenceResult = Try-PlaceRows -TimesRows $timesRows -IntervalRowsInOrder $cadenceOrder -WorkStartMin $WorkStartMin -WorkEndMin $WorkEndMin
    if ($cadenceResult.Success) {
        return @{ Success = $true; Slots = $cadenceResult.Slots; OrderUsed = 'tightest-cadence-first'; Error = 'Rank order could not be fully honored; placed tightest-cadence-first instead. All chosen cadences were kept.' }
    }

    return @{
        Success   = $false
        Error     = "No placement order fits every enabled row's cadence within the $($Global:DeskHealthFloorMinutes)-minute floor. Rank order failed at '$($rankResult.Failed)'; tightest-cadence-first failed at '$($cadenceResult.Failed)'."
        Slots     = @()
        OrderUsed = $null
    }
}

function Format-Timeline {
    param($Slots)
    $Slots | ForEach-Object {
        [pscustomobject]@{
            time         = ConvertFrom-MinuteOfDay $_.minute
            type         = $_.type
            optionId     = $_.optionId
            priorityRank = $_.priorityRank
        }
    }
}

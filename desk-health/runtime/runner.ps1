<#
.SYNOPSIS
  Desk Health Coach long-running runner. The ONLY writer of canonical state.
.DESCRIPTION
  Registered under a per-user Scheduled Task ("At log on", restart-on-failure). Wakes
  roughly once a minute: writes a heartbeat, reconciles mode, consumes any completed
  dialog result, consumes any pending command request, decides whether a slot is due,
  and spawns a dialog worker for at most one due slot at a time. Never blocks on the
  dialog worker -- it is spawned as a detached background process.
#>
param(
    [int]$TickIntervalSeconds = 60,
    [switch]$RunOnce   # single-tick mode, used by the test harness
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'schedule.ps1')
. (Join-Path $PSScriptRoot 'scoring.ps1')

$root = Get-DeskHealthRoot

function Initialize-PrivateDirs {
    param([string]$ModeRoot)
    foreach ($d in @('state', 'data', 'runtime')) {
        $p = Join-Path (if ($d -eq 'runtime') { $root } else { $ModeRoot }) $d
        Protect-PathForCurrentUser -Path $p
    }
    Protect-PathForCurrentUser -Path (Join-Path $ModeRoot 'state\inbox')
    Protect-PathForCurrentUser -Path (Join-Path $ModeRoot 'state\commands')
}

function Get-State {
    param([string]$ModeRoot)
    $path = Join-Path $ModeRoot 'state\state.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{
            currentDay      = (Get-Date).ToString('yyyy-MM-dd')
            pauseUntil      = $null
            lastTick        = $null
            shownSlots      = @{}
            settledSlots    = @{}
            rotation        = @{}
            activeDialog    = $null
            appliedRequests = @{}
            configRevision  = 0
            lastMilestone   = @{}
        }
    }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)
}

function Save-State {
    param([string]$ModeRoot, $State)
    Set-AtomicJson -Path (Join-Path $ModeRoot 'state\state.json') -Object $State
}

function Get-Summary {
    param([string]$ModeRoot)
    $path = Join-Path $ModeRoot 'data\summary.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{
            byDay            = @{}
            byType           = @{}
            byTimeBucket     = @{}
            excludedByReason = @{}
            score            = 0
            combo            = 0
            streak           = 0
            lastEligibleWorkday = $null
        }
    }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)
}

function Save-Summary {
    param([string]$ModeRoot, $Summary)
    Set-AtomicJson -Path (Join-Path $ModeRoot 'data\summary.json') -Object $Summary
}

function Write-Heartbeat {
    param([string]$Root)
    $line = (Get-Date).ToString('o')
    $tickLog = Join-Path $Root 'runtime\tick.log'
    Add-Content -LiteralPath $tickLog -Value $line -Encoding UTF8
    # Retain only 14 days.
    if (Test-Path -LiteralPath $tickLog) {
        $cutoff = (Get-Date).AddDays(-14)
        $kept = Get-Content -LiteralPath $tickLog | Where-Object {
            try { [datetime]::Parse($_) -ge $cutoff } catch { $true }
        }
        Set-AtomicContent -Path $tickLog -Content (($kept -join "`r`n") + "`r`n")
    }
    return [datetime]::Parse($line)
}

function Get-QuietWindowsActive {
    param($Settings, [datetime]$Now)
    if (-not $Settings.quietWindows -or $Settings.quietWindows.Trim() -eq '') { return $false }
    $day = $Now.DayOfWeek.ToString().Substring(0, 3)
    $minute = $Now.Hour * 60 + $Now.Minute
    foreach ($w in ($Settings.quietWindows -split ';' | Where-Object { $_.Trim() -ne '' })) {
        $parts = $w -split '\|'
        $wDays = @($parts[0] -split ',' | ForEach-Object { $_.Trim() })
        if ($wDays -notcontains $day) { continue }
        $s = ConvertTo-MinuteOfDay $parts[1].Trim()
        $e = ConvertTo-MinuteOfDay $parts[2].Trim()
        if ($minute -ge $s -and $minute -lt $e) { return $true }
    }
    return $false
}

function Invoke-CommandRequests {
    param([string]$ModeRoot, [string]$Mode, $State)
    $commandsDir = Join-Path $ModeRoot 'state\commands'
    if (-not (Test-Path -LiteralPath $commandsDir)) { return $State }
    foreach ($file in (Get-ChildItem -LiteralPath $commandsDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $req = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        } catch { Remove-Item -LiteralPath $file.FullName -Force; continue }

        if ($req.mode -ne $Mode) {
            $quarantine = Join-Path $ModeRoot 'data\test-runs\quarantine'
            Protect-PathForCurrentUser -Path $quarantine
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $quarantine $file.Name) -Force
            continue
        }

        if ($State.appliedRequests.ContainsKey($req.requestId)) {
            Remove-Item -LiteralPath $file.FullName -Force
            continue
        }

        switch ($req.type) {
            'pause' {
                $State.pauseUntil = $req.payload.until
            }
            'resume' {
                $State.pauseUntil = $null
            }
            default {
                # routine-edit / settings-edit / undo / mirror-repair are applied by the
                # skill's edit flow calling into this same request path; the concrete
                # config mutation is written here, atomically, by the runner alone.
                if ($req.payload.settingsPatch) {
                    $settingsPath = Join-Path $ModeRoot 'config\settings.tsv'
                    $rows = Import-Tsv2 -Path $settingsPath
                    $row = $rows[0]
                    foreach ($k in $req.payload.settingsPatch.PSObject.Properties.Name) {
                        $row.$k = $req.payload.settingsPatch.$k
                    }
                    Export-Tsv2 -Path $settingsPath -Rows $rows
                }
                if ($req.payload.routineRows) {
                    Export-Tsv2 -Path (Join-Path $ModeRoot 'config\routine.tsv') -Rows $req.payload.routineRows
                }
                if ($req.payload.snapshotPrevious) {
                    $State.previousConfigSnapshot = $req.payload.snapshotPrevious
                }
                $State.configRevision = [int]$State.configRevision + 1
                Add-JsonlLine -Path (Join-Path $ModeRoot 'data\changes.jsonl') -Object ([ordered]@{
                        ts        = (Get-Date).ToString('o')
                        requestId = $req.requestId
                        type      = $req.type
                        area      = $req.payload.area
                        before    = $req.payload.before
                        after     = $req.payload.after
                        revision  = $State.configRevision
                    })
            }
        }
        $State.appliedRequests[[string]$req.requestId] = @{ appliedAt = (Get-Date).ToString('o'); revision = $State.configRevision }
        Remove-Item -LiteralPath $file.FullName -Force
    }
    return $State
}

function Receive-DialogResult {
    param([string]$ModeRoot, [string]$Mode, $State, $Summary)
    $inbox = Join-Path $ModeRoot 'state\inbox'
    if (-not (Test-Path -LiteralPath $inbox)) { return @{ State = $State; Summary = $Summary } }
    foreach ($file in (Get-ChildItem -LiteralPath $inbox -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $res = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if ($res.mode -ne $Mode) {
            $quarantine = Join-Path $ModeRoot 'data\test-runs\quarantine'
            Protect-PathForCurrentUser -Path $quarantine
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $quarantine $file.Name) -Force
            continue
        }
        if ($State.settledSlots.ContainsKey($res.slotId)) {
            Remove-Item -LiteralPath $file.FullName -Force
            continue
        }

        $doneCountToday = [int]($Summary.byDay["$($State.currentDay)"].done)
        if (-not $doneCountToday) { $doneCountToday = 0 }

        $outcome = if ($res.action -eq 'done') { 'done' } else { 'skipped' }
        $points = 0
        if ($outcome -eq 'done') { $points = Get-PointsForDone -DoneCountTodayBeforeThis $doneCountToday }

        Add-JsonlLine -Path (Join-Path $ModeRoot 'data\slots.jsonl') -Object ([ordered]@{
                slotId      = $res.slotId
                scheduledTs = $res.scheduledTs
                shownTs     = $res.shownTs
                settledTs   = (Get-Date).ToString('o')
                type        = $res.type
                optionId    = $res.optionId
                outcome     = $outcome
                responseSec = $res.responseSec
                mode        = $Mode
            })
        Add-JsonlLine -Path (Join-Path $ModeRoot 'data\log.jsonl') -Object ([ordered]@{
                ts          = (Get-Date).ToString('o')
                scheduledTs = $res.scheduledTs
                shownTs     = $res.shownTs
                type        = $res.type
                optionId    = $res.optionId
                action      = $outcome
                responseSec = $res.responseSec
                mode        = $Mode
            })

        $State.settledSlots[[string]$res.slotId] = $outcome
        $day = $Summary.byDay["$($State.currentDay)"]
        if (-not $day) { $day = @{ done = 0; skipped = 0; excluded = 0 }; $Summary.byDay["$($State.currentDay)"] = $day }
        if ($outcome -eq 'done') { $day.done = [int]$day.done + 1 } else { $day.skipped = [int]$day.skipped + 1 }
        $Summary.score = [int]$Summary.score + $points
        if ($outcome -eq 'done') { $Summary.combo = [int]$day.done } else { $Summary.combo = $Summary.combo }

        $lockDir = Join-Path $ModeRoot 'state\dialog.lock'
        Remove-Lock -LockDir $lockDir

        Remove-Item -LiteralPath $file.FullName -Force
    }
    return @{ State = $State; Summary = $Summary }
}

function Invoke-Tick {
    param([string]$Root)

    $mode = Get-RuntimeMode -Root $Root
    if (-not $mode) {
        Write-Warning "Mode file / test-runs state mismatch -- failing closed, no prompt will be shown this tick."
        return
    }
    $modeRoot = Get-ModeRoot -Root $Root -Mode $mode
    Initialize-PrivateDirs -ModeRoot $modeRoot

    $realNow = Write-Heartbeat -Root $Root
    $state = Get-State -ModeRoot $modeRoot
    $summary = Get-Summary -ModeRoot $modeRoot

    # Test mode only: a defined clock-injection boundary for /desk-health test scenario,
    # so scenarios can simulate elapsed time without ever touching the real PC clock.
    $now = $realNow
    if ($mode -eq 'test' -and $state.ContainsKey('testClockOverride') -and $state.testClockOverride) {
        $now = [datetime]::Parse($state.testClockOverride)
    }
    if ($mode -eq 'test' -and $state.ContainsKey('__testForceDayRollover') -and $state.__testForceDayRollover) {
        $state.currentDay = $state.__testForceDayRollover
        $state.Remove('__testForceDayRollover')
    }

    $state = Invoke-CommandRequests -ModeRoot $modeRoot -Mode $mode -State $state
    $rd = Receive-DialogResult -ModeRoot $modeRoot -Mode $mode -State $state -Summary $summary
    $state = $rd.State; $summary = $rd.Summary

    $today = $now.ToString('yyyy-MM-dd')
    if ($state.currentDay -ne $today) {
        $hadDone = [bool]($summary.byDay["$($state.currentDay)"] -and [int]$summary.byDay["$($state.currentDay)"].done -gt 0)
        $summary = Update-DayStreak -Summary $summary -WorkdayDate $state.currentDay -HadAtLeastOneDone $hadDone -WasEligible $true
        $state.currentDay = $today
    }

    $settingsRows = Import-Tsv2 -Path (Join-Path $modeRoot 'config\settings.tsv')
    $routineRows = Import-Tsv2 -Path (Join-Path $modeRoot 'config\routine.tsv')
    if ($settingsRows.Count -eq 1 -and $routineRows.Count -gt 0) {
        $settings = $settingsRows[0]
        $day3 = $now.DayOfWeek.ToString().Substring(0, 3)
        $workdays = @($settings.workdays -split ',' | ForEach-Object { $_.Trim() })
        $isWorkday = $workdays -contains $day3
        $isPaused = $state.pauseUntil -and ([datetime]$state.pauseUntil -gt $now)
        $isQuiet = Get-QuietWindowsActive -Settings $settings -Now $now

        if ($isWorkday) {
            # Not gated on -not $isPaused or on "now" falling inside work hours: a paused or
            # after-hours slot must still receive its terminal outcome (excluded-pause /
            # excluded-unshown) via the sweep below. Only actually spawning a NEW dialog is
            # restricted to an unpaused due window, checked per-slot inside the loop.
            $workStartMin = ConvertTo-MinuteOfDay $settings.workStart
            $workEndMin = ConvertTo-MinuteOfDay $settings.workEnd
            $tl = Build-Timeline -Rows $routineRows -WorkStartMin $workStartMin -WorkEndMin $workEndMin
            if ($tl.Success) {
                    $lockDir = Join-Path $modeRoot 'state\dialog.lock'
                    $dialogActive = Test-Path -LiteralPath $lockDir
                    if ($dialogActive -and (Test-StaleLock -LockDir $lockDir)) {
                        Remove-Lock -LockDir $lockDir
                        $dialogActive = $false
                    }

                    $tickLogPath = Join-Path $Root 'runtime\tick.log'
                    foreach ($slot in $tl.Slots) {
                        $scheduledTs = $now.Date.AddMinutes($slot.minute)
                        $slotId = New-SlotId -ScheduledTs $scheduledTs -Type $slot.type -Mode $mode
                        if ($state.settledSlots.ContainsKey($slotId)) { continue }
                        $dueWindowEnd = $scheduledTs.AddMinutes(3)

                        if ($now -gt $dueWindowEnd) {
                            # The 3-minute catch-up window closed without the slot ever being shown.
                            Add-JsonlLine -Path (Join-Path $modeRoot 'data\slots.jsonl') -Object ([ordered]@{
                                    slotId    = $slotId; scheduledTs = $scheduledTs.ToString('o'); shownTs = $null
                                    settledTs = (Get-Date).ToString('o'); type = $slot.type; optionId = $slot.optionId
                                    outcome   = 'excluded-unshown'; responseSec = $null; mode = $mode
                                })
                            $state.settledSlots[[string]$slotId] = 'excluded-unshown'
                            $summary.excludedByReason['excluded-unshown'] = [int]($summary.excludedByReason['excluded-unshown']) + 1
                            continue
                        }
                        if ($now -lt $scheduledTs) { continue }

                        $lastShown = $state.lastShownTs
                        $tooSoon = $lastShown -and (($now) - [datetime]$lastShown).TotalMinutes -lt $Global:DeskHealthActualShowFloor

                        # Firing after scheduledTs is only a permitted catch-up if the heartbeat
                        # log shows continuous availability (no gap > 90s) across the slot.
                        $isLate = $now -gt $scheduledTs
                        $asleep = $isLate -and -not (Test-HeartbeatContinuous -TickLogPath $tickLogPath -FromTs $scheduledTs -ToTs $now)

                        if ($asleep) { $outcome = 'excluded-asleep' }
                        elseif ($isQuiet) { $outcome = 'excluded-quiet' }
                        elseif ($isPaused) { $outcome = 'excluded-pause' }
                        elseif ($dialogActive) { $outcome = 'excluded-dialog-busy' }
                        elseif ($tooSoon) { $outcome = 'excluded-dialog-busy' }
                        else { $outcome = $null }

                        if ($outcome) {
                            Add-JsonlLine -Path (Join-Path $modeRoot 'data\slots.jsonl') -Object ([ordered]@{
                                    slotId      = $slotId; scheduledTs = $scheduledTs.ToString('o'); shownTs = $null
                                    settledTs   = (Get-Date).ToString('o'); type = $slot.type; optionId = $slot.optionId
                                    outcome     = $outcome; responseSec = $null; mode = $mode
                                })
                            $state.settledSlots[[string]$slotId] = $outcome
                            $summary.excludedByReason[$outcome] = [int]($summary.excludedByReason[$outcome]) + 1
                            continue
                        }

                        # Fire exactly one dialog for the first due, unsettled slot this tick.
                        $optIds = @($slot.optionId -split ',' | ForEach-Object { $_.Trim() })
                        $rotKey = $slot.type
                        $prevPick = $state.rotation[[string]$rotKey]
                        $choices = @($optIds | Where-Object { $_ -ne $prevPick })
                        if ($choices.Count -eq 0) { $choices = $optIds }
                        $pick = $choices[(Get-Random -Minimum 0 -Maximum $choices.Count)]
                        $state.rotation[[string]$rotKey] = $pick

                        if (New-Lock -LockDir $lockDir -SlotId $slotId) {
                            $libRows = Import-Tsv2 -Path (Join-Path $modeRoot 'config\library.tsv')
                            $libRow = $libRows | Where-Object { $_.optionId -eq $pick } | Select-Object -First 1
                            $dialogArgs = @(
                                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                                '-File', (Join-Path $Root 'runtime\dialog.ps1'),
                                '-ModeRoot', $modeRoot, '-Mode', $mode, '-SlotId', $slotId,
                                '-ScheduledTs', $scheduledTs.ToString('o'), '-Type', $slot.type,
                                '-OptionId', $pick, '-MinSeconds', $libRow.minSeconds,
                                '-Action', $libRow.instruction, '-Dose', $libRow.dose, '-Why', $libRow.why
                            )
                            Start-Process -FilePath 'powershell.exe' -ArgumentList $dialogArgs -WindowStyle Hidden | Out-Null
                            $state.lastShownTs = $now.ToString('o')
                        }
                        break
                    }
                }
        }
    }

    $state.lastTick = $now.ToString('o')
    Save-State -ModeRoot $modeRoot -State $state
    Save-Summary -ModeRoot $modeRoot -Summary $summary
}

if ($RunOnce) {
    Invoke-Tick -Root $root
} else {
    while ($true) {
        try { Invoke-Tick -Root $root } catch { Write-Warning "tick failed: $_" }
        Start-Sleep -Seconds $TickIntervalSeconds
    }
}

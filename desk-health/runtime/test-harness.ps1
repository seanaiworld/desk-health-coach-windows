<#
.SYNOPSIS
  Deterministic injector for /desk-health test scenario <name>. Test mode only.
.DESCRIPTION
  Never appends expected slot/log/summary output directly and never touches the real
  PC clock or live files -- it injects clock/heartbeat/response inputs at the same
  boundary runner.ps1 already exposes (state.json's lastTick/lastShownTs/pauseUntil,
  and the dialog inbox), then calls Invoke-Tick so the real scheduling, exclusion,
  collision, scoring, streak, canonical-slot, detail-mirror, and summary code runs.
#>
param(
    [Parameter(Mandatory)][ValidateSet('pause', 'quiet', 'dialog-busy', 'unshown', 'wake-gap', 'collision', 'streak')]
    [string]$Scenario
)

. (Join-Path $PSScriptRoot 'common.ps1')

$root = Get-DeskHealthRoot
$mode = Get-RuntimeMode -Root $root
if ($mode -ne 'test') { throw "test-harness.ps1 only runs in test mode (current mode: $mode)." }
$modeRoot = Get-ModeRoot -Root $root -Mode $mode

function Get-TestState {
    $p = Join-Path $modeRoot 'state\state.json'
    if (Test-Path -LiteralPath $p) { return (ConvertFrom-JsonToHashtable (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)) }
    return @{}
}
function Save-TestState($s) { Set-AtomicJson -Path (Join-Path $modeRoot 'state\state.json') -Object $s }

switch ($Scenario) {
    'pause' {
        Write-CommandRequest -Root $root -Mode 'test' -CommandType 'pause' -Payload @{ until = (Get-Date).AddMinutes(30).ToString('o') }
        Write-Host "Injected: pause until +30min. Run runner.ps1 -RunOnce and confirm the next due slot settles excluded-pause."
    }
    'quiet' {
        $settingsRows = Import-Tsv2 -Path (Join-Path $modeRoot 'config\settings.tsv')
        if ($settingsRows.Count -ne 1 -or -not $settingsRows[0].quietWindows -or $settingsRows[0].quietWindows.Trim() -eq '') {
            Write-Host "No quiet window is configured in the test copy yet -- add one first via /desk-health set (edit.md), then re-run this scenario."
            break
        }
        $w = ($settingsRows[0].quietWindows -split ';' | Where-Object { $_.Trim() -ne '' })[0]
        $parts = $w -split '\|'
        $day = ($parts[0] -split ',')[0].Trim()
        $startMin = ConvertTo-MinuteOfDay $parts[1].Trim()
        $target = (Get-Date).Date
        for ($i = 0; $i -lt 7; $i++) {
            if ($target.DayOfWeek.ToString().Substring(0, 3) -eq $day) { break }
            $target = $target.AddDays(1)
        }
        $target = $target.AddMinutes($startMin + 1)
        $s = Get-TestState
        $s['testClockOverride'] = $target.ToString('o')
        Save-TestState $s
        Write-Host "Injected: testClockOverride = $($target.ToString('o')) (inside the configured quiet window '$w'). Run runner.ps1 -RunOnce and confirm the next due slot settles excluded-quiet."
    }
    'dialog-busy' {
        $lockDir = Join-Path $modeRoot 'state\dialog.lock'
        $dummy = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -WindowStyle Hidden -PassThru
        New-Lock -LockDir $lockDir -SlotId 'test-harness-fake-slot' -ProcessId $dummy.Id -ProcessName $dummy.ProcessName | Out-Null
        Write-Host "Injected: held dialog lock backed by a real 5-minute dummy process (PID $($dummy.Id)), so the lock will not look stale. Confirm the next due slot settles excluded-dialog-busy. Stop-Process -Id $($dummy.Id) to release early."
    }
    'unshown' {
        $settingsRows = Import-Tsv2 -Path (Join-Path $modeRoot 'config\settings.tsv')
        if ($settingsRows.Count -ne 1) { Write-Host "settings.tsv is not staged yet."; break }
        $workEndMin = ConvertTo-MinuteOfDay $settingsRows[0].workEnd
        $target = (Get-Date).Date.AddMinutes($workEndMin + 5)
        $s = Get-TestState
        $s['pauseUntil'] = $null
        $s['testClockOverride'] = $target.ToString('o')
        Save-TestState $s
        Write-Host "Injected: testClockOverride = $($target.ToString('o')) (past work end, so no dialog worker spawns for a slot that never fired). Run runner.ps1 -RunOnce and confirm every remaining slot settles excluded-unshown."
    }
    'wake-gap' {
        $tickLog = Join-Path $root 'runtime\tick.log'
        $stale = (Get-Date).AddMinutes(-5).ToString('o')
        Add-Content -LiteralPath $tickLog -Value $stale -Encoding UTF8
        Write-Host "Injected: a heartbeat 5 minutes in the past, creating a >90s gap up to now. Confirm any slot crossing that gap settles excluded-asleep, and that catch-up (<=3min late) is NOT permitted across it."
    }
    'collision' {
        $tmpDir = Join-Path $env:TEMP "desk-health-collision-test-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        Copy-Item -Path (Join-Path $modeRoot 'config\*.tsv') -Destination $tmpDir
        $routine = Import-Tsv2 -Path (Join-Path $tmpDir 'routine.tsv')
        if ($routine.Count -ge 1) {
            $routine[0].mode = 'interval'; $routine[0].cadenceMinutes = '13'; $routine[0].enabled = '1'
        }
        Export-Tsv2 -Path (Join-Path $tmpDir 'routine.tsv') -Rows $routine
        Write-Host "Staged a colliding routine copy at $tmpDir (13-min cadence against the rest). Run:"
        Write-Host "  runtime\validate.ps1 -ConfigDir `"$tmpDir`""
        Write-Host "and confirm it reports INVALID with the exact colliding pair. This never touches the live test config."
    }
    'streak' {
        $s = Get-TestState
        $s['__testForceDayRollover'] = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
        Save-TestState $s
        Write-Host "Injected: forced yesterday's currentDay so the next tick rolls the day over. Confirm Update-DayStreak runs and the streak/no-streak result matches whether yesterday had a Done."
    }
}

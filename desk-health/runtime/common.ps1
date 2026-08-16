# common.ps1 - shared helpers for the Desk Health Coach engine.
# Dot-sourced by validate.ps1, runner.ps1, dialog.ps1, report.ps1, test-harness.ps1.
# No canonical state is written from here directly except via the atomic helpers below;
# callers remain responsible for single-writer discipline (runner.ps1 owns live/test canon).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DeskHealthRoot {
    # This file lives at <root>/runtime/common.ps1, so root is its grandparent.
    Split-Path -Parent $PSScriptRoot
}

function ConvertFrom-JsonToHashtable {
    <# Windows PowerShell 5.1's ConvertFrom-Json has no -AsHashtable (added in PS 6+), and this
       engine targets 5.1 only. Recursively converts the PSCustomObject/array tree ConvertFrom-Json
       returns into nested Hashtables/arrays so callers can keep using .ContainsKey() and
       hashtable-index assignment, matching the [ordered]@{}/@{} shape state/summary start as. #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertFrom-JsonToHashtable $prop.Value
        }
        return $hash
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertFrom-JsonToHashtable $_ })
    }
    return $InputObject
}

function Start-DetachedScript {
    <# Spawns <ScriptPath> <NamedArgs> as a detached, hidden child via
       `powershell.exe -Command "& '<path>' -Name 'value' ..."` rather than `-File <path> ...`.
       On this machine (and plausibly others locked down the same way), a detached
       Start-Process child invoked with -File silently exits before running a single line of
       the script -- no error, no output, no window -- while the equivalent -Command "& ..."
       invocation runs normally. Root-caused via a minimal repro that isolated -File as the
       sole variable; never re-introduce a -File-based detached spawn without re-testing this. #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$NamedArgs
    )
    $quote = { param($v) "'" + ([string]$v -replace "'", "''") + "'" }
    $parts = @("& $(& $quote $ScriptPath)")
    foreach ($key in $NamedArgs.Keys) {
        $parts += "-$key $(& $quote $NamedArgs[$key])"
    }
    $cmd = $parts -join ' '
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', $cmd
    ) -WindowStyle Hidden | Out-Null
}

function Get-PropOrNull {
    <# StrictMode-safe property read. Under Set-StrictMode -Version Latest, reading a property
       that doesn't exist on the PSCustomObject trees ConvertFrom-Json produces is a terminating
       error -- and command payloads legitimately carry only the fields their command type needs
       (a settings-only edit has no routineRows, and vice versa). Returns $null when absent. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Protect-PathForCurrentUser {
    <# Resets NTFS ACLs on $Path to grant Full Control to the current user only,
       breaking inheritance. Windows has no umask, so this is the ACL equivalent
       of mode 700, applied before anything is written into the directory. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $user = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
    icacls $Path /inheritance:r | Out-Null
    icacls $Path /grant:r "${user}:(OI)(CI)F" | Out-Null
}

function Set-AtomicContent {
    <# Writes $Content to a sibling temp file, then Move-Item's it into place.
       Move-Item within the same volume is atomic, so readers never see a partial write. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = Join-Path $dir (".tmp-$([guid]::NewGuid().ToString('N')).tmp")
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Set-AtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object, [int]$Depth = 12)
    Set-AtomicContent -Path $Path -Content ($Object | ConvertTo-Json -Depth $Depth)
}

function Add-JsonlLine {
    <# Canonical append-only writers only: caller must already hold the lock. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 12 -Compress
    Add-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Read-Jsonl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    Get-Content -LiteralPath $Path | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json }
}

function Test-SafeTsvField {
    <# Rejects tabs, newlines, and other control characters from ever entering a TSV field. #>
    param([string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return $true }
    return -not ($Value -match "[\t\r\n]" -or ($Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]'))
}

function Import-TsvRows {
    <# Internal: a plain (non-array-wrapped) helper so the retry loop below can hold an
       intermediate result in a variable without PowerShell's array-vs-scalar assignment
       quirks -- only the final Import-Tsv2 return statement needs the ",@()" idiom. #>
    param([string]$Path)
    Import-Csv -LiteralPath $Path -Delimiter "`t"
}

function Import-Tsv2 {
    <# ALWAYS assign the result to a variable; never pipe this call directly into
       Where-Object/ForEach-Object. The ",@()" return below guarantees that ASSIGNMENT yields
       an array even for a single data row (so .Count is safe under StrictMode), but it also
       means the pipeline receives the whole array as ONE item -- a direct pipe therefore
       evaluates the predicate against the array itself and silently matches nothing.
       Assign first, then filter the variable. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    # Defensive retry: a transient file-handle/AV-scan lock on a just-written file can
    # occasionally yield a spuriously empty read even though the file has data rows.
    $lineCount = @(Get-Content -LiteralPath $Path).Count
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $count = @(Import-TsvRows -Path $Path).Count
        if ($count -gt 0 -or $lineCount -le 1) { break }
        Start-Sleep -Milliseconds 100
    }
    return , @(Import-TsvRows -Path $Path)
}

function Export-Tsv2 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()]$Rows)
    foreach ($row in $Rows) {
        foreach ($prop in $row.PSObject.Properties) {
            if (-not (Test-SafeTsvField $prop.Value)) {
                throw "Unsafe TSV field '$($prop.Name)' contains a tab, newline, or control character."
            }
        }
    }
    if (@($Rows).Count -eq 0) { $content = '' } else {
        $content = ($Rows | ConvertTo-Csv -Delimiter "`t" -NoTypeInformation) -join "`r`n"
        $content += "`r`n"
    }
    Set-AtomicContent -Path $Path -Content $content
}

function New-Lock {
    <# Atomic lock via New-Item -ItemType Directory, which fails if the directory
       already exists. Returns $true if the lock was acquired. Defaults to recording
       the caller's own process; the test harness may pass an explicit -ProcessId /
       -ProcessName to simulate a held lock without exiting immediately. #>
    param(
        [Parameter(Mandatory)][string]$LockDir,
        [Parameter(Mandatory)][string]$SlotId,
        [int]$ProcessId = $PID,
        [string]$ProcessName
    )
    try {
        New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
    } catch {
        return $false
    }
    Protect-PathForCurrentUser -Path $LockDir
    if (-not $ProcessName) { $ProcessName = (Get-Process -Id $ProcessId).ProcessName }
    $meta = [ordered]@{
        slotId      = $SlotId
        pid         = $ProcessId
        processName = $ProcessName
        startedAt   = (Get-Date).ToString('o')
    }
    Set-AtomicJson -Path (Join-Path $LockDir 'lock.json') -Object $meta
    return $true
}

function Remove-Lock {
    param([Parameter(Mandatory)][string]$LockDir)
    if (Test-Path -LiteralPath $LockDir) { Remove-Item -LiteralPath $LockDir -Recurse -Force }
}

function Test-StaleLock {
    <# A lock is stale only once the recorded PID no longer matches a live process
       of the recorded name -- never on age or heuristics alone. #>
    param([Parameter(Mandatory)][string]$LockDir)
    $metaPath = Join-Path $LockDir 'lock.json'
    if (-not (Test-Path -LiteralPath $metaPath)) { return $true }
    try {
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        $proc = Get-Process -Id $meta.pid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $true }
        if ($proc.ProcessName -ne $meta.processName) { return $true }
        return $false
    } catch {
        return $true
    }
}

function New-SlotId {
    param([Parameter(Mandatory)][datetime]$ScheduledTs, [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Mode)
    "{0}_{1}_{2}" -f $ScheduledTs.ToString('yyyyMMddTHHmm'), $Type, $Mode
}

function ConvertTo-Bool01 {
    param([string]$Value)
    return @('1', 'true', 'True', 'TRUE', 'yes', 'Yes', 'on', 'On') -contains $Value
}

function ConvertFrom-Bool {
    param([bool]$Value)
    if ($Value) { return '1' } else { return '0' }
}

function Test-TimeOfDay {
    <# 24-hour HH:mm only. #>
    param([string]$Value)
    return [bool]($Value -match '^([01]\d|2[0-3]):[0-5]\d$')
}

function ConvertTo-MinuteOfDay {
    param([string]$Hhmm)
    if (-not (Test-TimeOfDay $Hhmm)) { throw "Invalid time '$Hhmm' (expected 24h HH:mm)" }
    $parts = $Hhmm.Split(':')
    return ([int]$parts[0]) * 60 + [int]$parts[1]
}

function ConvertFrom-MinuteOfDay {
    param([Parameter(Mandatory)][int]$Minute)
    # [int] on a double ROUNDS (banker's rounding) rather than truncating, so an explicit
    # integer floor-division is required here -- casting minutes/60 directly produced
    # off-by-one hours (e.g. 580 -> "10:40" instead of "09:40").
    $h = ($Minute - ($Minute % 60)) / 60
    '{0:D2}:{1:D2}' -f $h, ($Minute % 60)
}

function Get-Gcd {
    param([int]$A, [int]$B)
    while ($B -ne 0) { $t = $B; $B = $A % $B; $A = $t }
    return [math]::Abs($A)
}

function Get-Lcm {
    param([int]$A, [int]$B)
    return [int]([math]::Abs($A * $B) / (Get-Gcd $A $B))
}

function Get-RuntimeMode {
    <# Returns 'test' or 'live' only if runtime/mode agrees with the presence/absence
       of data/test-runs/.current -- otherwise returns $null so callers fail closed. #>
    param([Parameter(Mandatory)][string]$Root)
    $modePath = Join-Path $Root 'runtime\mode'
    $currentDir = Join-Path $Root 'data\test-runs\.current'
    if (-not (Test-Path -LiteralPath $modePath)) { return $null }
    $mode = (Get-Content -LiteralPath $modePath -Raw).Trim()
    $hasCurrent = Test-Path -LiteralPath $currentDir
    if ($mode -eq 'test' -and -not $hasCurrent) { return $null }
    if ($mode -eq 'live' -and $hasCurrent) { return $null }
    if ($mode -ne 'test' -and $mode -ne 'live') { return $null }
    return $mode
}

function Get-ModeRoot {
    <# Root directory whose config/state/data a given mode reads and writes. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode)
    if ($Mode -eq 'test') { return (Join-Path $Root 'data\test-runs\.current') }
    return $Root
}

function ConvertTo-HtmlEscaped {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode($Value)
}

function Test-HeartbeatContinuous {
    <# True only if tick.log shows no gap greater than $MaxGapSeconds spanning
       [$FromTs, $ToTs] -- required before a slot may fire up to 3 minutes late. #>
    param(
        [Parameter(Mandatory)][string]$TickLogPath,
        [Parameter(Mandatory)][datetime]$FromTs,
        [Parameter(Mandatory)][datetime]$ToTs,
        [int]$MaxGapSeconds = 90
    )
    if (($ToTs - $FromTs).TotalSeconds -le $MaxGapSeconds) { return $true }
    if (-not (Test-Path -LiteralPath $TickLogPath)) { return $false }
    $stamps = @(Get-Content -LiteralPath $TickLogPath | ForEach-Object {
            try { [datetime]::Parse($_) } catch { $null }
        } | Where-Object { $_ -and $_ -ge $FromTs.AddSeconds(-$MaxGapSeconds) -and $_ -le $ToTs } | Sort-Object)
    if ($stamps.Count -eq 0) { return $false }
    $prev = $FromTs
    foreach ($s in $stamps) {
        if (($s - $prev).TotalSeconds -gt $MaxGapSeconds) { return $false }
        $prev = $s
    }
    if (($ToTs - $prev).TotalSeconds -gt $MaxGapSeconds) { return $false }
    return $true
}

function New-RequestId {
    [guid]::NewGuid().ToString('N')
}

function Write-CommandRequest {
    <# Claude Code's only path to influence canonical state: an immutable, validated
       request file, written temp-then-rename, for the runner to consume. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$CommandType,
        [Parameter(Mandatory)][hashtable]$Payload,
        [int]$ExpectedRevision = -1
    )
    $modeRoot = Get-ModeRoot -Root $Root -Mode $Mode
    $commandsDir = Join-Path $modeRoot 'state\commands'
    Protect-PathForCurrentUser -Path $commandsDir
    $requestId = New-RequestId
    $req = [ordered]@{
        requestId        = $requestId
        mode             = $Mode
        type             = $CommandType
        expectedRevision = $ExpectedRevision
        createdAt        = (Get-Date).ToString('o')
        payload          = $Payload
    }
    $path = Join-Path $commandsDir "$requestId.json"
    Set-AtomicJson -Path $path -Object $req
    return $requestId
}

<#
.SYNOPSIS
  One Windows Forms reminder dialog. Spawned as a detached child by runner.ps1.
.DESCRIPTION
  Never runs canonical logic itself: shows Skip/Done, enforces the minSeconds honesty
  pause client-side, then writes exactly one immutable result file into the mode's
  state/inbox/ via temp-file-plus-rename and exits. All text arrives as parameters,
  never interpolated into PowerShell source and never run through Invoke-Expression.
#>
param(
    [Parameter(Mandatory)][string]$ModeRoot,
    [Parameter(Mandatory)][ValidateSet('test', 'live')][string]$Mode,
    [Parameter(Mandatory)][string]$SlotId,
    [Parameter(Mandatory)][string]$ScheduledTs,
    [Parameter(Mandatory)][string]$Type,
    [Parameter(Mandatory)][string]$OptionId,
    [Parameter(Mandatory)][int]$MinSeconds,
    [Parameter(Mandatory)][string]$Action,
    [string]$Dose = '',
    [string]$Why = '',
    [string]$GameLine = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Without this, buttons fall back to unthemed classic rendering, and the focused/default
# button (Done, as AcceptButton) can repaint with white-on-white text once the form redraws
# for the "Not so fast" warning label -- must be called before any Form/control is created.
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'common.ps1')

$shownAt = Get-Date

function Show-ReminderForm {
    param([string]$Body, [bool]$NotSoFast)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Desk Health Coach'
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(420, 220)
    $form.BackColor = [System.Drawing.Color]::White

    # The warning (when present) reserves its own row at the top, and the body label shifts
    # down to start below it -- both always end at y=150, a clear 5px gap above the buttons'
    # top edge (y=155), so neither ever overlaps the buttons or each other.
    if ($NotSoFast) {
        $warn = New-Object System.Windows.Forms.Label
        $warn.Text = 'Not so fast -- give it a few more seconds.'
        $warn.ForeColor = [System.Drawing.Color]::DarkRed
        $warn.AutoSize = $false
        $warn.Size = New-Object System.Drawing.Size(380, 20)
        $warn.Location = New-Object System.Drawing.Point(20, 10)
        $form.Controls.Add($warn)
        $labelTop = 35
    } else {
        $labelTop = 20
    }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Body
    $label.ForeColor = [System.Drawing.Color]::Black
    $label.AutoSize = $false
    $label.Size = New-Object System.Drawing.Size(380, (150 - $labelTop))
    $label.Location = New-Object System.Drawing.Point(20, $labelTop)
    $form.Controls.Add($label)

    # FlatStyle 'Standard' (the default) is theme-drawn by Windows itself -- under visual
    # styles the OS's own button color scheme wins and an explicit ForeColor is silently
    # ignored, which is what let white-on-white text through on a dark-mode-themed system
    # even after EnableVisualStyles + ForeColor. 'Flat' avoided that by owner-drawing the
    # button, but its border (plus the extra default-button highlight ring Windows draws
    # around Done as AcceptButton) looked wrong. 'System' hands the ENTIRE button, including
    # text color, to the native Win32 control -- real standard Windows chrome, and native
    # rendering always keeps its own text readable against its own background, so it can't
    # reproduce the white-on-white bug the way 'Standard' did.
    $doneBtn = New-Object System.Windows.Forms.Button
    $doneBtn.Text = 'Done'
    $doneBtn.Size = New-Object System.Drawing.Size(100, 32)
    $doneBtn.Location = New-Object System.Drawing.Point(20, 155)
    $doneBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $doneBtn.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.Controls.Add($doneBtn)
    $form.AcceptButton = $doneBtn

    $skipBtn = New-Object System.Windows.Forms.Button
    $skipBtn.Text = 'Skip'
    $skipBtn.Size = New-Object System.Drawing.Size(100, 32)
    $skipBtn.Location = New-Object System.Drawing.Point(130, 155)
    $skipBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $skipBtn.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.Controls.Add($skipBtn)

    return $form.ShowDialog()
}

function Write-Result {
    param([string]$Action)
    $responseSec = [math]::Round(((Get-Date) - $shownAt).TotalSeconds, 1)
    $result = [ordered]@{
        slotId      = $SlotId
        scheduledTs = $ScheduledTs
        shownTs     = $shownAt.ToString('o')
        type        = $Type
        optionId    = $OptionId
        action      = $Action
        responseSec = $responseSec
        mode        = $Mode
    }
    $inbox = Join-Path $ModeRoot 'state\inbox'
    Protect-PathForCurrentUser -Path $inbox
    $tmp = Join-Path $inbox (".tmp-$([guid]::NewGuid().ToString('N')).tmp")
    [System.IO.File]::WriteAllText($tmp, ($result | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    $final = Join-Path $inbox "$SlotId.json"
    Protect-PathForCurrentUser -Path $inbox
    Move-Item -LiteralPath $tmp -Destination $final -Force
}

$bodyLines = @("$Type", $Action)
if ($Dose) { $bodyLines += "Dose: $Dose" }
if ($Why) { $bodyLines += "Why: $Why" }
if ($GameLine) { $bodyLines += $GameLine }
$body = ($bodyLines -join "`r`n`r`n")

$notSoFast = $false
while ($true) {
    $choice = Show-ReminderForm -Body $body -NotSoFast $notSoFast
    if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
        Write-Result -Action 'skipped'
        break
    }
    $elapsed = ((Get-Date) - $shownAt).TotalSeconds
    if ($elapsed -lt $MinSeconds) {
        $notSoFast = $true
        continue  # same action shown again, not counted as a second slot/prompt
    }
    Write-Result -Action 'done'
    break
}

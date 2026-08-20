[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing")

#Powershell Latency tester written by aigles1 with help from Claude

#Stop / Pause support added.
# Ctrl+C in the console normally stops the running pipeline - which here is
# ShowDialog() - tearing down the form and crashing. We deliberately avoid a
# native SetConsoleCtrlHandler, instead we tell the console to deliver Ctrl+C as ordinary
# input (no break signal, no crash) using only built-in .NET, then poll for it
# from the ping loop and treat it as Stop. No-op if there's no real console.
try { [System.Console]::TreatControlCAsInput = $true } catch { }

# Internal: wait granularity (ms). Controls how quickly Stop reacts mid-wait.
$SliceMs = 50

# Preset ping targets, in display order (top to bottom).
# Name is shown on top, Host (the actual ping target) directly underneath.
$Presets = @(
    @{ Name = 'Cloudflare DNS';      Host = '1.1.1.1' }
    @{ Name = 'Speedtest';           Host = 'speedtest.net' }
    @{ Name = 'Google DNS';          Host = '8.8.8.8' }
    @{ Name = 'Meter.net';           Host = '104.26.5.16' }
    @{ Name = 'Cisco OpenDNS';       Host = '208.67.222.222' }
    @{ Name = 'ISP Primary DNS';     Host = '127.0.0.1' }
    @{ Name = 'ISP Secondary DNS';   Host = '127.0.0.1' }
    @{ Name = 'ISP Default Gateway'; Host = '127.0.0.1' }
)

# form specs
$objForm = New-Object System.Windows.Forms.Form
$objForm.Text = "Check Network Status"
$objForm.Size = New-Object System.Drawing.Size(380,480)
$objForm.StartPosition = "CenterScreen"
$objForm.KeyPreview = $True
$objForm.MaximumSize = $objForm.Size
$objForm.MinimumSize = $objForm.Size

# combobox label
$objLabelbox = New-Object System.Windows.Forms.Label
$objLabelbox.Location = New-Object System.Drawing.Size(292,10)
$objLabelbox.Size = New-Object System.Drawing.Size(50,25)
$objLabelbox.BackColor = "Transparent"
$objLabelbox.ForeColor = "Black"
$objLabelbox.Text = "Count:"
$objForm.Controls.Add($objLabelbox)

$List = New-Object system.Windows.Forms.ComboBox
$List.TabIndex = 1
$List.width = 50
# 1-6 limit is no longer needed now that runs are cancellable.
@('1','2','3','4','5','6','10','25','50','100') | ForEach-Object {[void] $List.Items.Add($_)}
$List.SelectedIndex = 0
$List.location = New-Object System.Drawing.Point(295,35)
$List.Font = "Microsoft Sans Serif,10"
$objForm.Controls.Add($List)

# label
$objLabel = New-Object System.Windows.Forms.Label
$objLabel.Location = New-Object System.Drawing.Size(17,10)
$objLabel.Size = New-Object System.Drawing.Size(130,25)
$objLabel.BackColor = "Transparent"
$objLabel.ForeColor = "Black"
$objLabel.Text = "Enter Address:"
$objForm.Controls.Add($objLabel)

# input box
$objTextbox = New-Object System.Windows.Forms.TextBox
$objTextbox.TabIndex = 0
$objTextbox.Location = New-Object System.Drawing.Size(20,35)
$objTextbox.Size = New-Object System.Drawing.Size(180,20)
$objTextbox.MaxLength = 33
$objTextbox.Font = New-Object System.Drawing.Font("Segoe UI",11,[System.Drawing.FontStyle]::Regular)
$objForm.Controls.Add($objTextbox)

$ErrorProvider = New-Object System.Windows.Forms.ErrorProvider

# ok button (custom address)
$objButton = New-Object System.Windows.Forms.Button
$objButton.Location = New-Object System.Drawing.Size(210,37)
$objButton.Size = New-Object System.Drawing.Size(75,23)
$objButton.Text = "OK"
$objButton.Add_Click({Button_Click})
$objForm.Controls.Add($objButton)

# --- preset buttons + labels, generated from $Presets -----------------
# First preset sits at y=94; each subsequent one is 40px lower, matching
# the original hand-placed layout.
$presetNameFont = New-Object System.Drawing.Font("Microsoft Sans Serif",8.25)
$y = 94
foreach ($p in $Presets) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Size(170, $y)
    $btn.Size     = New-Object System.Drawing.Size(75,23)
    $btn.Text     = "OK"
    # Stash this button's target in its Tag. The handler is a PLAIN scriptblock
    # (no closure) so it resolves Start-PingTest/$List in script scope, and
    # reads its own target back via $this.Tag ($this = the clicked button).
    # This is why all buttons don't end up pinging the loop's last host.
    $btn.Tag = $p.Host
    $btn.Add_Click({ Start-PingTest -Target $this.Tag -Count ([int]$List.Text) })
    $objForm.Controls.Add($btn)

    # Two stacked labels: name on top (bold), address underneath (dim). Kept
    # under 128px wide so they end before the OK button at x=170.
    $nameLbl = New-Object System.Windows.Forms.Label
    $nameLbl.Text     = $p.Name
    $nameLbl.Font     = $presetNameFont
    $nameLbl.Location = New-Object System.Drawing.Point(39, ($y + 1))
    $nameLbl.Size     = New-Object System.Drawing.Size(128, 15)
    $objForm.Controls.Add($nameLbl)

    $addrLbl = New-Object System.Windows.Forms.Label
    $addrLbl.Text      = $p.Host
    $addrLbl.ForeColor = "DimGray"
    $addrLbl.Location  = New-Object System.Drawing.Point(39, ($y + 16))
    $addrLbl.Size      = New-Object System.Drawing.Size(128, 15)
    $objForm.Controls.Add($addrLbl)

    $y += 40
}

# form status bar
$objStatusBar = New-Object System.Windows.Forms.Label
$objStatusBar.Name = "statusBar"
$objStatusBar.Text = "Ready"
$objStatusBar.ForeColor = "blue"
$objStatusBar.location = New-Object System.Drawing.Point(23, 70)
$objStatusBar.Size = New-Object System.Drawing.Size(180,20)   # room for "Pinging... (3/6)"
$objStatusBar.Enabled = $true
$objForm.Controls.Add($objStatusBar)

# --- run state ---
$script:PingBusy  = $false
$script:PingStop  = $false
$script:PingPause = $false

# --- Pause button ---
$objPauseButton = New-Object System.Windows.Forms.Button
$objPauseButton.Name     = 'btnPause'
$objPauseButton.Location = New-Object System.Drawing.Size(210,66)
$objPauseButton.Size     = New-Object System.Drawing.Size(55,23)
$objPauseButton.Text     = "Pause"
$objPauseButton.Enabled  = $false
$objPauseButton.TabStop  = $false
$objPauseButton.Add_Click({
    $script:PingPause = -not $script:PingPause
    $objPauseButton.Text = if ($script:PingPause) { "Resume" } else { "Pause" }
})
$objForm.Controls.Add($objPauseButton)

# --- Stop button ---
$objStopButton = New-Object System.Windows.Forms.Button
$objStopButton.Name     = 'btnStop'
$objStopButton.Location = New-Object System.Drawing.Size(270,66)
$objStopButton.Size     = New-Object System.Drawing.Size(55,23)
$objStopButton.Text     = "Stop"
$objStopButton.Enabled  = $false
$objStopButton.TabStop  = $false
$objStopButton.Add_Click({
    $script:PingStop  = $true
    $script:PingPause = $false      # break out of a pause as well
})
$objForm.Controls.Add($objStopButton)

# If the window is closed mid-run, unwind the loop first.
$objForm.Add_FormClosing({ $script:PingStop = $true })

function Set-PingUiBusy {
    param([bool]$Busy)
    foreach ($c in $objForm.Controls) {
        if ($c -is [System.Windows.Forms.Button] -and
            $c.Name -notin @('btnStop','btnPause')) {
            $c.Enabled = -not $Busy
        }
    }
    $objStopButton.Enabled  = $Busy
    $objPauseButton.Enabled = $Busy
    if (-not $Busy) {
        $script:PingPause    = $false
        $objPauseButton.Text = "Pause"
    }
}

# Sleep for $Milliseconds while keeping the UI alive and Stop responsive.
# Returns early if Stop is pressed. Slices the wait into $SliceMs chunks
# and pumps the message loop between each.
# True if a Ctrl+C keypress is waiting in the console input buffer. Relies on
# TreatControlCAsInput being set above. Runs on the script thread (has a
# runspace), uses only built-in .NET, and safely returns $false when there's
# no real console (e.g. redirected input, or launched without a console).
function Test-ConsoleCtrlC {
    try {
        if ([System.Console]::IsInputRedirected) { return $false }
        while ([System.Console]::KeyAvailable) {
            $k = [System.Console]::ReadKey($true)
            if ($k.Key -eq 'C' -and ($k.Modifiers -band [System.ConsoleModifiers]::Control)) {
                return $true
            }
        }
    } catch { }
    return $false
}

function Wait-Cancellable {
    param([int]$Milliseconds)
    $slices = [math]::Ceiling($Milliseconds / $SliceMs)
    for ($w = 0; $w -lt $slices -and -not $script:PingStop; $w++) {
        # Fold a console Ctrl+C into the stop flag so waits cancel promptly too.
        if (Test-ConsoleCtrlC) { $script:PingStop = $true; break }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds $SliceMs
    }
}

function Start-PingTest {
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Count = 1
    )

    # DoEvents re-enters the message loop, so guard against re-entrancy.
    if ($script:PingBusy) { return }
    $script:PingBusy  = $true
    $script:PingStop  = $false
    $script:PingPause = $false
    Set-PingUiBusy $true

    # Discard any keystrokes buffered while idle (e.g. a stray Ctrl+C) so this
    # run starts clean and only reacts to Ctrl+C pressed during the run.
    [void](Test-ConsoleCtrlC)

    # We run one ping per loop pass so Stop/Pause can act between pings, but
    # formatting each result on its own reprints the "Destination:" group
    # header and pads with blank lines. Instead we push every result through a
    # SINGLE streaming formatter (a steppable pipeline): the header/grouping
    # print once and each ping streams in as a row - identical to native
    # "Test-Connection host -Count N".
    $renderer = { Out-Host }.GetSteppablePipeline()
    $renderer.Begin($true)
    $rendererEnded = $false

    # Test-Connection -Count 1 always numbers its Ping column "1". Rewrite that
    # field per iteration so the column counts 1,2,3... like the native command.
    # The property has no public setter, so we poke its compiler backing field.
    $pingField = $null

    try {
        for ($i = 1; $i -le $Count; $i++) {

            # Ctrl+C from the console arrives as input (see top of script); pick
            # it up here on the script thread and treat it like Stop.
            if (Test-ConsoleCtrlC) { $script:PingStop = $true }

            # honour Pause
            while ($script:PingPause -and -not $script:PingStop) {
                $objStatusBar.Text = "Paused ($i/$Count)"
                Wait-Cancellable -Milliseconds $SliceMs
            }
            if ($script:PingStop) { break }

            $objStatusBar.Text = "Pinging... ($i/$Count)"
            [System.Windows.Forms.Application]::DoEvents()

            $result = Test-Connection -TargetName $Target -Count 1 -ErrorAction SilentlyContinue

            if ($result) {
                if (-not $pingField) {
                    $pingField = $result.GetType().GetField(
                        '<Ping>k__BackingField',
                        [System.Reflection.BindingFlags]'Instance,NonPublic')
                }
                if ($pingField) { $pingField.SetValue($result, [uint32]$i) }
                $renderer.Process($result)   # streams one row, header only once
            }

            if ($i -lt $Count) { Wait-Cancellable -Milliseconds 1000 }
        }

        $renderer.End(); $rendererEnded = $true   # flush the formatter
        $objStatusBar.Text = if ($script:PingStop) { "Stopped" } else { "Done" }
    }
    finally {
        if (-not $rendererEnded) { try { $renderer.End() } catch {} }
        $script:PingBusy = $false
        Set-PingUiBusy $false
    }
}

# The OK button next to the text box (validates input first).
function Button_Click {
    if ($objTextbox.Text.Trim().Length -lt 1) {
        $ErrorProvider.SetError($objTextbox,
            "Please enter a valid IP address or domain name eg: 127.0.0.1")
        return
    }
    $ErrorProvider.Clear()
    # No Invoke-Expression: the old version interpolated the text box straight
    # into a command string, so "1.1.1.1; calc" would have executed calc.
    Start-PingTest -Target $objTextbox.Text.Trim() -Count ([int]$List.Text)
}

$objForm.Add_KeyDown({
    $_.SuppressKeyPress = $True
    if ($_.KeyCode -eq "Enter") {
        if (-not $script:PingBusy) { Button_Click }
    }
    elseif (($_.Control) -and ($_.KeyCode -eq 'A')) {
        $objTextbox.SelectAll()
    }
    elseif ($_.KeyCode -eq "Escape") {
        if ($script:PingBusy) { $script:PingStop = $true }
        else                  { $objForm.Close() }
    }
    elseif ($_.KeyCode -eq "Space" -and $script:PingBusy) {
        $objPauseButton.PerformClick()
    }
    else { $_.SuppressKeyPress = $False }
})

$objForm.ShowDialog() | Out-Null
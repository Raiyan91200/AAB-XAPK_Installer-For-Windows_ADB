Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Catch exceptions raised on the UI thread (e.g. inside a control callback) so the
# window shows the error instead of silently ending its message loop and closing.
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installerScript = Join-Path $scriptDir "install-aab.ps1"
$xapkInstallerScript = Join-Path $scriptDir "install-xapk.ps1"
# Fallback defaults only; the live values come from the UI text boxes / config JSON.
$defaultAdbPath = "C:/AndroidSDKForAndroidStudio/platform-tools/adb.exe"
$defaultUnityEditorRoot = "C:\Program Files\Unity\Hub\Editor"
$logFile = Join-Path $scriptDir "aab-install-last.log"
$crashLog = Join-Path $scriptDir "aab-install-crash.log"
$configFile = Join-Path $scriptDir "aab-install-ui.config.json"

function Report-Crash($ErrorObject, $Where) {
    try {
        $text = "[$Where] " + ($ErrorObject | Out-String)
        Add-Content -LiteralPath $crashLog -Value $text -ErrorAction SilentlyContinue
    } catch {
    }
    try {
        [System.Windows.Forms.MessageBox]::Show(([string]$ErrorObject), "AAB Installer error", "OK", "Error") | Out-Null
    } catch {
    }
}

# Any exception that reaches the WinForms message loop lands here instead of killing the window.
[System.Windows.Forms.Application]::add_ThreadException({
    param($eventSender, $threadArgs)
    Report-Crash $threadArgs.Exception "ThreadException"
})

function Load-Config {
    if (Test-Path -LiteralPath $configFile) {
        try {
            return Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        } catch {
        }
    }
    return $null
}

function Save-Config($Data) {
    try {
        $Data | ConvertTo-Json | Set-Content -LiteralPath $configFile -Encoding UTF8
    } catch {
    }
}

function Get-CurrentConfig {
    return [pscustomobject]@{
        Keystore        = $ksTextBox.Text.Trim('" ')
        Alias           = $aliasTextBox.Text.Trim()
        StorePass       = $storePassBox.Text
        KeyPass         = $keyPassBox.Text
        AdbPath         = $adbPathBox.Text.Trim('" ')
        UnityEditorRoot = $unityRootBox.Text.Trim('" ')
    }
}

function Get-UnityAndroidPlayerRoots {
    $editorRoot = if ($unityRootBox -and $unityRootBox.Text.Trim()) { $unityRootBox.Text.Trim() } else { $defaultUnityEditorRoot }
    if (-not (Test-Path -LiteralPath $editorRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $editorRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "Editor\Data\PlaybackEngines\AndroidPlayer" } |
            Where-Object { Test-Path -LiteralPath $_ }
    )
}

function Find-UnityAdbPath {
    foreach ($root in Get-UnityAndroidPlayerRoots) {
        $candidate = Join-Path $root "SDK\platform-tools\adb.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Find-UnityBundletoolPath {
    foreach ($root in Get-UnityAndroidPlayerRoots) {
        $toolsDir = Join-Path $root "Tools"
        if (Test-Path -LiteralPath $toolsDir) {
            $jar = Get-ChildItem -LiteralPath $toolsDir -Filter "bundletool*.jar" -File -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First 1
            if ($jar) {
                return $jar.FullName
            }
        }
    }

    return $null
}

function Find-AdbPath {
    $adbFromBox = if ($adbPathBox) { $adbPathBox.Text.Trim() } else { "" }
    $candidates = @(
        $env:ANDROID_QA_MCP_ADB,
        $adbFromBox,
        (Find-UnityAdbPath),
        $defaultAdbPath,
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe",
        (Get-Command "adb" -ErrorAction SilentlyContinue).Source,
        (Join-Path $scriptDir "adb.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return ""
}

function Get-BundletoolPath {
    if ($env:BUNDLETOOL_JAR -and (Test-Path -LiteralPath $env:BUNDLETOOL_JAR)) {
        return $env:BUNDLETOOL_JAR
    }

    $unityBundletool = Find-UnityBundletoolPath
    if ($unityBundletool) {
        return $unityBundletool
    }

    $toolsDir = Join-Path $scriptDir "tools"
    foreach ($root in @($scriptDir, $toolsDir)) {
        if (Test-Path -LiteralPath $root) {
            $jar = Get-ChildItem -LiteralPath $root -Filter "bundletool*.jar" -File -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First 1
            if ($jar) {
                return $jar.FullName
            }
        }
    }

    return ""
}

function Add-Log($Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $line = $Text.TrimEnd()
    $logBox.AppendText($line + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()

    try {
        Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
    } catch {
    }
}

function Set-Busy($Busy) {
    $installButton.Enabled = -not $Busy
    $xapkButton.Enabled = -not $Busy
    $browseButton.Enabled = -not $Busy
    $refreshButton.Enabled = -not $Busy
    $aabTextBox.Enabled = -not $Busy
    $deviceCombo.Enabled = -not $Busy
    $keepApksCheck.Enabled = -not $Busy
    $ksTextBox.Enabled = -not $Busy
    $ksBrowse.Enabled = -not $Busy
    $aliasTextBox.Enabled = -not $Busy
    $storePassBox.Enabled = -not $Busy
    $keyPassBox.Enabled = -not $Busy
    $adbPathBox.Enabled = -not $Busy
    $adbBrowse.Enabled = -not $Busy
    $unityRootBox.Enabled = -not $Busy
    $unityBrowse.Enabled = -not $Busy
    $progress.Visible = $Busy
}

function Quote-ProcessArgument($Argument) {
    if ($null -eq $Argument) {
        return '""'
    }

    $value = [string]$Argument
    if ($value -notmatch '[\s"]') {
        return $value
    }

    return '"' + ($value -replace '"', '\"') + '"'
}

function Refresh-Devices {
    $deviceCombo.Items.Clear()
    $adbPath = Find-AdbPath

    if (-not $adbPath) {
        Add-Log "ADB not found. Add Android platform-tools to PATH."
        return
    }

    try {
        $output = & $adbPath devices
        $devices = @(
            $output |
                Select-Object -Skip 1 |
                Where-Object { $_ -match "\S+\s+device$" } |
                ForEach-Object { ($_ -split "\s+")[0] }
        )

        foreach ($device in $devices) {
            [void]$deviceCombo.Items.Add($device)
        }

        if ($deviceCombo.Items.Count -gt 0) {
            $deviceCombo.SelectedIndex = 0
            Add-Log "Connected device found: $($deviceCombo.SelectedItem)"
        } else {
            Add-Log "No authorized device found. Connect phone and approve USB debugging."
        }
    } catch {
        Add-Log "ADB device check failed: $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $installerScript)) {
    [System.Windows.Forms.MessageBox]::Show("Missing install-aab.ps1 beside this UI file.", "AAB Installer", "OK", "Error") | Out-Null
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "AAB to Phone Installer"
$form.Size = New-Object System.Drawing.Size(760, 850)
$form.MinimumSize = New-Object System.Drawing.Size(680, 790)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 249)
$form.AllowDrop = $true

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Install Android App Bundle"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(22, 18)
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Choose or paste an .aab or .xapk file, then install it to the connected phone."
$subtitleLabel.AutoSize = $true
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(86, 94, 108)
$subtitleLabel.Location = New-Object System.Drawing.Point(25, 52)
$form.Controls.Add($subtitleLabel)

$aabLabel = New-Object System.Windows.Forms.Label
$aabLabel.Text = "AAB / XAPK file path"
$aabLabel.AutoSize = $true
$aabLabel.Location = New-Object System.Drawing.Point(25, 92)
$form.Controls.Add($aabLabel)

$aabTextBox = New-Object System.Windows.Forms.TextBox
$aabTextBox.Anchor = "Top,Left,Right"
$aabTextBox.Location = New-Object System.Drawing.Point(28, 118)
$aabTextBox.Size = New-Object System.Drawing.Size(585, 29)
$form.Controls.Add($aabTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Anchor = "Top,Right"
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(625, 116)
$browseButton.Size = New-Object System.Drawing.Size(92, 32)
$form.Controls.Add($browseButton)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = "Device"
$deviceLabel.AutoSize = $true
$deviceLabel.Location = New-Object System.Drawing.Point(25, 170)
$form.Controls.Add($deviceLabel)

$deviceCombo = New-Object System.Windows.Forms.ComboBox
$deviceCombo.DropDownStyle = "DropDownList"
$deviceCombo.Location = New-Object System.Drawing.Point(28, 196)
$deviceCombo.Size = New-Object System.Drawing.Size(360, 29)
$form.Controls.Add($deviceCombo)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Refresh"
$refreshButton.Location = New-Object System.Drawing.Point(402, 194)
$refreshButton.Size = New-Object System.Drawing.Size(92, 32)
$form.Controls.Add($refreshButton)

# ---- Signing group (fixes Play Games "not initialized" via correct signature) ----
$signGroup = New-Object System.Windows.Forms.GroupBox
$signGroup.Text = "Signing (for Google Play Games)"
$signGroup.Anchor = "Top,Left,Right"
$signGroup.Location = New-Object System.Drawing.Point(28, 238)
$signGroup.Size = New-Object System.Drawing.Size(689, 150)
$form.Controls.Add($signGroup)

$signInfo = New-Object System.Windows.Forms.Label
$signInfo.Text = "Leave empty to sign with the Android debug key (matches Unity Build & Run). For a store/internal-testing build, use the SAME keystore whose SHA-1 you registered in Google Cloud Console."
$signInfo.ForeColor = [System.Drawing.Color]::FromArgb(86, 94, 108)
$signInfo.Location = New-Object System.Drawing.Point(12, 22)
$signInfo.Size = New-Object System.Drawing.Size(665, 34)
$signGroup.Controls.Add($signInfo)

$ksLabel = New-Object System.Windows.Forms.Label
$ksLabel.Text = "Keystore"
$ksLabel.AutoSize = $true
$ksLabel.Location = New-Object System.Drawing.Point(12, 64)
$signGroup.Controls.Add($ksLabel)

$ksTextBox = New-Object System.Windows.Forms.TextBox
$ksTextBox.Anchor = "Top,Left,Right"
$ksTextBox.Location = New-Object System.Drawing.Point(90, 61)
$ksTextBox.Size = New-Object System.Drawing.Size(478, 25)
$signGroup.Controls.Add($ksTextBox)

$ksBrowse = New-Object System.Windows.Forms.Button
$ksBrowse.Anchor = "Top,Right"
$ksBrowse.Text = "Browse"
$ksBrowse.Location = New-Object System.Drawing.Point(576, 59)
$ksBrowse.Size = New-Object System.Drawing.Size(92, 29)
$signGroup.Controls.Add($ksBrowse)

$aliasLabel = New-Object System.Windows.Forms.Label
$aliasLabel.Text = "Alias"
$aliasLabel.AutoSize = $true
$aliasLabel.Location = New-Object System.Drawing.Point(12, 104)
$signGroup.Controls.Add($aliasLabel)

$aliasTextBox = New-Object System.Windows.Forms.TextBox
$aliasTextBox.Location = New-Object System.Drawing.Point(90, 101)
$aliasTextBox.Size = New-Object System.Drawing.Size(150, 25)
$signGroup.Controls.Add($aliasTextBox)

$storePassLabel = New-Object System.Windows.Forms.Label
$storePassLabel.Text = "Store pass"
$storePassLabel.AutoSize = $true
$storePassLabel.Location = New-Object System.Drawing.Point(256, 104)
$signGroup.Controls.Add($storePassLabel)

$storePassBox = New-Object System.Windows.Forms.TextBox
$storePassBox.UseSystemPasswordChar = $true
$storePassBox.Location = New-Object System.Drawing.Point(338, 101)
$storePassBox.Size = New-Object System.Drawing.Size(120, 25)
$signGroup.Controls.Add($storePassBox)

$keyPassLabel = New-Object System.Windows.Forms.Label
$keyPassLabel.Text = "Key pass"
$keyPassLabel.AutoSize = $true
$keyPassLabel.Location = New-Object System.Drawing.Point(474, 104)
$signGroup.Controls.Add($keyPassLabel)

$keyPassBox = New-Object System.Windows.Forms.TextBox
$keyPassBox.Anchor = "Top,Right"
$keyPassBox.UseSystemPasswordChar = $false
$keyPassBox.Location = New-Object System.Drawing.Point(548, 101)
$keyPassBox.Size = New-Object System.Drawing.Size(120, 25)
$signGroup.Controls.Add($keyPassBox)

# ---- Tool paths group (replaces the old hard-coded ADB / Unity locations) ----
$toolsGroup = New-Object System.Windows.Forms.GroupBox
$toolsGroup.Text = "Tool paths (used to find ADB and Unity's bundletool)"
$toolsGroup.Anchor = "Top,Left,Right"
$toolsGroup.Location = New-Object System.Drawing.Point(28, 400)
$toolsGroup.Size = New-Object System.Drawing.Size(689, 108)
$form.Controls.Add($toolsGroup)

$adbLabel = New-Object System.Windows.Forms.Label
$adbLabel.Text = "ADB (adb.exe)"
$adbLabel.AutoSize = $true
$adbLabel.Location = New-Object System.Drawing.Point(12, 30)
$toolsGroup.Controls.Add($adbLabel)

$adbPathBox = New-Object System.Windows.Forms.TextBox
$adbPathBox.Anchor = "Top,Left,Right"
$adbPathBox.Location = New-Object System.Drawing.Point(128, 27)
$adbPathBox.Size = New-Object System.Drawing.Size(440, 25)
$toolsGroup.Controls.Add($adbPathBox)

$adbBrowse = New-Object System.Windows.Forms.Button
$adbBrowse.Anchor = "Top,Right"
$adbBrowse.Text = "Browse"
$adbBrowse.Location = New-Object System.Drawing.Point(576, 25)
$adbBrowse.Size = New-Object System.Drawing.Size(92, 29)
$toolsGroup.Controls.Add($adbBrowse)

$unityLabel = New-Object System.Windows.Forms.Label
$unityLabel.Text = "Unity Hub Editor"
$unityLabel.AutoSize = $true
$unityLabel.Location = New-Object System.Drawing.Point(12, 68)
$toolsGroup.Controls.Add($unityLabel)

$unityRootBox = New-Object System.Windows.Forms.TextBox
$unityRootBox.Anchor = "Top,Left,Right"
$unityRootBox.Location = New-Object System.Drawing.Point(128, 65)
$unityRootBox.Size = New-Object System.Drawing.Size(440, 25)
$toolsGroup.Controls.Add($unityRootBox)

$unityBrowse = New-Object System.Windows.Forms.Button
$unityBrowse.Anchor = "Top,Right"
$unityBrowse.Text = "Browse"
$unityBrowse.Location = New-Object System.Drawing.Point(576, 63)
$unityBrowse.Size = New-Object System.Drawing.Size(92, 29)
$toolsGroup.Controls.Add($unityBrowse)

$keepApksCheck = New-Object System.Windows.Forms.CheckBox
$keepApksCheck.Text = "Keep generated .apks file"
$keepApksCheck.AutoSize = $true
$keepApksCheck.Location = New-Object System.Drawing.Point(28, 528)
$form.Controls.Add($keepApksCheck)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Anchor = "Top,Right"
$installButton.Text = "Run Install"
$installButton.BackColor = [System.Drawing.Color]::FromArgb(31, 111, 235)
$installButton.ForeColor = [System.Drawing.Color]::White
$installButton.FlatStyle = "Flat"
$installButton.Location = New-Object System.Drawing.Point(585, 522)
$installButton.Size = New-Object System.Drawing.Size(132, 40)
$form.Controls.Add($installButton)

$xapkButton = New-Object System.Windows.Forms.Button
$xapkButton.Anchor = "Top,Right"
$xapkButton.Text = "Install XAPK"
$xapkButton.BackColor = [System.Drawing.Color]::FromArgb(22, 135, 87)
$xapkButton.ForeColor = [System.Drawing.Color]::White
$xapkButton.FlatStyle = "Flat"
$xapkButton.Location = New-Object System.Drawing.Point(441, 522)
$xapkButton.Size = New-Object System.Drawing.Size(132, 40)
$form.Controls.Add($xapkButton)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Anchor = "Top,Left,Right"
$progress.Style = "Marquee"
$progress.MarqueeAnimationSpeed = 30
$progress.Location = New-Object System.Drawing.Point(28, 576)
$progress.Size = New-Object System.Drawing.Size(689, 12)
$progress.Visible = $false
$form.Controls.Add($progress)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Anchor = "Top,Bottom,Left,Right"
$logBox.Location = New-Object System.Drawing.Point(28, 604)
$logBox.Size = New-Object System.Drawing.Size(689, 150)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(22, 27, 34)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(229, 231, 235)
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($logBox)

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select Android App Bundle"
    $dialog.Filter = "Android App Bundle (*.aab)|*.aab|XAPK (*.xapk)|*.xapk|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") {
        $aabTextBox.Text = $dialog.FileName
    }
})

$refreshButton.Add_Click({
    Refresh-Devices
})

$ksBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select signing keystore"
    $dialog.Filter = "Keystore (*.keystore;*.jks)|*.keystore;*.jks|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") {
        $ksTextBox.Text = $dialog.FileName
    }
})

$adbBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select adb.exe"
    $dialog.Filter = "adb (adb.exe)|adb.exe|Executable (*.exe)|*.exe|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") {
        $adbPathBox.Text = $dialog.FileName
    }
})

$unityBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select the Unity Hub Editor folder (contains the Unity version folders)"
    if ($dialog.ShowDialog() -eq "OK") {
        $unityRootBox.Text = $dialog.SelectedPath
    }
})

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})

$form.Add_DragDrop({
    $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files.Count -gt 0 -and @(".aab", ".xapk") -contains [IO.Path]::GetExtension($files[0]).ToLowerInvariant()) {
        $aabTextBox.Text = $files[0]
    }
})

$installButton.Add_Click({
    try {
        $aabPath = $aabTextBox.Text.Trim('" ')
        if (-not (Test-Path -LiteralPath $aabPath)) {
            [System.Windows.Forms.MessageBox]::Show("Please select a valid .aab file.", "AAB Installer", "OK", "Warning") | Out-Null
            return
        }

        if ([IO.Path]::GetExtension($aabPath).ToLowerInvariant() -ne ".aab") {
            [System.Windows.Forms.MessageBox]::Show("Selected file must be an .aab file.", "AAB Installer", "OK", "Warning") | Out-Null
            return
        }

        if (-not $deviceCombo.SelectedItem) {
            [System.Windows.Forms.MessageBox]::Show("No device selected. Connect your phone and click Refresh.", "AAB Installer", "OK", "Warning") | Out-Null
            return
        }

        $ksPath = $ksTextBox.Text.Trim('" ')
        if ($ksPath) {
            if (-not (Test-Path -LiteralPath $ksPath)) {
                [System.Windows.Forms.MessageBox]::Show("Keystore file not found.", "AAB Installer", "OK", "Warning") | Out-Null
                return
            }
            if (-not $aliasTextBox.Text.Trim() -or -not $storePassBox.Text) {
                [System.Windows.Forms.MessageBox]::Show("When a keystore is set, Alias and Store pass are required.", "AAB Installer", "OK", "Warning") | Out-Null
                return
            }
        }

        # Remember keystore, alias, tool paths AND passwords for next time.
        Save-Config (Get-CurrentConfig)

        $logBox.Clear()
        Set-Content -LiteralPath $logFile -Value "" -ErrorAction SilentlyContinue
        Add-Log "Starting install..."
        Set-Busy $true

        $argsList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $installerScript,
            $aabPath,
            "-DeviceId", [string]$deviceCombo.SelectedItem
        )

        $bundletoolPath = Get-BundletoolPath
        if ($bundletoolPath) {
            $argsList += @("-BundletoolJar", $bundletoolPath)
        }

        $adbPath = Find-AdbPath
        if ($adbPath) {
            $argsList += @("-AdbPath", $adbPath)
        }

        if ($unityRootBox.Text.Trim()) {
            $argsList += @("-UnityEditorRoot", $unityRootBox.Text.Trim())
        }

        if ($keepApksCheck.Checked) {
            $argsList += "-KeepApks"
        }

        if ($ksPath) {
            $argsList += @("-Keystore", $ksPath, "-KsKeyAlias", $aliasTextBox.Text.Trim(), "-KsPass", $storePassBox.Text)
            if ($keyPassBox.Text) {
                $argsList += @("-KeyPass", $keyPassBox.Text)
            }
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo.FileName = "powershell.exe"
        $process.StartInfo.Arguments = ($argsList | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
        $process.StartInfo.WorkingDirectory = $scriptDir
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.EnableRaisingEvents = $true

        # NOTE: these callbacks run on background threads. Any exception that escapes
        # them tears down the message loop and closes the window with exit code 0
        # (no error shown). Everything here is wrapped so that can't happen.
        $process.add_OutputDataReceived({
            param($eventSender, $eventData)
            try {
                if ($eventData -and $eventData.Data -and -not $form.IsDisposed) {
                    $form.BeginInvoke([Action[string]]{ param($line) try { Add-Log $line } catch {} }, $eventData.Data) | Out-Null
                }
            } catch {
                Report-Crash $_ "OutputDataReceived"
            }
        })

        $process.add_ErrorDataReceived({
            param($eventSender, $eventData)
            try {
                if ($eventData -and $eventData.Data -and -not $form.IsDisposed) {
                    $form.BeginInvoke([Action[string]]{ param($line) try { Add-Log $line } catch {} }, $eventData.Data) | Out-Null
                }
            } catch {
                Report-Crash $_ "ErrorDataReceived"
            }
        })

        $process.add_Exited({
            param($eventSender, $eventData)
            try {
                if (-not $form.IsDisposed) {
                    $exitCode = $process.ExitCode
                    $form.BeginInvoke([Action[int]]{
                        param($code)
                        try {
                            Set-Busy $false
                            if ($code -eq 0) {
                                Add-Log "Install finished successfully."
                                [System.Windows.Forms.MessageBox]::Show("App installed successfully.", "AAB Installer", "OK", "Information") | Out-Null
                            } else {
                                Add-Log "Install failed with exit code $code."
                                Add-Log "Log file: $logFile"
                                [System.Windows.Forms.MessageBox]::Show("Install failed. Check the log box or aab-install-last.log.", "AAB Installer", "OK", "Error") | Out-Null
                            }
                        } catch {
                            Report-Crash $_ "ExitedUiAction"
                        }
                    }, $exitCode) | Out-Null
                }
            } catch {
                Report-Crash $_ "Exited"
            } finally {
                try { $process.Dispose() } catch {}
            }
        })

        $safeArgs = $process.StartInfo.Arguments -replace '(-KsPass|-KeyPass)\s+("[^"]*"|\S+)', '$1 ****'
        Add-Log "Command: powershell.exe $safeArgs"
        [void]$process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
    } catch {
        Set-Busy $false
        Add-Log "UI error: $($_.Exception.Message)"
        Add-Log "Log file: $logFile"
        [System.Windows.Forms.MessageBox]::Show("Installer UI error: $($_.Exception.Message)", "AAB Installer", "OK", "Error") | Out-Null
    }
})
$xapkButton.Add_Click({
    try {
        $xapkPath = $aabTextBox.Text.Trim('" ')
        if ([IO.Path]::GetExtension($xapkPath).ToLowerInvariant() -ne ".xapk" -or -not (Test-Path -LiteralPath $xapkPath)) {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title = "Select XAPK file"
            $dialog.Filter = "XAPK (*.xapk)|*.xapk|All files (*.*)|*.*"
            if ($dialog.ShowDialog() -ne "OK") {
                return
            }
            $xapkPath = $dialog.FileName
            $aabTextBox.Text = $xapkPath
        }

        if (-not $deviceCombo.SelectedItem) {
            [System.Windows.Forms.MessageBox]::Show("No device selected. Connect your phone and click Refresh.", "XAPK Installer", "OK", "Warning") | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $xapkInstallerScript)) {
            [System.Windows.Forms.MessageBox]::Show("Missing install-xapk.ps1 beside this UI file.", "XAPK Installer", "OK", "Error") | Out-Null
            return
        }

        Save-Config (Get-CurrentConfig)

        $logBox.Clear()
        Set-Content -LiteralPath $logFile -Value "" -ErrorAction SilentlyContinue
        Add-Log "Starting XAPK install..."
        Set-Busy $true

        $argsList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $xapkInstallerScript,
            $xapkPath,
            "-DeviceId", [string]$deviceCombo.SelectedItem
        )

        $adbPath = Find-AdbPath
        if ($adbPath) {
            $argsList += @("-AdbPath", $adbPath)
        }

        # ponytail: same process/log plumbing as the AAB button, kept separate so the AAB path stays untouched.
        $xapkProcess = New-Object System.Diagnostics.Process
        $xapkProcess.StartInfo.FileName = "powershell.exe"
        $xapkProcess.StartInfo.Arguments = ($argsList | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
        $xapkProcess.StartInfo.WorkingDirectory = $scriptDir
        $xapkProcess.StartInfo.UseShellExecute = $false
        $xapkProcess.StartInfo.RedirectStandardOutput = $true
        $xapkProcess.StartInfo.RedirectStandardError = $true
        $xapkProcess.EnableRaisingEvents = $true

        $onData = {
            param($eventSender, $eventData)
            try {
                if ($eventData -and $eventData.Data -and -not $form.IsDisposed) {
                    $form.BeginInvoke([Action[string]]{ param($line) try { Add-Log $line } catch {} }, $eventData.Data) | Out-Null
                }
            } catch {
                Report-Crash $_ "XapkDataReceived"
            }
        }
        $xapkProcess.add_OutputDataReceived($onData)
        $xapkProcess.add_ErrorDataReceived($onData)

        $xapkProcess.add_Exited({
            param($eventSender, $eventData)
            try {
                if (-not $form.IsDisposed) {
                    $form.BeginInvoke([Action[int]]{
                        param($code)
                        try {
                            Set-Busy $false
                            if ($code -eq 0) {
                                Add-Log "XAPK install finished successfully."
                                [System.Windows.Forms.MessageBox]::Show("App installed successfully.", "XAPK Installer", "OK", "Information") | Out-Null
                            } else {
                                Add-Log "XAPK install failed with exit code $code."
                                Add-Log "Log file: $logFile"
                                [System.Windows.Forms.MessageBox]::Show("Install failed. Check the log box or aab-install-last.log.", "XAPK Installer", "OK", "Error") | Out-Null
                            }
                        } catch {
                            Report-Crash $_ "XapkExitedUiAction"
                        }
                    }, $eventSender.ExitCode) | Out-Null
                }
            } catch {
                Report-Crash $_ "XapkExited"
            } finally {
                try { $eventSender.Dispose() } catch {}
            }
        })

        Add-Log "Command: powershell.exe $($xapkProcess.StartInfo.Arguments)"
        [void]$xapkProcess.Start()
        $xapkProcess.BeginOutputReadLine()
        $xapkProcess.BeginErrorReadLine()
    } catch {
        Set-Busy $false
        Add-Log "UI error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Installer UI error: $($_.Exception.Message)", "XAPK Installer", "OK", "Error") | Out-Null
    }
})

try {
    $savedConfig = Load-Config
    if ($savedConfig) {
        if ($savedConfig.Keystore) { $ksTextBox.Text = [string]$savedConfig.Keystore }
        if ($savedConfig.Alias) { $aliasTextBox.Text = [string]$savedConfig.Alias }
        if ($savedConfig.StorePass) { $storePassBox.Text = [string]$savedConfig.StorePass }
        if ($savedConfig.KeyPass) { $keyPassBox.Text = [string]$savedConfig.KeyPass }
        if ($savedConfig.AdbPath) { $adbPathBox.Text = [string]$savedConfig.AdbPath }
        if ($savedConfig.UnityEditorRoot) { $unityRootBox.Text = [string]$savedConfig.UnityEditorRoot }
    }
} catch {
    Report-Crash $_ "LoadConfig"
}

# Pre-fill the path boxes with the built-in defaults when the config left them empty.
if (-not $adbPathBox.Text.Trim()) { $adbPathBox.Text = $defaultAdbPath }
if (-not $unityRootBox.Text.Trim()) { $unityRootBox.Text = $defaultUnityEditorRoot }

# Persist every field (paths + passwords) when the window closes.
$form.Add_FormClosing({
    try { Save-Config (Get-CurrentConfig) } catch { }
})

try { Add-Log "bundletool: $(Get-BundletoolPath)" } catch { Report-Crash $_ "GetBundletool" }
try { Add-Log "adb: $(Find-AdbPath)" } catch { Report-Crash $_ "FindAdb" }
try { Refresh-Devices } catch { Report-Crash $_ "RefreshDevices" }

try {
    [void]$form.ShowDialog()
} catch {
    Report-Crash $_ "ShowDialog"
}

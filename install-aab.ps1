param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$AabPath,

    [string]$BundletoolJar = "",
    [string]$AdbPath = "",
    [string]$DeviceId = "",

    # Tool locations (overridable from the UI / config instead of being hard-coded).
    [string]$UnityEditorRoot = "C:\Program Files\Unity\Hub\Editor",
    [string]$DefaultAdbPath = "C:/AndroidSDKForAndroidStudio/platform-tools/adb.exe",

    [string]$Keystore = "",
    [string]$KsPass = "",
    [string]$KsKeyAlias = "",
    [string]$KeyPass = "",

    [switch]$KeepApks,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Resolve-File($PathValue, $Description) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $resolved = Resolve-Path -LiteralPath $PathValue -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Fail "$Description not found: $PathValue"
    }

    return $resolved.Path
}

function Find-CommandPath($Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Find-KeytoolPath($JavaPath) {
    # keytool ships in the JDK/JRE bin folder, right next to java.exe.
    if ($JavaPath) {
        $candidate = Join-Path (Split-Path -Parent $JavaPath) "keytool.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return (Find-CommandPath "keytool")
}

function Get-DefaultDebugKeystore {
    # Unity "Build and Run" (without a custom keystore) signs with the Android
    # debug key at %USERPROFILE%\.android\debug.keystore. Matching it here makes
    # the sideloaded build's signature identical to a Unity debug build.
    $path = Join-Path $env:USERPROFILE ".android\debug.keystore"
    if (Test-Path -LiteralPath $path) {
        return [pscustomobject]@{
            Keystore = $path
            KsPass   = "android"
            Alias    = "androiddebugkey"
            KeyPass  = "android"
        }
    }

    return $null
}

function Show-SigningSha($KeytoolPath, $Keystore, $KsPass, $Alias) {
    if (-not $KeytoolPath) {
        Write-Host "WARNING: keytool not found; cannot print signing SHA-1. Install a JDK to enable this." -ForegroundColor Yellow
        return
    }

    $ktArgs = @("-list", "-v", "-keystore", $Keystore, "-alias", $Alias, "-storepass", $KsPass)
    # keytool may emit warnings on stderr; discard them so ErrorActionPreference=Stop
    # in this script does not turn them into a terminating error that aborts install.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $KeytoolPath @ktArgs 2>$null
    } catch {
        $output = $null
    } finally {
        $ErrorActionPreference = $prevEap
    }

    if (($LASTEXITCODE -ne 0) -or (-not $output)) {
        Write-Host "WARNING: Could not read signing certificate from keystore (wrong password/alias?)." -ForegroundColor Yellow
        return
    }

    Write-Host "---- Signing certificate (register this in Google Cloud Console for Play Games) ----" -ForegroundColor Cyan
    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match 'SHA1:' -or $text -match 'SHA-1:' -or $text -match 'SHA256:' -or $text -match 'SHA-256:') {
            Write-Host ("   " + $text.Trim()) -ForegroundColor Cyan
        }
    }
    Write-Host "-----------------------------------------------------------------------------------" -ForegroundColor Cyan
}
function Get-UnityAndroidPlayerRoots {
    $editorRoot = $UnityEditorRoot
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
function Get-AabPackageName($JavaPath, $BundletoolPath, $BundlePath) {
    $dumpArgs = @(
        "-jar", $BundletoolPath,
        "dump",
        "manifest",
        "--bundle=$BundlePath",
        "--xpath=/manifest/@package"
    )

    $output = & $JavaPath $dumpArgs
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    foreach ($line in $output) {
        $value = ([string]$line).Trim()
        if ($value -match '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
            return $value
        }
    }

    return $null
}

function Launch-InstalledApp($AdbExecutable, $TargetDeviceId, $PackageName) {
    Write-Host "Launching app: $PackageName"
    & $AdbExecutable -s $TargetDeviceId shell monkey -p $PackageName 1
    return $LASTEXITCODE
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultAdbPath = $DefaultAdbPath
$aab = Resolve-File $AabPath "AAB file"
if ([IO.Path]::GetExtension($aab).ToLowerInvariant() -ne ".aab") {
    Fail "Input file must be an .aab file."
}

$java = Find-CommandPath "java"
if (-not $java) {
    Fail "Java was not found in PATH. Install JDK/JRE first."
}

if ([string]::IsNullOrWhiteSpace($AdbPath)) {
    $adbCandidates = @(
        $env:ANDROID_QA_MCP_ADB,
        (Find-UnityAdbPath),
        $defaultAdbPath,
        (Find-CommandPath "adb"),
        (Join-Path $scriptDir "adb.exe")
    )

    foreach ($candidate in $adbCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $AdbPath = $candidate
            break
        }
    }
}
$AdbPath = Resolve-File $AdbPath "ADB"

if ([string]::IsNullOrWhiteSpace($BundletoolJar)) {
    if ($env:BUNDLETOOL_JAR) {
        $BundletoolJar = $env:BUNDLETOOL_JAR
    } else {
        $BundletoolJar = Find-UnityBundletoolPath
        if (-not $BundletoolJar) {
            $bundletoolSearchRoots = @($scriptDir, (Join-Path $scriptDir "tools")) |
                Where-Object { Test-Path -LiteralPath $_ }
            $localBundletool = @(foreach ($root in $bundletoolSearchRoots) {
                Get-ChildItem -LiteralPath $root -Filter "bundletool*.jar" -File -ErrorAction SilentlyContinue
            }) |
                Sort-Object Name -Descending |
                Select-Object -First 1
            if ($localBundletool) {
                $BundletoolJar = $localBundletool.FullName
            }
        }
    }
}
$BundletoolJar = Resolve-File $BundletoolJar "bundletool jar"
$packageName = Get-AabPackageName $java $BundletoolJar $aab
if ($packageName) {
    Write-Host "Package: $packageName"
} else {
    Write-Host "WARNING: Could not detect package name. Install will continue, but auto-launch will be skipped."
}

Write-Host "Checking connected Android device..."
$devicesOutput = & $AdbPath devices
if ($LASTEXITCODE -ne 0) {
    Fail "ADB failed to list devices."
}

$connectedDevices = @(
    $devicesOutput |
        Select-Object -Skip 1 |
        Where-Object { $_ -match "\S+\s+device$" } |
        ForEach-Object { ($_ -split "\s+")[0] }
)

if ($DeviceId) {
    if ($connectedDevices -notcontains $DeviceId) {
        Fail "Device '$DeviceId' is not connected/authorized. Run 'adb devices' and check USB debugging."
    }
} elseif ($connectedDevices.Count -eq 1) {
    $DeviceId = $connectedDevices[0]
} elseif ($connectedDevices.Count -eq 0) {
    Fail "No authorized Android device found. Connect phone, enable USB debugging, and approve the prompt."
} else {
    Fail "Multiple devices found: $($connectedDevices -join ', '). Re-run with -DeviceId <id>."
}

$baseName = [IO.Path]::GetFileNameWithoutExtension($aab)
$aabDir = Split-Path -Parent $aab
$adjacentApks = Join-Path $aabDir "$baseName.apks"
$createdApks = $false

if (Test-Path -LiteralPath $adjacentApks -PathType Leaf) {
    $apks = $adjacentApks
    Write-Host "Using existing APKS beside AAB: $apks"
    Write-Host "NOTE: This .apks is installed as-is; its existing signature is used." -ForegroundColor Yellow
    Write-Host "      If Play Games fails to initialize, delete this .apks so it is rebuilt and re-signed." -ForegroundColor Yellow
} else {
    $outDir = Join-Path $scriptDir "aab-install-output"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $apks = Join-Path $outDir "$baseName-$DeviceId.apks"

    if (Test-Path -LiteralPath $apks) {
        Remove-Item -LiteralPath $apks -Force
    }

    $buildArgs = @(
        "-jar", $BundletoolJar,
        "build-apks",
        "--bundle=$aab",
        "--output=$apks",
        "--mode=persistent",
        "--local-testing",
        "--overwrite"
    )

    # Resolve which key will sign the split APKs. Play Games only initializes when
    # the installed app's signing SHA-1 is registered in the game's Google Cloud
    # project, so we sign with the same key Unity uses instead of bundletool's
    # throwaway debug key.
    $effectiveKeystore = $null
    $effectiveKsPass = $null
    $effectiveAlias = $null
    $effectiveKeyPass = $null

    if ($Keystore) {
        $effectiveKeystore = Resolve-File $Keystore "Keystore"
        if (-not $KsPass -or -not $KsKeyAlias) {
            Fail "When using -Keystore, you must also pass -KsPass and -KsKeyAlias."
        }
        $effectiveKsPass = $KsPass
        $effectiveAlias = $KsKeyAlias
        $effectiveKeyPass = if ($KeyPass) { $KeyPass } else { $KsPass }
        Write-Host "Signing with custom keystore: $effectiveKeystore (alias: $effectiveAlias)"
    } else {
        $debugKs = Get-DefaultDebugKeystore
        if ($debugKs) {
            $effectiveKeystore = $debugKs.Keystore
            $effectiveKsPass = $debugKs.KsPass
            $effectiveAlias = $debugKs.Alias
            $effectiveKeyPass = $debugKs.KeyPass
            Write-Host "No -Keystore given. Signing with the Android debug keystore (matches Unity Build & Run default):"
            Write-Host "   $effectiveKeystore"
        } else {
            Write-Host "WARNING: No keystore given and no Android debug keystore found." -ForegroundColor Yellow
            Write-Host "         bundletool will use its own debug key. Play Games will likely fail to initialize" -ForegroundColor Yellow
            Write-Host "         unless that key's SHA-1 is registered in your Google Cloud project." -ForegroundColor Yellow
        }
    }

    if ($effectiveKeystore) {
        $buildArgs += "--ks=$effectiveKeystore"
        $buildArgs += "--ks-pass=pass:$effectiveKsPass"
        $buildArgs += "--ks-key-alias=$effectiveAlias"
        $buildArgs += "--key-pass=pass:$effectiveKeyPass"

        try {
            $keytool = Find-KeytoolPath $java
            Show-SigningSha $keytool $effectiveKeystore $effectiveKsPass $effectiveAlias
        } catch {
            Write-Host "WARNING: Could not print signing SHA-1 (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Host "Building local-testing APKS from AAB..."
    & $java $buildArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "bundletool build-apks failed."
    }

    $createdApks = $true
}

$installArgs = @(
    "-jar", $BundletoolJar,
    "install-apks",
    "--apks=$apks",
    "--adb=$AdbPath"
)
Write-Host "Installing on device $DeviceId..."
$previousAndroidSerial = $env:ANDROID_SERIAL
$env:ANDROID_SERIAL = $DeviceId
& $java $installArgs
$installExitCode = $LASTEXITCODE
if ($null -eq $previousAndroidSerial) {
    Remove-Item Env:\ANDROID_SERIAL -ErrorAction SilentlyContinue
} else {
    $env:ANDROID_SERIAL = $previousAndroidSerial
}
if ($installExitCode -ne 0) {
    Fail "bundletool install-apks failed."
}

Write-Host "Done. AAB installed successfully on $DeviceId." -ForegroundColor Green
if (-not $NoLaunch -and $packageName) {
    $launchExitCode = Launch-InstalledApp $AdbPath $DeviceId $packageName
    if ($launchExitCode -ne 0) {
        Write-Host "WARNING: App installed, but auto-launch failed." -ForegroundColor Yellow
    }
} elseif (-not $NoLaunch) {
    Write-Host "WARNING: App installed, but package name was unavailable so auto-launch was skipped." -ForegroundColor Yellow
}

if ($KeepApks -or -not $createdApks) {
    Write-Host "Kept APK set: $apks"
} else {
    Remove-Item -LiteralPath $apks -Force -ErrorAction SilentlyContinue
}

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$XapkPath,

    [string]$AdbPath = "",
    [string]$DeviceId = "",
    [string]$DefaultAdbPath = "C:/AndroidSDKForAndroidStudio/platform-tools/adb.exe",

    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$xapk = Resolve-Path -LiteralPath $XapkPath -ErrorAction SilentlyContinue
if (-not $xapk) {
    Fail "XAPK file not found: $XapkPath"
}
$xapk = $xapk.Path
if ([IO.Path]::GetExtension($xapk).ToLowerInvariant() -ne ".xapk") {
    Fail "Input file must be an .xapk file."
}

if ([string]::IsNullOrWhiteSpace($AdbPath)) {
    # ponytail: no Unity SDK lookup here; the UI always passes -AdbPath.
    foreach ($candidate in @($env:ANDROID_QA_MCP_ADB, $DefaultAdbPath, (Get-Command "adb" -ErrorAction SilentlyContinue).Source, (Join-Path $scriptDir "adb.exe"))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $AdbPath = $candidate
            break
        }
    }
}
if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
    Fail "ADB not found: $AdbPath"
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

# XAPK is a plain zip: split APKs at the root, optional OBBs under Android/obb/<package>/.
# Expand-Archive refuses non-.zip extensions in PS 5.1, so use ZipFile directly.
$extractDir = Join-Path ([IO.Path]::GetTempPath()) ("xapk-" + [guid]::NewGuid().ToString("N"))
try {
    Write-Host "Extracting XAPK..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($xapk, $extractDir)

    $packageName = $null
    $manifestFile = Join-Path $extractDir "manifest.json"
    if (Test-Path -LiteralPath $manifestFile) {
        try {
            $packageName = (Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json).package_name
        } catch {
        }
    }
    if ($packageName) {
        Write-Host "Package: $packageName"
    } else {
        Write-Host "WARNING: Could not detect package name from manifest.json. Auto-launch will be skipped." -ForegroundColor Yellow
    }

    $apkFiles = @(Get-ChildItem -LiteralPath $extractDir -Filter "*.apk" -File | ForEach-Object { $_.FullName })
    if ($apkFiles.Count -eq 0) {
        Fail "No .apk files found inside the XAPK."
    }

    Write-Host "Installing $($apkFiles.Count) APK(s) on device $DeviceId..."
    $apkFiles | ForEach-Object { Write-Host "   $([IO.Path]::GetFileName($_))" }
    & $AdbPath -s $DeviceId install-multiple -r @apkFiles
    if ($LASTEXITCODE -ne 0) {
        Fail "adb install-multiple failed. (INSTALL_FAILED_UPDATE_INCOMPATIBLE = uninstall the existing app first; it has a different signature.)"
    }

    $obbRoot = Join-Path $extractDir "Android\obb"
    if (Test-Path -LiteralPath $obbRoot) {
        foreach ($obb in Get-ChildItem -LiteralPath $obbRoot -File -Recurse) {
            $remote = "/sdcard/Android/obb/" + $obb.FullName.Substring($obbRoot.Length + 1).Replace('\', '/')
            Write-Host "Pushing OBB: $remote"
            & $AdbPath -s $DeviceId shell mkdir -p ($remote.Substring(0, $remote.LastIndexOf('/')))
            & $AdbPath -s $DeviceId push $obb.FullName $remote
            if ($LASTEXITCODE -ne 0) {
                Fail "adb push failed for OBB: $($obb.Name)"
            }
        }
    }

    Write-Host "Done. XAPK installed successfully on $DeviceId." -ForegroundColor Green
    if (-not $NoLaunch -and $packageName) {
        Write-Host "Launching app: $packageName"
        & $AdbPath -s $DeviceId shell monkey -p $packageName 1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: App installed, but auto-launch failed." -ForegroundColor Yellow
        }
    }
} finally {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

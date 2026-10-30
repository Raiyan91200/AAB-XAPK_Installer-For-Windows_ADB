# AAB / XAPK Phone Installer

A small Windows tool that installs Android **.aab** (Android App Bundle) and **.xapk** files on a phone connected over USB, using ADB. You get a simple window: pick a file, pick the device, click install. The app is installed and launched for you.

It is made for Unity Android developers who need to test a store-style build (AAB) on a real phone, including builds that use **Google Play Games**, which only start when the app is signed with the right key.

---

## Features

- **AAB install**: turns the bundle into device-specific APKs with `bundletool` and installs them.
- **XAPK install**: extracts the XAPK, installs all split APKs with `adb install-multiple`, and copies OBB files to the phone.
- **Correct signing for Play Games**: signs AAB builds with your release keystore or the Android debug key, so the signing SHA-1 matches what is registered in Google Cloud.
- **Prints the signing SHA-1 / SHA-256** during install, ready to copy into Google Cloud Console.
- **Opens the app automatically** after install.
- **Finds tools automatically**: ADB and bundletool are taken from your Unity installation first, then from the Android SDK, PATH, or the local `tools` folder.
- **Drag and drop** `.aab` / `.xapk` files onto the window.
- **Remembers your settings** (keystore, alias, passwords, tool paths) between runs.
- **Live log** in the window, also saved to `aab-install-last.log`.

---

## Requirements

| Requirement | Why | Where to get it |
|---|---|---|
| Windows with PowerShell 5.1+ | Runs the UI and scripts | Built into Windows 10/11 |
| Java (JDK or JRE) on `PATH` | Runs `bundletool` (AAB only) and `keytool` (prints SHA-1) | Unity's bundled OpenJDK, Android Studio JBR, or any JDK 11+ |
| ADB (`adb.exe`) | Talks to the phone | Unity Android Build Support, Android Studio, or [platform-tools](https://developer.android.com/tools/releases/platform-tools) |
| bundletool jar | Converts AAB to APKs (AAB only) | Comes with Unity Android Build Support; a fallback copy is in `tools/` |
| Android phone with **USB debugging** on | Install target | Settings → Developer options → USB debugging |

XAPK installs need only ADB. Java and bundletool are not used.

---

## Quick start

1. Connect the phone by USB and accept the **"Allow USB debugging?"** prompt on the phone.
2. Double-click **`install-aab-ui.bat`**.
3. Check that your phone shows in the **Device** list (click **Refresh** if it doesn't).
4. Pick your file with **Browse**, paste the path, or drag the file onto the window.
5. Click:
   - **Run Install** for an `.aab` file
   - **Install XAPK** for an `.xapk` file
6. Follow the log. When it finishes, the app opens on the phone and a "installed successfully" message is shown.

---

## The window, field by field

| Field | Used by | What it does |
|---|---|---|
| **AAB / XAPK file path** | Both | The file to install. Browse, paste, or drag and drop. |
| **Device** | Both | The connected, authorized phone to install on. **Refresh** reloads the list. |
| **Keystore** | AAB | Keystore (`.keystore` / `.jks`) used to sign the APKs. Leave empty to use the Android debug key. |
| **Alias** | AAB | Key alias inside the keystore. Required when Keystore is set. |
| **Store pass** | AAB | Keystore password. Required when Keystore is set. |
| **Key pass** | AAB | Key password. If empty, Store pass is used. |
| **ADB (adb.exe)** | Both | Path to `adb.exe`. Pre-filled with a default; change it if your SDK is somewhere else. |
| **Unity Hub Editor** | AAB | Folder that holds your Unity versions (for example `C:\Program Files\Unity\Hub\Editor`). Used to find Unity's ADB and bundletool. |
| **Keep generated .apks file** | AAB | Keeps the built `.apks` in `aab-install-output/` instead of deleting it after install. |
| **Install XAPK** | XAPK | Installs the `.xapk` in the path box. If the box does not hold an `.xapk`, a file picker opens. |
| **Run Install** | AAB | Builds and installs the `.aab` in the path box. |

---

## How AAB install works

```
.aab ──► bundletool build-apks (signed, --local-testing) ──► .apks ──► bundletool install-apks ──► adb ──► phone ──► app launches
```

1. Reads the package name from the bundle's manifest (used for auto-launch).
2. Checks that the selected device is connected and authorized.
3. **If a `.apks` with the same name sits next to the `.aab`**, that file is installed as it is (with its old signature).
   Otherwise, a new `.apks` is built in `aab-install-output/` with `--mode=persistent --local-testing`, signed with:
   - your **keystore** if you filled in the Signing box, or
   - the **Android debug keystore** (`%USERPROFILE%\.android\debug.keystore`), the same key Unity's *Build and Run* uses, or
   - bundletool's own debug key, as a last resort (shows a warning).
4. Prints the signing certificate's **SHA-1 / SHA-256**.
5. Installs the right splits for the phone with `bundletool install-apks`.
6. Launches the app.
7. Deletes the built `.apks` unless **Keep generated .apks file** is ticked.

## How XAPK install works

```
.xapk (zip) ──► extract to temp ──► adb install-multiple -r *.apk ──► adb push OBBs ──► app launches
```

1. Extracts the XAPK (it is a zip file) to a temporary folder.
2. Reads `package_name` from `manifest.json`.
3. Installs **every `.apk`** at the top level of the archive in one step with `adb install-multiple -r` (`-r` = replace an existing install, keeping its data).
4. If the archive has `Android/obb/<package>/...`, each OBB is pushed to `/sdcard/Android/obb/<package>/` on the phone.
5. Launches the app and deletes the temporary folder.

XAPK files are already signed, so the **Signing box is not used** for XAPK installs.

---

## Signing and Google Play Games

Play Games only starts when the installed app's **signing certificate SHA-1** is registered as an **OAuth 2.0 Android client** in the game's Google Cloud project. If it is not, the game shows Play Games as *"not initialized"*.

- **Testing a debug build** → leave the Signing box empty. The tool signs with the Android debug key, which is usually already registered (it is what *Build and Run* uses).
- **Testing a release / internal-testing build** → enter the **same keystore Unity uses to build the AAB** (path, alias, passwords).
- During install, copy the **SHA-1** from the log and check it is listed under **Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client IDs (Android)** for your package name.
- An old `.apks` next to the `.aab` is installed **without re-signing**. If Play Games fails, delete that `.apks` so the tool rebuilds and signs it again.

---

## How tools are found

**ADB** (first match wins):
1. `ANDROID_QA_MCP_ADB` environment variable
2. The **ADB** box in the window
3. Unity: `<Unity Hub Editor>\<version>\Editor\Data\PlaybackEngines\AndroidPlayer\SDK\platform-tools\adb.exe` (newest version first)
4. `C:/AndroidSDKForAndroidStudio/platform-tools/adb.exe`
5. `%ANDROID_HOME%\platform-tools\adb.exe`, then `%ANDROID_SDK_ROOT%\platform-tools\adb.exe`
6. `adb` on `PATH`
7. `adb.exe` next to the scripts

**bundletool** (first match wins):
1. `BUNDLETOOL_JAR` environment variable
2. Unity: `...\AndroidPlayer\Tools\bundletool*.jar` (newest version first)
3. `bundletool*.jar` next to the scripts, then in `tools/`

**Java / keytool**: `java` from `PATH`; `keytool` from the same folder as `java.exe`, otherwise from `PATH`.

The paths found are printed at the top of the log when the window opens.

---

## Command-line use (no window)

Both installers can be run straight from PowerShell.

### AAB

```powershell
.\install-aab.ps1 "D:\Builds\MyGame.aab" -DeviceId R58M12345AB
```

With a release keystore, keeping the `.apks`:

```powershell
.\install-aab.ps1 "D:\Builds\MyGame.aab" -Keystore "D:\keys\release.keystore" -KsKeyAlias mykey -KsPass "****" -KeyPass "****" -KeepApks
```

| Parameter | Description |
|---|---|
| `AabPath` (1st, required) | Path to the `.aab` |
| `-DeviceId` | ADB serial. Optional when only one device is connected. |
| `-AdbPath` | Path to `adb.exe` (found automatically if left out) |
| `-BundletoolJar` | Path to the bundletool jar (found automatically if left out) |
| `-UnityEditorRoot` | Unity Hub Editor folder, used to find ADB / bundletool |
| `-DefaultAdbPath` | Fallback ADB path |
| `-Keystore`, `-KsKeyAlias`, `-KsPass`, `-KeyPass` | Signing key. Without them, the Android debug keystore is used. |
| `-KeepApks` | Keep the built `.apks` |
| `-NoLaunch` | Don't open the app after install |

### XAPK

```powershell
.\install-xapk.ps1 "D:\Downloads\MyGame.xapk" -DeviceId R58M12345AB
```

| Parameter | Description |
|---|---|
| `XapkPath` (1st, required) | Path to the `.xapk` |
| `-DeviceId` | ADB serial. Optional when only one device is connected. |
| `-AdbPath` | Path to `adb.exe` (found automatically if left out) |
| `-DefaultAdbPath` | Fallback ADB path |
| `-NoLaunch` | Don't open the app after install |

Both scripts exit with code `0` on success and `1` on failure.

---

## Project files

| File / folder | Purpose |
|---|---|
| `install-aab-ui.bat` | **Start here.** Opens the window. If it closes with an error, it prints the last log and waits. |
| `install-aab-ui.ps1` | The window (WinForms UI). Runs the installers below and shows their output. |
| `install-aab.ps1` | AAB installer script (bundletool + signing). |
| `install-xapk.ps1` | XAPK installer script (ADB only). |
| `tools/bundletool-all-1.18.3.jar` | Fallback bundletool, used when Unity's copy isn't found. |
| `aab-install-ui.config.json` | Saved window settings *(created automatically, git-ignored)*. |
| `aab-install-last.log` | Log of the last install *(git-ignored)*. |
| `aab-install-crash.log` | UI errors, if any *(git-ignored)*. |
| `aab-install-output/` | Built `.apks` files *(git-ignored)*. |

> ⚠️ **Security:** `aab-install-ui.config.json` stores your keystore **passwords in plain text**. It is listed in `.gitignore`. Never commit or share it. Delete it to clear all saved settings.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Device list is empty | Reconnect the cable, accept the USB debugging prompt on the phone, click **Refresh**. Try another cable or USB port. Run `adb devices` and check the phone shows as `device`, not `unauthorized`. |
| `ADB not found` | Set the **ADB** box to your `adb.exe`, or install Android platform-tools. |
| `Java was not found in PATH` (AAB) | Install a JDK and add its `bin` folder to `PATH`. |
| `bundletool jar not found` (AAB) | Set the **Unity Hub Editor** box correctly, or put a `bundletool*.jar` in `tools/`. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | The phone already has the app signed with a different key. Uninstall it first: `adb uninstall <package>`. |
| `INSTALL_FAILED_VERSION_DOWNGRADE` | The phone has a newer version. Uninstall it first. |
| `INSTALL_FAILED_NO_MATCHING_ABIS` (XAPK) | The XAPK has no native libraries for this phone's CPU (for example, arm64 only on a 32-bit phone). |
| Play Games "not initialized" | See [Signing and Google Play Games](#signing-and-google-play-games). The SHA-1 in the log must be registered in Google Cloud. |
| Installed, but the app didn't open | The package name couldn't be read. Open the app manually; the install itself worked. |
| The window closed by itself | Check `aab-install-crash.log` and `aab-install-last.log`. |

---

## Using it on another PC

1. Copy the whole folder (the `.gitignore`d files are not needed).
2. Install Unity Android Build Support **or** Android platform-tools, plus a JDK for AAB installs.
3. Open `install-aab-ui.bat` and set the **ADB** and **Unity Hub Editor** paths if the defaults don't match. They are saved for next time.

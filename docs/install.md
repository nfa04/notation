# Installing Notation

Notation is free software. Pick your system below; every download is on the
[releases page](https://github.com/nfa04/notation/releases/latest).

## <a id="ios"></a>iPhone and iPad (AltStore)

Apple only lets apps outside the App Store run if they are signed with your own Apple ID. [AltStore](https://altstore.io)
does that signing for you and renews it automatically. You need a Mac or Windows PC for the first setup, a free Apple ID
(a separate one for this is a good idea), and a USB cable.

1. **Install AltServer** on the computer from [altstore.io](https://altstore.io) and keep it running (menu bar on a Mac, tray on Windows). iTunes and iCloud must be the versions from apple.com or the Microsoft Store (Windows).
2. **Turn on Developer Mode** on the iPhone or iPad: *Settings → Privacy & Security → Developer Mode*, then restart. (The switch appears after the first AltStore install.)
3. **Install AltStore on the device**: connect it by cable, trust the computer, choose *AltServer → Install AltStore → your device* and sign in with your Apple ID. On the device open *Settings → General → VPN & Device Management*, tap the Apple ID and *Trust* it.
4. **Add the Notation source**: open AltStore, go to *Sources*, tap **+** and paste

   `https://github.com/nfa04/notation/releases/latest/download/altstore.json`

   (or open this address on the device: `altstore://source?url=https://github.com/nfa04/notation/releases/latest/download/altstore.json`).
5. **Install**: *Browse → Notation → Free*. Updates appear in AltStore when a new version is released.

What to know about the free Apple ID:

* The signature lasts **7 days**. AltStore renews it by itself while the device and the computer running AltServer are on the same Wi-Fi network, so keep AltServer running now and then.
* A free account can have only **3 apps** active at a time (see altstore.io for how AltStore itself is counted) and **10 app IDs per week**.
* Prefer a different tool? Download `Notation-ios-unsigned.ipa` from the releases page and sign it with [Sideloadly](https://sideloadly.io) or Xcode.
* In the European Union, AltStore PAL is an alternative that avoids the 7-day renewal; see altstore.io.

## macOS

1. Download `Notation-macos.dmg`, open it and drag **Notation** onto the *Applications* shortcut in the window. (`Notation-macos.zip` holds the same app, if you prefer an archive.)
2. The app is not notarized by Apple (that needs a paid developer account), so macOS refuses the first start. Allow it once:
   * **macOS 15 (Sequoia) and newer:** double-click Notation, close the message, open *System Settings → Privacy & Security*, scroll down to the line about Notation and click **Open Anyway**, then enter your password.
   * **macOS 14 and older:** right-click Notation → **Open** → **Open**.
   * **Any version, in a terminal:** `xattr -cr /Applications/Notation.app`, then open it normally.
3. After that it starts like any other app. A new version is a new download, so the step is needed again after an update.

## Windows

1. Download `Notation-windows-x64-setup.exe` and run it. Windows SmartScreen may say the app is unrecognised, because it is not signed with a paid certificate: choose **More info → Run anyway**.
2. Click through the installer. It installs for your user only (no administrator password) unless you choose otherwise, adds Notation to the Start menu, and installs the Visual C++ runtime if your PC lacks it. Update by running the newer setup; remove it under *Settings → Apps*.
3. Prefer no installer? `Notation-windows-x64.zip` is the portable version: unzip the whole folder (keep its files together) and run `notation.exe`. It needs the [Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe) if Windows reports a missing `VCRUNTIME140.dll`.

## <a id="linux"></a>Linux

Flatpak: download `Notation-linux-x86_64.flatpak` and run `flatpak install --user Notation-linux-x86_64.flatpak`, then start
Notation from the application menu or with `flatpak run io.github.nfa04.notation`.

## Android

Download the APK for your device and open it (allow "install unknown apps" for your browser or file manager when
asked):

* `Notation-android-arm64.apk`: almost every phone and tablet from the last decade (64-bit ARM). Take this one if unsure.
* `Notation-android-arm32.apk`: older 32-bit ARM devices.
* `Notation-android-x64.apk`: the Android emulator on a PC, Chromebooks and x86 Android devices.
* `Notation-android-universal.apk`: all three in one file (about 260 MB). Works anywhere, but is much bigger; prefer the one for your device.

## Check the download

Each release has a `SHA256SUMS.txt`: `sha256sum -c SHA256SUMS.txt` (Linux), `shasum -a 256 -c SHA256SUMS.txt` (macOS).

# Releasing Notation

What is automated, what is not, and what each store needs. Nothing here publishes by itself except pushing a tag, which
creates a GitHub Release.

## Cutting a version

1. Change `version:` in `pubspec.yaml` (`1.0.1+2`: the part after `+` is the Android `versionCode`; it must grow with every release).
2. Add `fastlane/metadata/android/en-US/changelogs/2.txt` (and `de-DE`): the file is named after the build number. F-Droid and the GitHub Release show it.
3. Add a `<release>` to `linux/io.github.nfa04.notation.metainfo.xml`.
4. Commit, then `git tag v1.0.1 && git push --tags`. `.github/workflows/release.yml` builds Android, iOS (unsigned), macOS, Windows and the Flatpak, and attaches them to a GitHub Release together with `altstore.json` and `SHA256SUMS.txt`. The file names have no version in them, so `releases/latest/download/<name>` links on the website keep working.

## Secrets (repository settings → Secrets and variables → Actions)

Only needed to sign the Android APK of the release with your own key (without them the APK is signed with the debug key and
cannot be updated over a store version). Make a key **once** and keep two copies of it somewhere safe; if it is lost, an app
that is on Google Play or F-Droid-signed-by-you can never be updated:

```
keytool -genkey -v -keystore ~/notation-upload.jks -keyalg RSA -keysize 4096 -validity 10000 -alias upload
base64 -w0 ~/notation-upload.jks      # -> ANDROID_KEYSTORE_BASE64
```

`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`upload`) and `ANDROID_KEY_PASSWORD` are what you typed. For a local
signed build put `storeFile`, `storePassword`, `keyAlias`, `keyPassword` in `android/key.properties` (git-ignored).

## Website downloads

`site/` links to `…/releases/latest/download/Notation-<platform>.<ext>`. `docs/install.md` and `docs/privacy.md` are the sources of
`install.html` and `privacy.html`.

## iOS and iPadOS: AltStore

The release contains `Notation-ios-unsigned.ipa` and `altstore.json` (made by `tool/make_altstore_source.py`). Users add
`https://github.com/nfa04/notation/releases/latest/download/altstore.json` as a source in AltStore; the steps are in `docs/install.md`.
The repository has to be public for these links to work.

## macOS and Windows outside the stores

Both are unsigned, so users see a warning (steps in `docs/install.md`). To remove it:

* **macOS** (needs the Apple Developer Program, US$99/yr): the workflow already signs and notarizes when five secrets exist, and stays unsigned without them (that is the state now). To switch it on:
  1. In developer.apple.com → Certificates, create a **Developer ID Application** certificate (a certificate signing request from Keychain Access), install it, then export it from Keychain Access as a `.p12` with a password.
  2. At appleid.apple.com create an **app-specific password**.
  3. Add the secrets `MACOS_CERTIFICATE_BASE64` (`base64 -i cert.p12`), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` (the 10 characters in the membership page) and `APPLE_APP_SPECIFIC_PASSWORD`.
  4. Tag a release. The log of the step "Sign and notarize the macOS app" ends with `accepted` and `spctl ... accepted source=Notarized Developer ID`. Then remove the Gatekeeper steps from the macOS section of `docs/install.md`.
  This step has not been run yet (no account): expect to fix details on its first run, for instance a library that the signing loop misses or an entitlement the hardened runtime needs.
* **Windows**: the Inno Setup installer (`windows/installer/notation.iss`) is built in CI already. [SignPath Foundation](https://signpath.org/) signs open-source projects for free (an application is needed), or a paid certificate / Azure Trusted Signing. Signing the installer removes the SmartScreen warning.

## Flathub

Flathub builds from source, so it cannot use `linux/flatpak/io.github.nfa04.notation.yml` (that one packs the CI's prebuilt
bundle, for the `.flatpak` on the release page). See `flathub/README.md` for what the source manifest needs.

## F-Droid

`fdroid/io.github.nfa04.notation.yml` is a draft recipe for `fdroiddata`. Reviewers will look at these:

* **Proprietary or prebuilt code.** Done: ML Kit (`mobile_scanner`) was replaced by `qr_code_scanner_plus` (ZXing); the release dependency tree has no Google Play services, ML Kit or Firebase. Still to check with `fdroid scanner`: the native libraries inside the `onnxruntime-android` and WebRTC (`io.github.webrtc-sdk`) AARs (Maven Central, usually accepted), `com.github.davidliu:audioswitch` (JitPack), and **pdfrx**, which downloads PDFium binaries while building.
* **Anti-features.** Reviewers may ask about `NonFreeNet`: the app can sync to Dropbox / OneDrive and use an OpenAI-compatible service, but only if the person adds one, and it downloads models from Hugging Face / GitHub on request. Describe that in the merge request and let them decide the tags.
* **Build.** Try it with `fdroidserver` (`fdroid build -v -l io.github.nfa04.notation` in a checkout of fdroiddata) before opening the merge request.
* The listing text and the changelogs come from `fastlane/metadata/android/`. Screenshots go in `fastlane/metadata/android/en-US/images/phoneScreenshots/` (1.png, 2.png, …).

## Google Play and the App Store (later)

Reuse the same metadata. Play needs an app bundle signed with the upload key (`flutter build appbundle`), the Data safety form
(answers follow `docs/privacy.md`: no data collected by the developer; data you send to a service you chose goes to that service) and the
privacy policy URL. The App Store additionally needs `ios/Runner/PrivacyInfo.xcprivacy` (not yet there: the plugins' use of the
"required reason" APIs has to be audited first), an Apple Developer account and App Store Connect records.

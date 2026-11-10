# Flathub submission (prepared, not submitted)

Flathub builds every app from source in a sandbox **without network access**, so it cannot use the prebuilt bundle of
`linux/flatpak/io.github.nfa04.notation.yml` (that one is only for the `.flatpak` file of the GitHub release). A Flutter app is built
there with [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter): it reads [flatpak-flutter.yml](flatpak-flutter.yml)
and writes the real manifest, with the Flutter SDK and every pub package pinned by hash.

## What is here

`flatpak-flutter.yml` is the **input**. It already contains what the tool cannot know: everything that the plugins download while
building, given as a pinned source and put where the plugin looks for it:

| What | Package (locked version) | Where it goes |
|---|---|---|
| PDFium `chromium/8125` | `pdfium_dart` 0.4.1 (build hook) | `.dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_8125/linux-<arch>/libpdfium.so` |
| SQLite 3.8.0 (`libsqlite3.<arch>.linux.so`) | `sqlite3` 3.8.0 (build hook) | `.dart_tool/hooks_runner/shared/sqlite3/build/download-<first 8 of its hash>/libsqlite3.so` |
| ONNX Runtime 1.28.3 | `flutter_onnxruntime` 1.9.0 (CMake) | `build/linux/<arch>/release/plugins/flutter_onnxruntime/onnxruntime/onnxruntime-linux-<arch>-1.28.3` |
| libwebrtc `m150.7871.07` | `flutter_webrtc` 1.6.3 (CMake) | `<pub cache>/flutter_webrtc-1.6.3/third_party/downloads/` |

**These four are tied to the locked versions.** After a `flutter pub upgrade` of any of those packages, look up the new version
(PDFium: `_pdfiumRelease` in `pdfium_dart/hook/build.dart`; SQLite: `releaseTag` and the hash in `sqlite3/lib/src/hook/asset_hashes.dart`;
ONNX Runtime: the default `ONNXRUNTIME_VERSION` in the plugin's `linux/CMakeLists.txt`; libwebrtc: `third_party/libwebrtc_version.ini`),
and change URL, hash and the folder names in the file. A wrong path does not fail loudly: the plugin tries to download, and the sandbox
build stops with "Failed to download".

## Steps

1. Make the repository public and tag a release (`v0.0.1`); put the commit of the tag in the `notation` source (`commit:`).
2. Screenshots: the metainfo needs `<screenshots>` with image URLs (PNG, 16:9 works best) at the tag.
3. Generate (needs network; `pip install packaging pyyaml tomlkit`, or the Docker image of the project):
   ```
   git clone https://github.com/TheAppgineer/flatpak-flutter && cd flathub
   python3 ../flatpak-flutter/flatpak-flutter.py flatpak-flutter.yml
   ```
   This writes `io.github.nfa04.notation.yml`, `pubspec-sources.json` and `flutter-sdk-*.json`.
4. Build exactly as Flathub does and run it:
   ```
   flatpak-builder --sandbox --user --install --install-deps-from=flathub --force-clean build-dir io.github.nfa04.notation.yml
   flatpak run io.github.nfa04.notation
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest io.github.nfa04.notation.yml
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder appstream linux/io.github.nfa04.notation.metainfo.xml
   ```
5. Pull request against `flathub/flathub` (branch `new-pr`) with the generated files, following
   https://docs.flathub.org/docs/for-app-authors/submission. The ID `io.github.nfa04.notation` matches the GitHub account `nfa04`
   that owns the repository, which is what Flathub verifies. It cannot change after publishing.

## Open questions for the reviewers

* **Prebuilt binaries.** PDFium, SQLite, ONNX Runtime and libwebrtc are upstream release binaries, downloaded by hash. Flathub accepts
  this for Flutter apps when it cannot be avoided (the same as the PDFium of other apps); expect to be asked why, and be ready to say
  that PDFium and libwebrtc have no practical source build for a Flatpak and that every file is pinned by SHA-256.
* **GNOME 50 and clang.** The runtime is `org.gnome.Platform//50`, built on freedesktop 25.08, so the clang extension is `llvm20`
  of that branch. If Flutter 3.47 wants a newer clang, change `llvm20` (also in `append-path` and `prepend-ld-library-path`) to `llvm21` or `llvm22`.
* **Not built yet** (see the status at the end of this file).

# Contributing to Notation

Thanks for helping. Notation is an early beta (0.0.x), so bug reports with clear steps to reproduce them are as welcome as code.

## Reporting a bug or asking for a feature

Open an issue at https://github.com/nfa04/notation/issues. For a bug, say:

* the platform and version (Android 15, Windows 11, the web version in Firefox, ...) and the app's version;
* what you did, what you expected, and what happened instead;
* if you can, a small note or PDF that shows it (remove anything private first).

**Security problems are different:** do not open a public issue; see [SECURITY.md](SECURITY.md).

## Setting up

You need Flutter **3.47.7** (stable; the version CI uses, in `.github/workflows/ci.yml`). On Linux, the native plugins also need:

    sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev liblzma-dev

Then:

    flutter pub get
    (cd pdf_overlay && dart pub get)     # a package of its own
    flutter run                          # on the device or desktop of your choice

## Checking your change

CI runs the same steps on every pull request; please run them first.

    flutter analyze                      # must report no issues at all (infos count too)
    flutter build linux --debug          # once: the tests load PDFium, SQLite, ONNX Runtime and QuickJS from this build
    LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test
    (cd pdf_overlay && dart test)

The full suite has about 3 700 tests and takes a few minutes. While working, run only the files you touch
(`flutter test test/some_test.dart`). Every `flutter test` process needs one to three gigabytes of memory, so do not run many at once.

Some tests measure time; under heavy load one of them can fail once. Run it again on its own before you suspect your change.

## How the code is written

* **Do not run `dart format`** on existing files. The project uses long lines (up to about 150 characters) and its own layout;
  a format run rewrites hundreds of files and buries the real change. Match the style of the file you edit.
* **Every text the user sees needs a German translation.** Wrap it in `tr(...)` (or use the `Text` of `lib/l10n/text.dart`) and add
  the English text with its German translation to `lib/l10n/german.dart`; `test/german_coverage_test.dart` fails otherwise.
* **Add a test** for a fix or a feature. Widget tests are in `test/`, next to the existing tests of the same area.
* **Keep data on the device.** A feature that sends anything over the network must be something the person switches on, and must be
  described in `docs/privacy.md`. Models run on the device; new models must have a licence that allows redistribution, and the licence
  is named where the person turns the model on.
* **New bundled files with a licence of their own** (fonts, native libraries, vocabularies) get their licence text in `assets/licenses/`
  and a line in `lib/legal/bundled_licenses.dart`, so it shows on the licences page.
* Comments explain *why*, in full sentences. Look at the code around yours.

## Pull requests

* One topic per pull request; describe what changed and how you checked it.
* Screenshots help for anything visible.
* By opening a pull request you agree that your contribution is licensed under the project's licence, the
  [GNU AGPL v3.0 or later](LICENSE).

## Extensions

You can add features without changing the app: see [docs/extensions.md](docs/extensions.md).

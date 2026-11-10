#!/bin/sh
# Makes the sqlite3 package compile SQLite from the given source file instead of downloading the prebuilt library of its GitHub release.
# For the builds of F-Droid and Flathub, which must build everything from source (see fdroid/ and flathub/). The compile options are
# the package's default ones, so the library is the same as the prebuilt one. Run it in the root of the project before `flutter build`:
#   tool/use_sqlite_source.sh third_party/sqlite3/sqlite3.c
# where sqlite3.c is the amalgamation of the SQLite version that the sqlite3 package expects (https://sqlite.org/download.html;
# sqlite3 3.8.0 -> SQLite 3.54.0, sqlite-amalgamation-3540000.zip).
set -eu
src="${1:?usage: use_sqlite_source.sh path/to/sqlite3.c}"
[ -f "$src" ] || { echo "$src does not exist" >&2; exit 1; }
grep -q '^hooks:' pubspec.yaml && { echo "pubspec.yaml has a hooks: section already" >&2; exit 1; }
cat >> pubspec.yaml <<YAML

hooks:
  user_defines:
    sqlite3:
      source: source
      path: $src
YAML

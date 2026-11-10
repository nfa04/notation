#!/bin/sh
# Makes notation:// links (live-session invitations) open in Notation on this Linux desktop.
#
#   tool/install_linux_link_handler.sh [path/to/the/notes/executable]
#
# Without an argument it uses the release build (flutter build linux). While you develop, build once with
# `flutter build linux --debug` and pass build/linux/x64/debug/bundle/notation: a link then starts that
# build, which hands it on to the copy you started with `flutter run` if one is running.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
exe="${1:-$root/build/linux/x64/release/bundle/notation}"
if [ ! -x "$exe" ]; then
  echo "Not found: $exe (build it first: flutter build linux)" >&2
  exit 1
fi
exe="$(cd "$(dirname "$exe")" && pwd)/$(basename "$exe")"
dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$dir" "${XDG_CONFIG_HOME:-$HOME/.config}"
sed "s|@EXEC@|$exe|" "$root/linux/notation.desktop.in" > "$dir/notation.desktop"
echo "Icon=$root/linux/icons/256.png" >> "$dir/notation.desktop"
update-desktop-database "$dir" 2>/dev/null || true
xdg-mime default notation.desktop x-scheme-handler/notation
echo "Registered $dir/notation.desktop -> $exe"
echo "Try: xdg-open 'notation://join?s=wss://example.org#AAAA'"

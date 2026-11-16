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
# The file is named after the application id (my_application.cc sets it as the program name): on Wayland GNOME
# finds a window's icon and name only through the desktop entry of that name, so any other name shows a gear.
id=io.github.nfa04.notation
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
mkdir -p "$icons/256x256/apps" "$icons/scalable/apps"
cp "$root/linux/icons/256.png" "$icons/256x256/apps/$id.png"
cp "$root/linux/icons/$id.svg" "$icons/scalable/apps/$id.svg"
gtk-update-icon-cache -q -t "$icons" 2>/dev/null || true
rm -f "$dir/notation.desktop"
sed "s|@EXEC@|$exe|" "$root/linux/notation.desktop.in" > "$dir/$id.desktop"
echo "Icon=$id" >> "$dir/$id.desktop"
echo "StartupWMClass=$id" >> "$dir/$id.desktop"
update-desktop-database "$dir" 2>/dev/null || true
xdg-mime default "$id.desktop" x-scheme-handler/notation
echo "Registered $dir/$id.desktop -> $exe"
echo "Try: xdg-open 'notation://join?s=wss://example.org#AAAA'"

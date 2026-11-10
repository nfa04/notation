#!/usr/bin/env python3
"""Generates every logo file of Notation from one drawing.

    python3 branding/make_icons.py

The logo is a pen that writes its own N: the left stem and the diagonal are the
ink, the right stem is the pen, its tip (amber, the colour of a highlighter) is
where the diagonal ends.  The geometry below is the single source; it is
repeated, on purpose and with the same numbers, in lib/widgets/notation_logo.dart
(which draws it in the app's accent colour).  Change one, change the other.

Needs ImageMagick (`magick`, with its RSVG delegate) only to turn SVG into PNG/ICO.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRAND = ROOT / 'branding'

BLUE_TOP, BLUE_BOTTOM = '#5b9bff', '#2f6fe0'   # centre is the default accent 0xFF4285F4
AMBER = '#ffd54a'
BAND = '#c7d9fb'
WHITE = '#ffffff'

# glyph in a 1024 box, before the placement transform
GLYPH_CENTRE = (495, 500)


def glyph(fill=WHITE, tip=AMBER, band=BAND, mono=False):
    """The N / pen.  mono: one colour only (the tip is cut off from the body by a thin gap)."""
    parts = []
    mask = ''
    if mono:
        mask = ('<mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
                '<rect width="1024" height="1024" fill="#fff"/>'
                '<path d="M628 614Q690 646 752 614" fill="none" stroke="#000" stroke-width="24"/></mask>')
    parts.append(f'<path d="M300 760V280L690 590" fill="none" stroke="{fill}" stroke-width="100" stroke-linecap="round" stroke-linejoin="round"/>')
    parts.append(f'<path d="M640 240a50 50 0 0 1 100 0V600L690 810L640 600z" fill="{fill}"/>')
    if mono:
        parts = [f'<g mask="url(#m)">{"".join(parts)}</g>']
    else:
        parts.append(f'<path d="M640 300H740V340H640z" fill="{band}"/>')
        parts.append(f'<path d="M640 600L690 810L740 600Q690 625 640 600z" fill="{tip}"/>')
    return mask + ''.join(parts)


def place(scale, dx=0, dy=0):
    cx, cy = GLYPH_CENTRE
    return f'translate({512 + dx} {512 + dy}) scale({scale}) translate({-cx} {-cy})'


GRADIENT = (f'<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{BLUE_TOP}"/>'
            f'<stop offset="1" stop-color="{BLUE_BOTTOM}"/></linearGradient></defs>')


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{body}</svg>\n'


def tile(scale=1.12):
    """Rounded tile: Linux, Windows, web, store listing, README, site."""
    return svg(f'{GRADIENT}<rect width="1024" height="1024" rx="230" fill="url(#g)"/><g transform="{place(scale)}">{glyph()}</g>')


def square(scale=1.12):
    """Full bleed: iOS (the system rounds it) and anything that crops itself (maskable)."""
    return svg(f'{GRADIENT}<rect width="1024" height="1024" fill="url(#g)"/><g transform="{place(scale)}">{glyph()}</g>')


def macos():
    """macOS draws no mask of its own: shape, margin and shadow are part of the picture."""
    shadow = ('<filter id="s" x="-20%" y="-20%" width="140%" height="150%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/>'
              '<feOffset dy="12"/><feComponentTransfer><feFuncA type="linear" slope=".30"/></feComponentTransfer>'
              '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
    k = 824 / 1024
    return svg(f'{GRADIENT}<defs>{shadow}</defs><g filter="url(#s)" transform="translate(100 100) scale({k})">'
               f'<rect width="1024" height="1024" rx="230" fill="url(#g)"/><g transform="{place(1.12)}">{glyph()}</g></g>')


def android_foreground(mono=False):
    """Adaptive icon layer: only the middle 61 % (626 of 1024) is always visible."""
    return svg(f'<g transform="{place(0.74)}">{glyph(mono=mono)}</g>')


def mark(color=WHITE):
    """Glyph alone, one colour, for places that bring their own background."""
    return svg(f'<g transform="{place(1.0)}">{glyph(fill=color, mono=True)}</g>')


def run(*args):
    subprocess.run(args, check=True)


def png(svg_path, out, size, flatten=None):
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = ['magick', '-background', 'none', '-density', str(72 * size / 1024 * 4), str(svg_path), '-resize', f'{size}x{size}']
    if flatten:
        cmd += ['-background', flatten, '-alpha', 'remove', '-alpha', 'off']
    run(*cmd, str(out))


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def main():
    tmp = BRAND / '.build'
    tmp.mkdir(exist_ok=True)

    # masters (kept in the repository)
    write(BRAND / 'logo.svg', tile())
    write(BRAND / 'logo-square.svg', square())
    write(BRAND / 'logo-mark.svg', mark())
    write(BRAND / 'logo-macos.svg', macos())

    write(tmp / 'tile.svg', tile())
    write(tmp / 'square.svg', square())
    write(tmp / 'macos.svg', macos())
    write(tmp / 'fg.svg', android_foreground())
    write(tmp / 'fg_mono.svg', android_foreground(mono=True))
    write(tmp / 'maskable.svg', square(0.9))

    # Android: adaptive (API 26+), themed (13+), legacy square for older
    res = ROOT / 'android/app/src/main/res'
    for density, px in {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}.items():
        png(tmp / 'fg.svg', res / f'mipmap-{density}/ic_launcher_foreground.png', px)
        png(tmp / 'fg_mono.svg', res / f'mipmap-{density}/ic_launcher_monochrome.png', px)
    for density, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        png(tmp / 'tile.svg', res / f'mipmap-{density}/ic_launcher.png', px)
    # the small icon of a notification is drawn as a silhouette: the glyph alone, white
    write(tmp / 'stat.svg', svg(f'<g transform="{place(1.45)}">{glyph(mono=True)}</g>'))
    for density, px in {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96}.items():
        png(tmp / 'stat.svg', res / f'drawable-{density}/ic_stat_notation.png', px)
    write(res / 'mipmap-anydpi-v26/ic_launcher.xml',
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
          '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
          '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
          '</adaptive-icon>\n')
    write(res / 'drawable/ic_launcher_background.xml',
          '<?xml version="1.0" encoding="utf-8"?>\n'
          '<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">\n'
          f'    <gradient android:angle="270" android:startColor="{BLUE_TOP}" android:endColor="{BLUE_BOTTOM}"/>\n'
          '</shape>\n')

    # iOS (no transparency allowed) and its launch image
    ios = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    for f in sorted(ios.glob('Icon-App-*.png')):
        w = int(subprocess.check_output(['magick', 'identify', '-format', '%w', str(f)]))
        png(tmp / 'square.svg', f, w, flatten=BLUE_BOTTOM)
    launch = ROOT / 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
    for name, k in (('LaunchImage.png', 1), ('LaunchImage@2x.png', 2), ('LaunchImage@3x.png', 3)):
        png(tmp / 'tile.svg', launch / name, 120 * k)

    # macOS
    mac = ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
    for f in sorted(mac.glob('app_icon_*.png')):
        png(tmp / 'macos.svg', f, int(f.stem.split('_')[-1]))

    # Windows
    sizes = [16, 24, 32, 48, 64, 128, 256]
    for s in sizes:
        png(tmp / 'tile.svg', tmp / f'ico{s}.png', s)
    run('magick', *[str(tmp / f'ico{s}.png') for s in sizes], str(ROOT / 'windows/runner/resources/app_icon.ico'))

    # Linux (the Flatpak installs these; the scalable one is what desktops prefer)
    write(ROOT / 'linux/icons/io.github.nfa04.notation.svg', tile())
    for s in (64, 128, 256, 512):
        png(tmp / 'tile.svg', ROOT / f'linux/icons/{s}.png', s)

    # web
    web = ROOT / 'web'
    png(tmp / 'tile.svg', web / 'favicon.png', 48)
    write(web / 'favicon.svg', tile())
    png(tmp / 'tile.svg', web / 'icons/Icon-192.png', 192)
    png(tmp / 'tile.svg', web / 'icons/Icon-512.png', 512)
    png(tmp / 'maskable.svg', web / 'icons/Icon-maskable-192.png', 192, flatten=BLUE_BOTTOM)
    png(tmp / 'maskable.svg', web / 'icons/Icon-maskable-512.png', 512, flatten=BLUE_BOTTOM)

    # store listing (Play, F-Droid) and the README
    png(tmp / 'tile.svg', ROOT / 'fastlane/metadata/android/en-US/images/icon.png', 512)
    png(tmp / 'tile.svg', BRAND / 'logo-512.png', 512)

    # the website lives next to the app
    site = ROOT.parent / 'site'
    if site.is_dir():
        write(site / 'favicon.svg', tile())
        png(tmp / 'tile.svg', site / 'apple-touch-icon.png', 180)

    for f in tmp.iterdir():
        f.unlink()
    tmp.rmdir()
    print('done')


if __name__ == '__main__':
    sys.exit(main())

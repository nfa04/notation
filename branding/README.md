# Notation logo

A pen that writes its own **N**: the left stem and the diagonal are the ink, the right stem is the pen, and its amber tip is
where the diagonal ends.

| | |
|---|---|
| Blue | `#4285f4` (the default accent of the app), shaded `#5b9bff` above to `#2f6fe0` below |
| Amber | `#ffd54a` (the highlighter; the tip of the pen) |
| Shape | rounded tile (corner radius 22.5 %), the N centred and 12 % larger than the drawing box |

## One drawing, many files

`make_icons.py` holds the drawing and writes every file that shows it. Run it after changing the design, never edit a
generated PNG by hand:

```
python3 branding/make_icons.py        # needs ImageMagick (magick, with RSVG)
```

| Where | Files |
|---|---|
| Masters (kept here) | `logo.svg` (tile), `logo-square.svg` (full bleed), `logo-mark.svg` (glyph only), `logo-macos.svg`, `logo-512.png` (README) |
| Android | adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml`: gradient background, foreground, themed monochrome), legacy `ic_launcher.png`, status-bar silhouette `drawable-*/ic_stat_notation.png` |
| iOS | `AppIcon.appiconset` (full bleed, no transparency) and the launch image |
| macOS | `AppIcon.appiconset` (shape, margin and shadow are part of the picture) |
| Windows | `windows/runner/resources/app_icon.ico` (16 to 256 px) |
| Linux | `linux/icons/` (scalable SVG and PNGs for the Flatpak, `data/notation.png` for the window of a bundle) |
| Web | `web/favicon.svg`, `favicon.png`, `icons/` (plain and maskable) |
| Store listing | `fastlane/metadata/android/en-US/images/icon.png` |
| Website | `../site/favicon.svg`, `apple-touch-icon.png` (the header mark in the pages is pasted from `logo.svg`) |

## In the app

`lib/widgets/notation_logo.dart` draws the same picture with the same numbers, tinted with the accent colour the person chose
(the default accent gives exactly the icon). It is used on the first screen, in the navigation rail and in the About page. The
geometry is repeated on purpose: if you change one, change the other (`test/notation_logo_test.dart` looks at a few points).

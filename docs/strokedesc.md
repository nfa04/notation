# Designed brushes and the `.strokedesc` file

What a person sees: the brush button in the drawing bar has *Design a brush...* at the end of its menu. The designer shows a live line, a kind of brush (ink, roller, soft, charcoal, stamp, mix), a slider for every number of that kind, and buttons to import and export a `.strokedesc` file, to copy a brush as one line of text and paste one, and to save a changed brush as a copy. *Save and use* puts the brush in the menu and draws with it from the next line on.

Code: `lib/models/brush_desc.dart` (the numbers, the id, the file, `CustomBrushes`), `lib/data/brush_library.dart` (what is kept), `lib/screens/brush_designer.dart` (the dialog), the note-file part in `lib/data/note_file.dart`. Tests: `test/brush_desc_test.dart`, `test/brush_designer_ui_test.dart`, and `test/brush_look_frozen_test.dart`, which holds the brushes that come with the app to exactly the look they always had.

## The file

A `.strokedesc` is one brush as JSON:

```json
{
  "format": "strokedesc",
  "version": 1,
  "name": "Dry wall",
  "kind": "roller",
  "params": { "width": 5, "coat": 0.5, "streaks": 1, "ridge": 0.35, "dryness": 0.6 }
}
```

* `kind` is `ink`, `roller`, `soft`, `charcoal`, `stamp` or `mix` (a mix also has `parts`, below). A reader must ignore fields it does not know; a change that breaks readers raises `version`, and a file of a newer version is turned away with a message, not half read.
* A number that is left out is the standard of its kind; a number outside its range is brought into it; a value that is not a number is an error. Numbers are kept to thousandths.
* At most 16 KiB. The id is **not** in the file; it is made of the rest.
* A `mix` has `"parts": [ {...}, {...} ]`: two complete brush objects (as above, a mix cannot be a part; a reader refuses a part that says `"kind": "mix"` before it reads further, so a file cannot nest brushes deeper). The id of a mix is made of its numbers and the **ids** of its parts, not their names.

| kind | numbers (range, standard) |
|---|---|
| `ink` (`ParamBrush`) | `width` 0.2-10 (1), `pressure` 0-1 (0), `smoothing` 0-1 (0.5), `taper` 0-1 (0), `opacity` 0.05-1 (1), `jitter` 0-1 (0), `nibAngle` 0-179 (left out: a round tip), `nibFlatness` 0.05-1 (0.15). *Advanced:* `pressureCurve` 0.3-3 (1), `speedThin` 0-1 (0), `startTaper` / `endTaper` 0-1 (left out: `taper` does both), `waver` 0-1 (0), `lightness` 0-1 (0), `hue` 0-60 (0), `blend` 0/1 (0), and the third batch (see *Dashes, effects, colour along the line, curves*) |
| `roller` (`RollerBrush`) | `width` 1-12 (5), `coat` 0.1-1 (0.5), `streaks` 0-1.5 (1), `ridge` 0-1 (0.35), `dryness` 0-0.8 (0.3). *Advanced:* `streakLength` 0.3-3 (1), `laneWidth` 0.4-3 (1), `ridgeWidth` 0.02-0.4 (0.14), `blend` 0/1 |
| `soft` (`SoftBrush`) | `width` 0.5-12 (6), `strength` 0.1-1 (1), `softness` 0-1 (0.6), `speckle` 0-10 (0), `wobble` 0-1 (0). *Advanced:* `speckleSize` 0.3-3 (1), `speckleSpread` 0.3-3 (1), `blur` 0-2 (1) |
| `charcoal` (`CharcoalBrush`) | `width` 0.5-10 (3), `pressure` 0-1 (0.7), `taper` 0-1 (0.35), `jitter` 0-1 (0.12), `body` 0-0.6 (0.1), `dryness` 0-0.8 (0.3), `dust` 0-3 (1). *Advanced:* `grainSize` 0.4-3 (1), `runLength` 0.3-3 (1), `dustSpread` 0.3-3 (1), `dustSize` 0.3-3 (1) |
| `stamp` (`StampBrush`) | `width` 0.5-12 (4), `spacing` 0.05-3 (0.35), `shape` 0-4 round/square/triangle/star/leaf (0), `scatter` 0-2 (0), `sizeJitter` 0-1 (0.2), `opacity` 0.05-1 (1). *Advanced:* `pressure` 0-1 (0.5), `squash` 0.1-1 (1), `angle` 0-179 (0), `angleJitter` 0-1 (0), `follow` 0/1 (0: dab keeps its angle, 1: turns with the line), `lightness`, `hue`, `blend` as for ink, and the effects and the colour along the line (not dashes) |
| `mix` (`MixBrush`) | `sizeB` 0.2-4 (1: how thick the second brush is compared to what it makes on its own), `underneath` 0/1 (0: the second is drawn over the first); and two `parts` |

`width` is how many times thicker than the width chosen in the bar the line is made (the brush's `widthScale`). The knobs are one table (`BrushDesc.knobsOf`); the designer's sliders, the range checks and the standards all come from it. The standards of `roller` and `charcoal` are the roller and the charcoal of the app, and the four ink presets in `BrushDesc.starting` draw exactly like the pencil, fountain pen, calligraphy nib and marker (`brush_desc_test.dart` compares their geometry). The soft ones are close to the airbrush and the wash, not the same: those two are drawn from tables of layers, a soft design from the numbers (a bell curve of layers, blurred on the screen in proportion to `softness`).

## The id: why a line always means the look it was drawn with

A line keeps only its brush's id (`strokes.brush`, the note file, the live-session replica). For a designed brush the id is `custom:` and 16 hex digits made of the **kind and the numbers** (not the name). So:

* The same design is the same id on every device, and two people who make the same brush share it.
* Changing a number makes **another id**. Lines drawn with the old brush keep the old look; the designer saves the changed brush as a new one and takes the old one out of the menu (not out of the library).
* Renaming changes nothing for the lines.
* **A number added later does not change old ids.** A `BrushKnob` is *sparse* when it was added after the first version (every new number is): the id text leaves it out while it is at its standard, so a brush made before the number existed has the id it always had. The numbers of the first version are in the id always (`brush_desc_test.dart` pins ids of both kinds).
* The hash is made with sums and remainders only (no bit operations, no 64-bit multiplication), so that it is the same in a browser. `brush_desc_test.dart` holds one id fixed: if it ever changes, every note drawn with a designed brush loses its look.

## What is kept on a device (`BrushLibrary`)

One setting for each brush, `brush:<id>`, holding the `.strokedesc` JSON and `"listed": true/false`. `syncedSetting` lets the `brush:` settings travel with the profile (see profile-sync.md), and `SyncLibrary.applySetting` reloads the library when one arrives. At start-up `BrushLibrary.load` reads them and makes them the designed brushes there are (`CustomBrushes.sync` -> `Brushes.sync('custom:', ...)`); a brush whose description did not change is the same object, so nothing is drawn again.

*Listed* means in the brush menu. Every brush ever kept stays in the library, because notes are drawn with it: *Remove from the menu* only unlists it; *Delete* (after a question) takes it out for good. A deletion is kept as a setting `brush:<id>` = `{"removed": true}` (not a missing setting, which the next synced device would give back), so it travels with the profile; it does not count for the 500. Lines in notes drawn with a deleted brush are drawn as the pen until a note file or a live session with the brush brings it back (`adopt`, `keep`). A brush that comes from a note is kept **unlisted** until the person adds it (a note from someone else cannot fill the menu); the designer shows those under *Brushes that came with notes*. A library holds at most 500 brushes.

## In a `.uninote` file

The note file is a ZIP (see the comment at the top of `note_file.dart`). `noteFileEntries` adds `brushes/<hex>.strokedesc` for every designed brush that the note's lines use and this device knows (`designedBrushesUsedBy`); the name is the id without `custom:`. Brushes the lines do not use are not taken along. `decodeNoteFile` reads every `brushes/*.strokedesc` into `ParsedNoteFile.brushes`: one that is damaged, too big or of a newer version is left out with a warning and the note opens; at most 200 are read. `NoteFileService` hands them to `BrushLibrary.adopt` when a note is opened from a file or arrives by sync, so the lines look as they were made to.

Because the entry is derived from the note's own lines, a note on a device that lacks the brush gets it back on the next save: the files of two devices converge after one sync.

## In a live session

A line is sent as a change with its data (`replica.dart`, `_strokeData`); for a designed brush the data has `bd` next to `b` (the id): the brush as `{"k": kind, "n": name, "p": {numbers}}` (`BrushDesc.toCompactJson`). The lines of a guest who joins later carry it too, since what a joiner is given is the same data. About 100-200 bytes a line, and nothing for the pen and the brushes of the app.

A device that takes in a line (`Replica._learnBrush`) reads the numbers, checks that they make the id the line names (the id is made of the numbers, so a line cannot bring a brush under the id of another one, and a line cannot change a brush a device has), and, if it does not have the brush, `CustomBrushes.learn`s it: it is a brush of the app **at once** (so the line is drawn right when it arrives, whatever the order of the changes), out of the menu, and `CustomBrushes.keeper` (`BrushLibrary.keep`, set in `main.dart`) writes it into the library so that the lines still look right after a restart. Something that is not a brush, or whose numbers do not make the id, is ignored and the line is drawn as the pen; a device with 500 brushes takes no more. Older versions ignore `bd`.

## Where else a note comes from

Every way a note file is opened goes through `NoteFileService._materialise` (open a file, a template, a shared copy, a note from another device, unlocking a locked note), which keeps the brushes **before** it saves the note (saving tells the dashboard to make the note's picture, which must not be made with the pen). The two ways in that do not: a live session (the line carries its brush, above) and an update of an opened copy (`CollabService._takeOwnerCopy` keeps the owner's brushes before it works out what changed, because the changes it makes carry a brush with their lines only if this device knows it).

Checked, not changed: PDF export (`test/pdf_brush_test.dart` compares a designed brush of every kind, with its numbers at the ends, with the screen); the id arithmetic gives the same ids compiled to JavaScript as natively (2000 random designs); stamps are kept on the device and need nothing; handwriting recognition leaves out the brushes that paint (`Brushes.writes`); the assistant and the MCP server do not choose brushes.

## What is not done

* **Tilt** of a stylus does nothing: the app keeps one pressure for each point of a line and no tilt, so a brush that followed the tilt would need a new stream of numbers in every line (note file, sync, live session, undo). The pressure and the speed of the hand can be drawn as curves instead.
* The brush number *Steady hand* (`stabilise`) averages the points of a line when it is drawn on the page, not while the pen moves; the app's own line stabiliser (`lib/models/stabilizer.dart`, a rope behind the pen) works on the input as the pen moves and is a setting of its own, for every brush.
* Soft, charcoal and roller have no effects, no colour along the line and no curves (they are drawn through pictures and tables of layers); they can be one part of a mix.
* **Brushes of extensions** (`ext:<extension>/<brush>`) are not embedded. The editor says so (a snack bar, once for each extension) when a note has lines of one the device does not have - on opening the note and when such lines arrive in a live session; the lines are drawn as the pen.
* Note history (`NoteHistory`) writes the brushes into its versions, but the history viewer does not register brushes it reads; a brush that was deleted from the library on purpose is not restored by looking at an old version.
* Extension brushes (`ext:...`) are not embedded.
* A charcoal brush is not smaller in a PDF than before (see pdf-brush-export in the architecture notes).
* **Deleting is not undoable and does not look at notes**: the question says that lines drawn with the brush become the pen; the app does not count the notes that use it. At 500 live brushes no more come in from notes and sessions.
* A version of the app from before this one opens a note with designed brushes and draws those lines as the pen.

## Advanced numbers, colour, blend

The designer shows the usual numbers of a kind and, under *Advanced*, the rest (`BrushKnob.advanced`); a brush that uses an advanced number opens that part when it is chosen. Every slider has a field beside it to type the number in (out of range is brought into range); choices (shape, blend) are named and move in whole steps.

Colour: `BrushLayer` has `lightness` and `hue` (a tint of the line's colour, `tintedColor`), and `BrushShape.multiply` says the line darkens what it lies on. Ink and stamps cut the line (or the dabs) into pieces and draw each of five colours near the line's own as a layer; the screen (`canvas_painters.dart`), the PDF (`pdf_brush.dart`: fill colour per layer, `/BM /Multiply`) and the designer's preview all read the same fields. Soft and charcoal do not vary colour (they are drawn through a cache of pictures). *Multiply* darkens against the other ink of the same page layer and against the page in a PDF; the screen draws ink in its own layer, so on a coloured paper it is not multiplied with the paper itself.

## Dashes, effects, colour along the line, curves, a steady hand (third batch)

All of these are sparse numbers (left out of the id at their standard), so no earlier brush changed; `lookOf` in the frozen test writes `under`/`next`/`vivid` only when a shape has them.

**Dashes** (`ink`): `dash` (0 = solid; otherwise the length a dash *looks*, in widths of the line, round ends included; up to 1 it is a dot) and `dashGap`. The line is cut at exact places along its length (`ParamBrush._dashRuns`: points and thickness are interpolated at the cuts), at most 3000 dashes on a line.

**Behind the line** (`ink` and `stamp`; `LineEffects`, `behindLayers` in `brush.dart`): `shadow` (opacity), `shadowDistance` (to the lower right, in widths), `shadowBlur` (rings), `glow` (reach in widths; three rings, the widest first) with `glowHue`, `outline` (thickness of a border) with `outlineTone` (darker / lighter / opposite hue). They are `BrushShape.under`: layers drawn **before** the shape, each a copy of the shape made thicker and/or moved, with its own opacity and tint. The screen (`paintBrushShape`, used when a shape has `under` or `next`), the PDF (`pdf_brush.dart`) and the preview draw them in the same order. A found-by-test trap: in the PDF a ribbon of one thickness is *stroked*, so a tinted layer needs its stroke colour set as well as its fill colour.

**Colour along the line** (`ColourFlow`): `gradientHue` / `gradientLight` (the change from the start to the end of the line; eight steps), `rainbow` (length of one turn round the colour wheel in widths; twelve hues), `fade` (positive: see-through towards the end; negative: comes out of nothing), and for ink `pressureShade` / `speedShade` (lighter or darker where the pen pressed hard or moved fast). Every number is a change from the colour the person picked, so a brush never chooses the colour. The line is cut into pieces about as long as it is thick; each piece gets a (lightness, hue, opacity) and the pieces with the same one are one layer. A line is drawn in **at most 40 layers**: with more distinct colours the nearest are put together (`ParamBrush._fewShades`; opacity is kept finer than colour). Pieces of different colours are cut straight across with the corner between them filled (`_cutRibbon`), so one colour never lies over the next. A hue turn on a black or grey pen has nothing to turn, so such layers are `vivid` (`tintedColor` first gives a colourless pen a saturation and a middle lightness): a rainbow works on a black pen.

**Curves** (`ink`): `pressureAt0/25/50/75/100` and `speedAt0/25/50/75/100` are optional numbers (0.1-2: the thickness compared to the width that is set at five evenly spaced inputs; linear between). They are all there or none is (a missing one reads as 1). With the pressure curve on, `pressure` and `pressureCurve` do nothing; with the speed curve on, `speedThin` does nothing. The speed input is the speed of the hand against the usual speed of the line, 0 to twice. The designer draws them as a curve you drag (vertical drags only: a free drag would lose to the scrolling of the dialog); turning a curve on starts it from the response the old numbers gave. `stabilise` averages each point with up to six neighbours on both sides (the ends stay).

**Mixes** (`MixBrush`): two designed brushes on the same line. The first sets the width in the bar; the second draws a line of its own (`BrushShape.line`: same points and pressures, a thickness of `stroke.width * b.widthScale / a.widthScale * sizeB`) and is `BrushShape.next`, drawn over the first or (`underneath`) under it. Painters recurse through `next`; the soft-brush cache is keyed by the line, so the second part's own line object is kept in the shape. A mix travels in a note file and in a live session with its parts inside (`parts` / compact `parts`); the parts are not registered as brushes of their own.

**Sharing as text**: `BrushDesc.toCode()` is `notation-brush:` and the URL-safe base64 of the compact JSON (about a thousand characters); `fromCode` also takes the text of a `.strokedesc`, ignores whitespace and line breaks, and refuses anything else with a reason. The designer's *Copy as text* / *Paste from text* use the clipboard; *Save as a copy* keeps the brush it was made from in the menu (saving and using it unlists that one).

Tests: `brush_desc_test.dart` (group *dashes, what is behind a line, colour along it, curves...*), `brush_paint_test.dart` (pixels: shadow and mix through `paintStrokes`), `pdf_brush_test.dart` (every new design against PDFium), `brush_designer_ui_test.dart` (curve drag, dependent sliders, mix, copy/paste, copy), `collab/brush_live_test.dart` (a mix over a session).

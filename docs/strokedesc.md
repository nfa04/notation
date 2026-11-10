# Designed brushes and the `.strokedesc` file

What a person sees: the brush button in the drawing bar has *Design a brush...* at the end of its menu. The designer shows a live line, a kind of brush (ink, roller, soft, charcoal, stamp), a slider for every number of that kind, and buttons to import and export a `.strokedesc` file. *Save and use* puts the brush in the menu and draws with it from the next line on.

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

* `kind` is `ink`, `roller`, `soft`, `charcoal` or `stamp`. A reader must ignore fields it does not know; a change that breaks readers raises `version`, and a file of a newer version is turned away with a message, not half read.
* A number that is left out is the standard of its kind; a number outside its range is brought into it; a value that is not a number is an error. Numbers are kept to thousandths.
* At most 16 KiB. The id is **not** in the file; it is made of the rest.

| kind | numbers (range, standard) |
|---|---|
| `ink` (`ParamBrush`) | `width` 0.2-10 (1), `pressure` 0-1 (0), `smoothing` 0-1 (0.5), `taper` 0-1 (0), `opacity` 0.05-1 (1), `jitter` 0-1 (0), `nibAngle` 0-179 (left out: a round tip), `nibFlatness` 0.05-1 (0.15). *Advanced:* `pressureCurve` 0.3-3 (1), `speedThin` 0-1 (0), `startTaper` / `endTaper` 0-1 (left out: `taper` does both), `waver` 0-1 (0), `lightness` 0-1 (0), `hue` 0-60 (0), `blend` 0/1 (0) |
| `roller` (`RollerBrush`) | `width` 1-12 (5), `coat` 0.1-1 (0.5), `streaks` 0-1.5 (1), `ridge` 0-1 (0.35), `dryness` 0-0.8 (0.3). *Advanced:* `streakLength` 0.3-3 (1), `laneWidth` 0.4-3 (1), `ridgeWidth` 0.02-0.4 (0.14), `blend` 0/1 |
| `soft` (`SoftBrush`) | `width` 0.5-12 (6), `strength` 0.1-1 (1), `softness` 0-1 (0.6), `speckle` 0-10 (0), `wobble` 0-1 (0). *Advanced:* `speckleSize` 0.3-3 (1), `speckleSpread` 0.3-3 (1), `blur` 0-2 (1) |
| `charcoal` (`CharcoalBrush`) | `width` 0.5-10 (3), `pressure` 0-1 (0.7), `taper` 0-1 (0.35), `jitter` 0-1 (0.12), `body` 0-0.6 (0.1), `dryness` 0-0.8 (0.3), `dust` 0-3 (1). *Advanced:* `grainSize` 0.4-3 (1), `runLength` 0.3-3 (1), `dustSpread` 0.3-3 (1), `dustSize` 0.3-3 (1) |
| `stamp` (`StampBrush`) | `width` 0.5-12 (4), `spacing` 0.05-3 (0.35), `shape` 0-4 round/square/triangle/star/leaf (0), `scatter` 0-2 (0), `sizeJitter` 0-1 (0.2), `opacity` 0.05-1 (1). *Advanced:* `pressure` 0-1 (0.5), `squash` 0.1-1 (1), `angle` 0-179 (0), `angleJitter` 0-1 (0), `follow` 0/1 (0: dab keeps its angle, 1: turns with the line), `lightness`, `hue`, `blend` as for ink |

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

* **Brushes of extensions** (`ext:<extension>/<brush>`) are not embedded. The editor says so (a snack bar, once for each extension) when a note has lines of one the device does not have - on opening the note and when such lines arrive in a live session; the lines are drawn as the pen.
* Note history (`NoteHistory`) writes the brushes into its versions, but the history viewer does not register brushes it reads; a brush that was deleted from the library on purpose is not restored by looking at an old version.
* Extension brushes (`ext:...`) are not embedded.
* A charcoal brush is not smaller in a PDF than before (see pdf-brush-export in the architecture notes).
* **Deleting is not undoable and does not look at notes**: the question says that lines drawn with the brush become the pen; the app does not count the notes that use it. At 500 live brushes no more come in from notes and sessions.
* A version of the app from before this one opens a note with designed brushes and draws those lines as the pen.

## Advanced numbers, colour, blend

The designer shows the usual numbers of a kind and, under *Advanced*, the rest (`BrushKnob.advanced`); a brush that uses an advanced number opens that part when it is chosen. Every slider has a field beside it to type the number in (out of range is brought into range); choices (shape, blend) are named and move in whole steps.

Colour: `BrushLayer` has `lightness` and `hue` (a tint of the line's colour, `tintedColor`), and `BrushShape.multiply` says the line darkens what it lies on. Ink and stamps cut the line (or the dabs) into pieces and draw each of five colours near the line's own as a layer; the screen (`canvas_painters.dart`), the PDF (`pdf_brush.dart`: fill colour per layer, `/BM /Multiply`) and the designer's preview all read the same fields. Soft and charcoal do not vary colour (they are drawn through a cache of pictures). *Multiply* darkens against the other ink of the same page layer and against the page in a PDF; the screen draws ink in its own layer, so on a coloured paper it is not multiplied with the paper itself.

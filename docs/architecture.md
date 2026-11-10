# Architecture

Notation is one Flutter code base for Linux, Windows, macOS, Android and iOS. Nothing in `lib/` may assume a platform:
code that needs one checks for it (`Platform.isLinux`, `kIsWeb`) and has a fallback, or is behind an interface that
tests replace with a fake.

## The layers

```
 screens/  ──▶  services (ai/, sync/, speech/, graph/, lock/, ...)  ──▶  data/ (repositories, SQLite)
    │                          │
    └── models/, painters/, markdown/, algebra/ ... (pure code the others share)
```

* **`data/`** is the only code that talks to SQLite. Repositories return plain Dart objects (`note_data.dart`) and never a `Map` of
  columns. `NoteRepository` is about notes themselves (their content, folders, the trash, what changed) and hands out the repositories
  of the concerns that grew around them: `settings` (`SettingsRepository`, which stamps every value for the sync between devices),
  `locks` (`LockRepository`: the locks, and which locked notes are open now; what may be read is decided there), `templates`,
  `text` (the words of notes for the search and the AI), `knowledge` (vectors, passages, facts, the graph, links and citations) and
  `ai` (what the AI made of a note). Each is one class with its own SQL, built from the same database, so a test can make a
  `NoteRepository(db)` and reach all of them. `TaskRepository`, `StyleRepository` and the other stores stand alone. The schema and its
  migrations live in `database_schema.dart`; a change to the tables is a new step there plus a bump of `schemaVersion`
  (new tables use `CREATE TABLE IF NOT EXISTS`, so an older database can be brought up in any order).
* **What comes from outside is not trusted** (a note file, a message of a collaborator, a peer's folder): names that end up in a
  path go through `safe_names.dart`, zip files are read with the limits of `safe_zip.dart`, and `decodeNoteFile` leaves out what is
  not in the form it expects instead of failing (`test/hostile_input_test.dart`).
* **Services** hold the logic and the state that lives longer than a screen. They are `ChangeNotifier`s or plain
  classes, are made once in `main()` and handed down by constructor (`NotationApp` → `MainShellNavigation` → the
  screens). There is no service locator and no global state besides `AppLanguage.instance`.
* **`screens/`** only shows state and calls services. `fixed_page_note_editor.dart` is a `State` too large for one file;
  it is split into `part` files (`editor_*.dart`) that are extensions on that state, one per feature.
* **Pure code** (parsers, graph building, layout, the algebra checker, chunking, the Whisper mel spectrogram) takes data
  and returns data. It has no `BuildContext`, no I/O, and is what most unit tests cover. Heavy ones run in an isolate
  (`Isolate.run`) so the UI stays smooth.

## Where things are

| Folder | What it does |
|---|---|
| `data/` | SQLite stores, the `.uninote` file format (`note_file.dart`), note import/export, PDF notes |
| `models/`, `painters/` | Strokes, text boxes, highlights, shapes, and how a page is drawn |
| `screens/` | Every screen and dialog; `editor_*.dart` are parts of the note editor |
| `ai/` | Providers (on device Qwen, OpenAI-compatible), prompts, the document assistant, the all-notes retrieval (`note_knowledge.dart`), things the AI makes of a note (`note_ai.dart`) |
| `llm/` | Running Qwen and the sentence-embedding models with ONNX Runtime, model downloads |
| `graph/` | The knowledge graph: fact extraction, building, layout, snapshots (see `graph-architecture.md`) |
| `speech/` | Whisper speech to text, microphone, read aloud |
| `ink/`, `scan/` | Handwriting, maths from ink, OCR of photos |
| `algebra/` | LaTeX parsing, solving, derivatives and integrals, checking steps |
| `markdown/` | Parser shared by the on-screen view and the PDF export, syntax highlighting |
| `collab/` | Live sessions (WebRTC, end-to-end sealed), shared copies on cloud storage, merging |
| `nativeshare/` | Sharing a note or folder with people at the same cloud service (Nextcloud), kept in step by the folder sync (see `native-sharing.md`) |
| `sync/` | CalDAV, phone calendars, ICS feeds, tasks on calendars |
| `devicesync/` | Profile sync between a person's devices: keys and pairing, rooms on the signalling server, WebRTC links, the sync itself (see `profile-sync.md`) |
| `lock/` | Locking notes with a passcode or encryption |
| `history/` | Versions of a note and the difference between two |
| `automations/` | Rules that run when a note is made, changed or closed |
| `extensions/` | User scripts that run sandboxed in an isolate (see `extensions.md`) |
| `reminders/` | Reminders: the recurrence model, the service (timer, tasks' due dates, hand-over to the system), the notification sink |
| `capture/` | Quick notes, clipped web pages (article extraction), what other apps share, the `notation://capture` and `clip` links |
| `review/` | The weekly review: gathering the week, the digest, the assistant's summary (a read-only agent run over the digest, `ai/reading_agent.dart`) |
| `audio/` | Sound kept with notes: mu-law WAV codec, playback |
| `diagram/` | Mind maps and flowcharts from text: parsing and layout |
| `outline/`, `tags/` | The table of contents of a note; tag names and the tag tree |
| `spelling/`, `search/`, `templates/`, `style/`, `profile/`, `features/`, `l10n/` | Smaller features |

## Conventions

* **Words.** Text shown to people is written in English in the code. `l10n/text.dart` exports a `Text` that looks a
  literal up in the language in use; strings built at run time go through `tr('...{n}...', {'n': 3})` or `trCount`.
  The German table is `l10n/german.dart` (add a key there; a missing one just shows English, but `test/german_coverage_test.dart`
  reads the source and fails with the file and the text of every one that is missing; a text that is no word goes in `_asTheyAre` there).
* **Optional services.** A feature that may be off or missing (`ai`, `speech`, `locks`, ...) is a nullable parameter; the
  UI hides its buttons when it is null. This is also how tests build a screen with only what it needs.
* **Models that are downloaded** (`DownloadableModel`) show their state (`notInstalled`, `downloading`, `installed`),
  are fetched on request, and are unloaded again after a while so they do not hold memory.
* **Long work is cancellable** (`AiCancel`) and reports progress; work that must survive leaving a screen belongs to
  a service, not to the screen's `State` (the graph run and the lock timer are examples).
* **Nothing is generated on its own that costs much** (the graph, the facts, summaries): a button starts it, and what was
  made is kept (database and `.uninote` file) so it is not made twice.
* **Privacy by default.** Models run on the device; the cloud provider is opt-in and its key is in the system's secure
  storage. Locked notes are not read by the AI, the search, the graph or the previews.

## Tests

`flutter test` runs everything under `test/` (close to a thousand tests); the plugins with native code need the debug bundle's
libraries on Linux: `LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test`.

* Widget tests use `tester.runAsync` with real short delays wherever a database or an isolate is involved (the fake
  clock does not move those) and an in-memory database (`AppDatabase.open(path: inMemoryDatabasePath)`).
* Services take their outside world (network, microphone, models, calendars) as an interface or a function, so a test
  passes a fake: `PhoneCalendarApi`, `CausalLm`, `WhisperEngine`, `MicRecorder`, `TextEmbedder`, ...
* `integration_test/` runs the real models (Whisper, Qwen, handwriting, maths) on a desktop:
  `flutter test integration_test/<file> -d linux --dart-define=MODEL_DIR=...` (each file says what it needs).
* The signalling conformance tests (`test/collab/signaling_test.dart`) start the Dart server themselves; set
  `SIGNALING_URL` to run them against another implementation instead.

## Reading handwritten formulas

`MathService` (`lib/ink/math_service.dart`) is the one object the editor, the maths check and the settings talk to; behind it are two
models, chosen with `FormulaModel` and remembered in the setting `math_model`:

* **TexTeller 3.0** (Apache-2.0, `onnx_texteller_model.dart`): trained on handwriting; about 3 in 4 test formulas read exactly right.
  Two 8-bit ONNX files (encoder 88 MB, decoder 229 MB with a key/value cache, made by `tool/texteller_models.py`), a 448 x 448 gray
  picture with the proportions kept and a **thin pen** (`renderInkForTexTeller`: 0.02 of a letter height; a pen as thick as on the page
  drops it from about 3 in 4 to 1 in 4; only this picture is drawn so, the page is not changed). The decoder keeps its sessions open for
  a while after a formula (30 s on a computer, 6 s on a phone) because formulas are asked for one after the other. The model gives LaTeX
  as it is meant to be read, so `MathVocab.decodeRaw` is used, not `tidyLatex` (which would turn `\partial u` into `\partialu`).
* **Pix2Text-MFR** (MIT, `onnx_math_model.dart`): made for printed formulas, lighter (120 MB) and quicker, poor at handwriting. It is the
  choice for a device that is short of speed or memory.

TexTeller is the default everywhere (it runs on a 2020 mid-range tablet with 4 GB in a few seconds a formula); Pix2Text is the choice for
a device that is too slow or short of memory. A person who only has the Pix2Text files keeps reading with them until they download the
other. The TexTeller files are downloaded from the release of
https://github.com/nfa04/texteller-onnx-8bit, or, in the web build (GitHub's downloads carry no CORS headers), from
https://huggingface.co/nfa04/texteller-onnx-8bit (`MathService.defaultTellerRepo`; `--dart-define=TEXTELLER_REPO=<folder url>` points a
build elsewhere) and checked against their SHA-256 (`MathService.tellerChecksums`) before they are used: a file that differs is
removed. `tool/texteller_models.py` (the maintained copy is in that repository) makes the files again from the published ones.
`InkPrefetcher` forgets the formulas it read with the model before when the model is switched.

## Profiling

`tool/profile_app.dart` measures what a big library costs a release-like (AOT) build: the database, the code that runs at each key and
save, real frames of the editor, and the start of the app. It only works in a folder of its own, never on the notes of the person:

```
flutter build linux --profile -t tool/profile_app.dart
PROFILE_DIR=~/.cache/notation-profile PROFILE_FRESH=1 build/linux/x64/profile/bundle/notation
```

The top of the file says how to pick a part, how to see which functions the time goes to, and how to run it beside an app that is
open. `test/perf/large_pdf_profile_test.dart` does the same for big PDFs. Debug builds and `flutter test` say little about time.

The reference for typing is a document of 100 pages (140 KB of mixed text) on a tablet of about 2016: a key should show in under 50 ms.
`PROFILE_TABLET=1` measures it. One `TextField` cannot do that at this length: a key lays out and paints all of the text.

`PROFILE_ONLY=save` follows a save while a document of 5, 40 and 140 KB is written (a save does not grow with the document: the screen stands
still 6 to 9 ms at the median on a desktop at any of them), and `PROFILE_ONLY=export` makes a PDF, pictures, a `.uninote` file, a Word file and
a web page and says for each how long it took and how long the main isolate was busy at a stretch (the screen stood still).
`PROFILE_ONLY=pdfscroll` scrolls through imported PDFs (see "The pages of an imported PDF").

What it taught, for code that runs often:

* **A widget's key says what it is, not where it is.** A key made from an offset in the text changes with each key pressed before it,
  and the widget and everything in it is made anew.
* **`shrinkWrap` builds everything.** A list that can be long goes into a `CustomScrollView` as a sliver.
* **One paragraph has a price.** A `RichText` with widgets in it works out the accessibility of all its text again for each of them.
* **Impeller keeps no pixels.** A `RepaintBoundary` saves painting, but what is in it is still drawn for every frame.
* **What is native is let go of by hand.** `Picture`, `ui.Image` and `TextPainter` live outside the memory of Dart, which does not
  feel them fill up: `dispose` them instead of waiting for a collection.

## The platform look

The app is Material all through. `style/platform_look.dart` dresses it as an iPhone app when that is wanted (Settings > General > Appearance > Platform look: Automatic is iOS on an iPhone or iPad only, or force Material or iOS to try it on any device). `iosLook(ThemeData)` sets `ThemeData.platform` to iOS, which brings the iOS font, the swipe-back transition, the bouncing scroll and the iOS text selection, and restyles the app bar, cards, dialogs, sheets, menus and the navigation bar. `NotationApp` applies it before the accessibility theme, so the accessibility settings win.

Switches, sliders, check boxes and spinners are made with their `.adaptive` constructors (use those in new code; a Radio is not yet). A dialog is *not* made with `AlertDialog.adaptive`: the iOS alert has no `Material` above it, so a text field or list tile inside it would fail. Dialogs are only restyled by the theme.

## Adding a feature: a checklist

1. Put the logic in a service or a pure function, with its outside world behind an interface.
2. If it keeps data: a table (or column) and a migration in `database_schema.dart`, access in a repository.
3. If it should travel with a note: a field in the `.uninote` manifest (`note_file.dart`), read and written by
   `note_file_service.dart`. Old files without the field must still open.
4. Wire the service in `main()` and pass it down; make the parameter nullable.
5. Words in English in the code, a line in `german.dart`.
6. A unit test for the logic, a widget test for the screen, and a short section in the README for what the person sees.

## Handwriting as text in an exported PDF

A PDF viewer selects, copies and searches text it finds in the file, and finds none in a line drawn with a pen. `lib/export/pdf_ink_text.dart` puts
the text of the handwriting under the ink, in PDF text mode 3 (neither filled nor stroked: nothing is drawn, the viewer still has the letters).

* What the writing says is not read for the PDF alone. The search keeps it (`ink_text`, by the key of the block of strokes, see `InkIndexer`), an open
  note has more in `NoteInkReader.prefetcher`; `PdfInkText` takes both, and reads the blocks that have none with the handwriting reader, for at most a
  minute (the rest is counted in `unread` and told to the person). A block that was read and came out empty is not read again.
* Where the text goes: `inkTextLines` cuts the strokes of the block into lines with `groupIntoLines`, the same cut the reader made, so line *n* of the
  text is the *n*th line of writing. When the numbers differ the block is cut into equal rows. The reader gives no box for a word, so a line is one
  string, stretched (`Tz`) to the width of its ink: a viewer marks a word about where it is written, by the width of its letters.
* Only the strokes the page shows are used: nothing from a hidden layer is read or written into the file.
* The font is the built in Helvetica, which costs the file nothing; letters it cannot write (Greek, say) are left out. A font to embed would carry them,
  and the file would grow by its size.
* It is in `_buildOverlayPage`, so it holds for all three exports (a note, an imported PDF with the overlay merged on, the rasterised fallback). The
  setting `pdf_handwriting_text` (on unless `0`) switches it off. Formulas (LaTeX) are not put in.

## Brush lines in an exported PDF

A brush (`lib/models/brush.dart`) makes an `Outline` (`lib/models/outline.dart`), not a bare `Path`: the polygons, circles and ribbons it is made of,
with the `Path` for the screen made from them the first time it is asked for. `drawBrushOnPdf` (`lib/export/pdf_brush.dart`) writes those pieces
as they are: a polygon as its corners, a circle as four curves, a layer made only of ribbons of one thickness (the airbrush's rings, the marker) as their
lines stroked that thick with round ends and joints, which is the same shape. Each layer is one fill, so where its pieces overlap it is no darker,
as on the screen. Points are rounded to hundredths.

* Before this the outline was followed in steps of 1.5 (a `PathMetrics` call and a `lineTo` for each), and a ribbon is a quad and a full circle every
  3 units: one airbrush line came to 1.5 MiB. A page of six lines of every brush now draws in about a tenth of the time (11.5 s to 0.9 s in a debug
  test run) and is 2.7 MiB instead of 17.6.
* What the screen blurs (`BrushShape.soft`) the PDF cannot: it draws the plain layers, as before.
* Charcoal is still big (about 180 KiB for a line 215 long, uncompressed, as before): its streaks are ribbons of many thicknesses in one layer, so they
  are quads and circles. Drawing each layer opaque in a transparency group painted at the layer's opacity would let them be strokes, at the cost of a
  group per layer for the viewer to render; not done.
* **The pen's pressure** (`drawPressureLineOnPdf`): a line the screen draws with pressure (`drawsWithPressure`, with the stylus sensitivity the
  pages use) is, if opaque, its points stroked in runs of one width; a new run begins where the width has changed by `pressureWidthStep` (0.1, about
  0.04 pt either way, below a 1200 dpi dot), and a segment whose ends differ by more is cut into pieces of a step. That costs about twice a line of one
  width, where the exact outline (a quad and a circle a point) costs over ten times. A see-through line is its exact outline filled once, as runs
  would overlap darker at their joints. Before, every pen line was written one width all along.
* `test/pdf_brush_test.dart` draws a line of every brush, and pen lines with smooth and jumping pressure, through PDFium and compares them with the same
  shapes drawn by Flutter, pixel by pixel.

## The pages of an imported PDF

PDFium does one thing at a time, on pdfrx's isolate. What the editor asks of it goes through `PageJobs` (`lib/pdf/page_jobs.dart`):

* **Ranked when it starts, not when it was asked for.** Each time something can start, `_jobRanker` ranks what waits: the pictures of the pages on
  screen, what is on screen of them made sharp for the zoom, their words, then the pages ahead of the reading (`_pagesAhead`) and their words, then
  those behind. A page that is built (`_BuiltPage`) is never dropped; anything else out of reach is dropped, and called off if it runs (pdfrx 2.11
  renders in slices of about 8 ms and looks at its cancel token between them). One job runs; one wanted much more may start beside it.
* **Nothing starts during a fling** of more than two pages a second (`_flingingPast`): what it passes would be drawn after it is gone, in front of
  the page it stops on. Before, a fling or a drag of the scrollbar asked for every page it passed, and the page it stopped on came last (1.8 s for
  scans, 2.5 s for drawings after 15 jumps).
* **A picture is as wide as the screen shows the page** (`pagePixelWidth`: in steps of 256, never more than the dpi of the settings): about 1280
  pixels on a tablet instead of 1654 to 2067. The dpi setting is the most, and what exported pictures of pages use.
* **Zoomed in, only what is on screen is rendered sharp** (`_SharpPatch`, `renderPageRegion`), with a quarter more around it, once the zoom and the
  scrolling have settled. It used to be the whole page at up to 4800 pixels across (64 MB) for each page near the screen.
* **The words come apart from the picture** (`PdfPageWords`): the picture shows when it is drawn, and the text layer of the page gets its words
  when they are read. pdfrx's reading order and line breaks and `linesOf` run on another isolate (`pdfWordsOf`); on the main isolate they held the
  screen still for each page that came in. `_RawTextPage` gives pdfrx's text layout the raw text there, so it is pdfrx's own code that runs.
* **The scrollbar's preview** shows the page's picture if it is kept, else a small one of the page under the finger only.

`PROFILE_ONLY=pdfscroll` reads, flings and jumps through PDFs of dense text, scans and drawings. What is left (text PDFs only) is the text layer:
a `Text` for each word inside a `SelectionArea`. When a page's words arrive, the area adds and sorts all its selectables by screen order (20% of the
main isolate in the jumps), and lays out, builds and later removes hundreds of paragraphs (36%); Linux also makes their semantics (18%). One
render object for the whole layer, taking part in the selection as a `Selectable`, would remove that.

## The block editor

A long document cannot be written in one `TextField`: it lays out all of its text at each key (44 ms at 120 KB on a fast desktop with no
app code at all). `lib/block_editor/` writes it line by line, and is the only editor of the written document.

* The `LiveMarkdownController` is still the only truth: text, selection, attributes. Everything else that changes the document (the toolbar, the
  assistant, undo, collaboration) changes it as before, and the editor follows its notifications.
* `DocumentLines` holds one `DocumentLine` per `MdBlock` (a blank line is a block too). A line keeps its id and height while the text around it
  changes. `parsedText` says which lines changed.
* Only the lines around the screen exist (half a screen either way), each a `RichText` of its own under a `RepaintBoundary`, placed by
  `RenderBlockColumn` in a box as tall as the whole document. Each line has a `_Look` in its own coordinates, which is why a key
  rebuilds one line: the lines after it only move. A callback in a line (a tick box, a link) asks where the line starts when it is called.
* A line is drawn by `_LiveBuilder` from a `LiveSource` that holds only that line, with its places counted from its start. What lines know of each
  other is in `LiveFacts`, looked at again after the frame, and only when a change touches something that can matter.
* The keyboard is told of a small stretch of the text around the caret (`_imeRoom`), through the delta model.
* The lines are on sheets of paper, as in the read view: `DocumentLines` places each one, going over to the next sheet between two wrapped rows (`DocumentLine.breaks`), never inside a table or the like, and after a page break. A line does not know of its gap: its render object draws its rows either side of it, and `shift` and `natural` turn a place in the line into where it is drawn and back. A key that changes no height places nothing.
* Heights are estimates until a line was laid out; in idle time a few lines to a frame are. A line above the screen that turns out another height
  does not go into the layout: it is applied between frames, together with the scroll correction (`correctBy` during layout comes too late for
  the viewport, and the page jumps).
* What sits over the page must not repaint with it: `RenderBlockColumn` has its own boundary (a layout repaints the object itself), the sheets are
  drawn only near the screen, the side ruler has its own boundary, and `FollowingToolbar` rebuilds the toolbar only when something it shows changes.
* `MdBlock.shifted` is O(1): runs and markup catch up when read.

### Opening a long document

A note opens in the read view, which has to lay out all of the text to know where the sheets end. In one frame that stood still for as long as the
document is long, and a spinner would stand still with it. `LivePieces` holds the pieces of the text as far as they were made, one list for the view
that is measured and for the sheets: a `LiveMarkdownView` with `inTurn` makes as many to a frame as take a few milliseconds, so that the first sheets are
there at once. `documentSheetBreaks` keeps what it found of each piece (`known`), and the sheets are worked out again at most every 250 ms while
pieces come in. A note opened to go to a page or a find takes all of them in the first frame (`LivePieces.atOnce`), which has to know where the end is.
All of the text is laid out once, unseen; only sheets near the screen show theirs (`_sheetsNear`), and that follows `ScrollMetricsNotification` too:
a place the layout puts right tells no scroll listener.

### Zooming far down a note

`PageList` is told the height of every page (`_pageExtent`) and the total, so where each page is and where the list ends are known whatever is built.
A `SliverList` keeps the pages it has built where they were when their size changes, which is another page than the one worked out, more so the further
down, and it only guesses its length. A height that changes must go through `setState`, and each page sits in an `OverflowBox` for the frame until then.
`_setZoom` changes the size and the scrolling for the same frame: `moveWithZoom` sets the position silently, since a jump would be sent back when the new
position is past the old end. Listeners are told after that layout, the editor first (`pageResized`): it adds the distance scrolled to the last layout,
which does not hold across a change of size.

Numbers and how to get them: `tool/profile_app.dart`.

On a touch screen: a long press goes by whole words from the word pressed, a finger only selects in text being written (else it scrolls), and the
menu is part of the text's tap region, stands over the selection, follows it (`_followMenu`) and goes when it has left the screen. The caret moves the
page only when it moved (`_caretWas`): a notification of the spell check is no reason to scroll back to it. The formatting bar at the side keeps the shape
it has without a keyboard and scrolls (`SteadyBar`): in the height a keyboard leaves it would go to more columns, each taken from the width of the page.

What the system adds to a keyboard is in `block_editor/block_input.dart`, written like the framework's own text field does it (and none of it tried on
a device yet):

* The floating cursor of iOS (`updateFloatingCursor`): a cursor is drawn where the finger is, the caret at the place it would go to (`_Floating`, painted by
  `_RenderBlockMarks`), and the selection goes there at the end, unless the keyboard made a selection meanwhile (two fingers). The framework drops the place
  the start message carries and counts every update from nothing: the origin here is the start's offset, which is zero.
* Scribble on iPadOS: the editor is a `ScribbleClient` (`TextInput.registerScribbleElement`), and `_sendRects` tells the system where the letters of the
  keyboard's window are (`SelectionRect`, positions are those of the window, not of the document), debounced and after a frame, for what is on the screen.
* Stylus handwriting on Android 13 and up: a pen down on the text puts the caret there, makes sure of the connection and calls `Scribe`; what it reads
  arrives as deltas like keys.
* Pictures from the keyboard: `BlockEditor.onContent` makes the config declare `blockContentTypes`; `_insertKeyboardPicture` keeps the picture with the note
  (`DocumentImages.forKeeping`: PNG, JPEG and GIF as they come, anything else as PNG, because the exports know only those) and writes `![Picture](image:...)`.

* Pen gestures inside the editor (`pen_gesture.dart`, `_BlockPen`), for where nothing else takes the pen: a `Listener` follows a stylus stroke, and when
  the pen lifts `recognizePenGesture` looks at it, by the height of a line (a gesture is the size of a word): a zigzag over words deletes them (whole
  words, and a space with them), a loop selects them, a short stroke down between two letters makes a space, down on a space takes it away. Anything else
  is the drag that selects, as before. The gesture must lie over the text it names, and a finger or a mouse never makes one. Where the system takes the
  pen (Scribble, the handwriting of an Android keyboard) the stroke is cancelled before it ends and nothing happens here. Thresholds are guesses from
  synthetic strokes; a real hand on a real tablet may need them moved (the numbers are in `recognizePenGesture`).

Known gaps: Scribble's text placeholder (`insertTextPlaceholder`: the system asks for room where the pen writes; none is made, the text is put in when the
writing is read); the system's own handwriting gestures on Android (cross out, join) are not handled, since Flutter's Android embedder has no `performHandwritingGesture`; the spell check still reads all of the
text a moment after typing stops (`recheckSpelling`), which is a pause on a slow device with a long document.

## Spell checking of handwriting

The words of the handwriting are checked with the same dictionaries as text boxes (`SpellService`, tool "Spell checking"). The
background reader (`NoteInkReader`, which also keeps the readings for the search and the PDF text) reads the note when a dictionary is on;
`misspelledInk` (`lib/ink/ink_spelling.dart`) takes the readings, cuts them into lines with `inkTextLines`, and places each unknown word by
its share of the line (the reader keeps no box per word, so the underline is near the word, not exact). Words of up to two letters are left
alone. The editor (`editor_ink_spelling.dart`) draws a wavy red line under the word and a tap offers suggestions (copied to the clipboard,
the ink cannot be changed), "Add to dictionary" and "Ignore". A changed block has a new key, so its old underlines go until it is read again.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;

/// The groups the tools are listed in.
enum FeatureGroup {
  writing('Writing and drawing'),
  creative('Creative tools'),
  maths('Maths'),
  reading('Reading and looking things up'),
  note('Note buttons'),
  ai('Assistant'),
  organising('Organising and sharing');

  final String title;
  const FeatureGroup(this.title);
}

/// A tool of the app that can be switched on or off. What is not listed here is always there: the pen, the eraser,
/// text boxes, the written document, folders, the dashboard and the settings.
enum Feature {
  highlighter(FeatureGroup.writing, 'Highlighter', 'A see-through marker for the drawing bar.', Icons.border_color_outlined),
  roller(FeatureGroup.writing, 'Roller pen', 'A paint roller for the drawing bar: a wide band with streaks.', Icons.format_paint_outlined),
  shapes(FeatureGroup.writing, 'Shapes', 'Lines, arrows, rectangles and ellipses drawn with the pen.', Icons.crop_square),
  lasso(FeatureGroup.writing, 'Lasso', 'Select, move, copy and delete drawings, text boxes and pictures by drawing around them.', Icons.gesture),
  straighten(FeatureGroup.writing, 'Straight lines and shapes', 'Lines drawn nearly straight are straightened, and drawings very close to a rectangle, ellipse, triangle or diamond become that shape.', Icons.show_chart),
  images(FeatureGroup.writing, 'Pictures', 'Put pictures on a page.', Icons.add_photo_alternate_outlined),
  themeImages(FeatureGroup.writing, 'Theme images', 'A picture at the top of a note, a folder or a day of the calendar.', Icons.wallpaper_outlined),
  spelling(FeatureGroup.writing, 'Spell checking', 'Underlines misspelled words in text boxes and the written document, with suggestions. Needs a dictionary from the settings.', Icons.spellcheck),
  tables(FeatureGroup.writing, 'Tables', 'Tables in text boxes and in the written document.', Icons.table_chart_outlined),
  diagrams(FeatureGroup.writing, 'Mind maps and diagrams', 'Turn an outline into a mind map, lines like "Start -> Check -> Done" into a flowchart, or (advanced) a state diagram, a tree or a graph, on the page.', Icons.account_tree_outlined),

  brushes(FeatureGroup.creative, 'More brushes', 'Pencil, fountain pen, calligraphy nib, marker, charcoal, airbrush and watercolour for the drawing bar.', Icons.brush_outlined),
  guides(FeatureGroup.creative, 'Guides and rulers', 'Overlays for composition (thirds, golden ratio, grid) and perspective, and a ruler or set square that the lines you draw along it follow.', Icons.straighten),
  flipbook(FeatureGroup.creative, 'Flipbook', 'Play the pages of a note one after the other like the frames of an animation, round and round, at a speed you choose; while drawing, the pages before and after can show through faintly (onion skin).', Icons.movie_filter_outlined),
  ideas(FeatureGroup.creative, 'Ideas from the assistant', 'Ask the assistant for a colour palette for a mood or subject, or for ideas to start from: a drawing, a character, a story, a song, a design. Needs the assistant.', Icons.lightbulb_outline),
  pathText(FeatureGroup.creative, 'Text on lines and shapes', 'Write words along a line, a curve or round a shape, or inside a shape. The text belongs to the drawing and goes where it goes.', Icons.text_rotation_angleup),
  alignLines(FeatureGroup.creative, 'Alignment lines', 'Lines that show where a text box, picture or shape you are moving lines up with the others on the page (or the middle and edges of the page), and let it fall into place. Hold Alt to move freely.', Icons.align_horizontal_center),
  exportImages(FeatureGroup.creative, 'Export as pictures', 'Save the pages of a note as pictures (PNG) in a size for the web, a screen, print, a post, a slide or a story, with the background left out if you like.', Icons.image_outlined),
  stamps(FeatureGroup.creative, 'Stamp library', 'Keep drawings (a symbol, a logo, a flourish) as stamps and put them on any page again.', Icons.approval_outlined),
  arrange(FeatureGroup.creative, 'Align, distribute and group', 'Line up several selected drawings, text boxes and pictures along an edge or their middle, space them evenly, or group them so that they are selected, moved and copied together.', Icons.align_horizontal_left),
  pictureEdit(FeatureGroup.creative, 'Picture editing', 'Crop, turn, adjust the colours of, filter, and take the background out of a picture on a page.', Icons.tune),
  layers(FeatureGroup.creative, 'Layers', 'Draw on layers that can be hidden, locked, reordered and made see-through, and move drawings between them.', Icons.layers_outlined),
  symmetry(FeatureGroup.creative, 'Symmetry drawing', 'Draw with a mirror or around a centre: what you draw is repeated on the other side or in turns (mandalas, patterns).', Icons.flip),
  colorPicker(FeatureGroup.creative, 'Eyedropper', 'Pick a color from anything on the page (a drawing, a picture, a PDF) for the pen: tap the button or press I, then touch the color.', Icons.colorize_outlined),
  fillBucket(FeatureGroup.creative, 'Fill bucket', 'Fill a closed area of a drawing with the pen color by touching it: the area is found from the lines round it, and small gaps in them can be closed. The fill is a shape under the lines, so it can be recolored or moved later.', Icons.format_color_fill),
  stabiliser(FeatureGroup.creative, 'Line stabiliser', 'Smooths a shaky hand: the line follows the pen with a little delay, for clean lettering and line art.', Icons.timeline),

  solve(FeatureGroup.maths, 'Calculate and solve', 'Calculate, solve, differentiate and integrate in text.', Icons.functions),
  plots(FeatureGroup.maths, 'Plots', 'Graphs of functions, and empty plots to draw into.', Icons.auto_graph),
  checkMaths(FeatureGroup.maths, 'Check my maths', 'Marks the maths you write as right or wrong, line by line, a moment after you wrote it, and gives the result of a line that ends with =. Needs the formula model from the settings.', Icons.rule),
  mathInk(FeatureGroup.maths, 'Handwritten formulas', 'Turn a handwritten formula into LaTeX (needs the model from the settings).', Icons.draw_outlined),

  pdf(FeatureGroup.reading, 'PDF', 'Import a PDF to write on, and export a note as a PDF.', Icons.picture_as_pdf_outlined),
  citations(FeatureGroup.reading, 'Citations', 'Keep the papers and books you read, quote them in a note with [@key] and have the sources listed in the style you need (APA, MLA, Chicago, Harvard, IEEE).', Icons.format_quote),
  lookup(FeatureGroup.reading, 'Look things up', 'Search the web, Wikipedia and translate from selected text, with the page beside the note.', Icons.travel_explore),

  favorites(FeatureGroup.note, 'Favourites', 'A star on a note, to find it again quickly.', Icons.star_outline_rounded),
  lock(FeatureGroup.note, 'Lock', 'Lock a note, so that it asks for the code before it opens.', Icons.lock_outline),
  reminders(FeatureGroup.note, 'Reminders', 'Be reminded about a note at a time you choose.', Icons.add_alert_outlined),
  echoes(FeatureGroup.note, 'Notes that say the same', 'While you write, a small note names the other notes that have facts about the same things (from the facts of the graph view), to open them.', Icons.hub_outlined),
  outline(FeatureGroup.note, 'Outline and bookmarks', 'The outline of a note, bookmarks on its pages and the links to other notes.', Icons.format_list_bulleted),
  present(FeatureGroup.note, 'Presenting', 'Show the pages of a note full screen, one after the other, like slides.', Icons.slideshow_outlined),
  audio(FeatureGroup.note, 'Sounds', 'Keep sounds with a note and play them, and have a note read into a sound file.', Icons.headphones_outlined),
  translate(FeatureGroup.note, 'Translate a note', 'Translate the whole note into another language with the assistant.', Icons.translate),
  dictate(FeatureGroup.note, 'Dictation', 'Write down what is said (needs the speech model from the settings).', Icons.mic_none),
  readAloud(FeatureGroup.note, 'Read aloud', 'Have the note read to you (needs a voice from the settings).', Icons.volume_up_outlined),

  handwriting(FeatureGroup.ai, 'Handwriting to text', 'Turn handwriting into text (needs the model from the settings).', Icons.text_snippet_outlined),
  assistant(FeatureGroup.ai, 'Assistant', 'Ask questions about a document and have it summarised.', Icons.auto_awesome),
  flashcards(FeatureGroup.ai, 'Flashcards', 'Make flashcards from a document with the assistant, and learn them. Needs the assistant.', Icons.style_outlined),

  calendar(FeatureGroup.organising, 'Calendar and tasks', 'The calendar, the week view, tasks and syncing them.', Icons.calendar_month_outlined),
  automations(FeatureGroup.organising, 'Automations', 'Rules that sort, title and file notes by themselves.', Icons.bolt_outlined),
  history(FeatureGroup.organising, 'History', 'Earlier versions of a note, to compare and go back to.', Icons.history),
  live(FeatureGroup.organising, 'Working together', 'Live sessions and shared copies of notes with other people.', Icons.group_outlined),
  noteFiles(FeatureGroup.organising, 'Note files', 'Save a note as a file (.uninote) and open one.', Icons.save_alt_rounded);

  final FeatureGroup group;
  final String title;
  final String description;
  final IconData icon;

  const Feature(this.group, this.title, this.description, this.icon);

  /// The tool [id] names, null for one this version does not know.
  static Feature? byId(String id) => values.where((f) => f.name == id).firstOrNull;
}

/// What a person uses the app for, which decides what is switched on to begin with.
enum UseArea {
  maths('Mathematics and physics', 'Formulas, proofs, problem sheets and graphs.', Icons.functions),
  sciences('Chemistry, biology and medicine', 'Diagrams, tables, lab notes and a lot to learn by heart.', Icons.biotech_outlined),
  computing('Computer science and engineering', 'Diagrams, tables, specifications and code.', Icons.terminal),
  humanities('Philosophy, history and literature', 'Reading texts closely, quoting and arguing in writing.', Icons.menu_book_outlined),
  languages('Languages', 'Vocabulary, grammar and texts in more than one language.', Icons.translate),
  society('Law, business, economics and social sciences', 'Cases, tables, readings and deadlines.', Icons.balance_outlined),
  arts('Art and design', 'Sketches, pictures and layouts.', Icons.palette_outlined),
  together('Working with others', 'Sharing notes and writing them together.', Icons.groups_outlined);

  final String title;
  final String description;
  final IconData icon;

  const UseArea(this.title, this.description, this.icon);

  /// A short name, for a toolbar profile.
  String get shortTitle => switch (this) {
        UseArea.maths => 'Maths',
        UseArea.sciences => 'Sciences',
        UseArea.computing => 'Computing',
        UseArea.humanities => 'Humanities',
        UseArea.languages => 'Languages',
        UseArea.society => 'Society',
        UseArea.arts => 'Art and design',
        UseArea.together => 'Together',
      };

  /// Which way of working this use is: uses of one kind share most of their tools and are often at hand together (maths and the
  /// sciences), uses of different kinds are seldom (maths and art). Working with others is no way of working of its own: -1.
  int get _kind => switch (this) {
        UseArea.maths || UseArea.sciences || UseArea.computing => 0,
        UseArea.humanities || UseArea.languages || UseArea.society => 1,
        UseArea.arts => 2,
        UseArea.together => -1,
      };

  /// Whether [areas] are of different kinds (maths and art), so that a person may well use them one at a time: the uses to
  /// offer a toolbar profile each for.
  static bool unrelated(Iterable<UseArea> areas) => {for (final a in areas) a._kind}.where((k) => k >= 0).length >= 2;

  /// The tools this use adds to the ones everybody gets ([FeaturePresets.basics]).
  Set<Feature> get features => switch (this) {
        UseArea.maths => {Feature.solve, Feature.plots, Feature.mathInk, Feature.checkMaths, Feature.handwriting, Feature.tables, Feature.shapes, Feature.straighten},
        UseArea.sciences => {Feature.diagrams, Feature.tables, Feature.citations, Feature.shapes, Feature.straighten, Feature.flashcards, Feature.assistant, Feature.handwriting, Feature.plots, Feature.solve},
        UseArea.computing => {Feature.diagrams, Feature.tables, Feature.shapes, Feature.straighten, Feature.automations, Feature.lookup, Feature.assistant},
        UseArea.humanities => {Feature.diagrams, Feature.citations, Feature.lookup, Feature.assistant, Feature.flashcards, Feature.themeImages, Feature.handwriting},
        UseArea.languages => {Feature.lookup, Feature.flashcards, Feature.assistant, Feature.handwriting},
        UseArea.society => {Feature.diagrams, Feature.tables, Feature.citations, Feature.lookup, Feature.assistant, Feature.flashcards, Feature.automations},
        UseArea.arts => {Feature.diagrams, Feature.shapes, Feature.straighten, Feature.themeImages, Feature.handwriting, Feature.brushes, Feature.symmetry, Feature.stabiliser, Feature.layers, Feature.pictureEdit, Feature.guides, Feature.arrange, Feature.stamps, Feature.flipbook, Feature.ideas, Feature.exportImages, Feature.pathText, Feature.alignLines, Feature.colorPicker, Feature.fillBucket},
        UseArea.together => {Feature.live, Feature.history},
      };
}

/// Ready-made sets of tools.
class FeaturePresets {
  /// What everybody gets, whatever they use the app for.
  static const basics = {Feature.favorites, Feature.lock, Feature.reminders, Feature.outline, Feature.echoes, Feature.present, Feature.audio, Feature.translate, Feature.dictate, Feature.readAloud, Feature.spelling, Feature.highlighter, Feature.roller, Feature.lasso, Feature.images, Feature.pdf, Feature.history, Feature.noteFiles, Feature.calendar};

  /// Only what a notebook with a pen needs.
  static const minimal = <Feature>{Feature.pdf};

  /// Every tool.
  static Set<Feature> get everything => {...Feature.values};

  /// The tools for a person who uses the app for [areas]: the basics and what each use adds. No uses: the basics.
  static Set<Feature> forAreas(Iterable<UseArea> areas) => {...basics, for (final a in areas) ...a.features};
}

/// Which tools are on. Without anything saved, every one is (the app as it always was).
class FeatureSettings extends ChangeNotifier {
  static const enabledKey = 'features_enabled';
  static const areasKey = 'features_areas';
  static const knownKey = 'features_known';

  /// The tools that came after the lists of tools were first saved. A list saved without a record of what it knew leaves these on
  /// (a new tool is there for a person who never chose against it).
  static const _added = {Feature.citations, Feature.diagrams, Feature.brushes, Feature.symmetry, Feature.stabiliser, Feature.layers, Feature.pictureEdit, Feature.guides, Feature.arrange, Feature.stamps, Feature.flipbook, Feature.ideas, Feature.exportImages, Feature.alignLines, Feature.favorites, Feature.lock, Feature.reminders, Feature.outline, Feature.echoes, Feature.present, Feature.audio, Feature.translate, Feature.dictate, Feature.readAloud, Feature.colorPicker, Feature.fillBucket};

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  FeatureSettings(this._read, this._write);

  Set<Feature> _enabled = FeaturePresets.everything;
  Set<UseArea> _areas = {};

  /// The tools that are on.
  Set<Feature> get enabled => Set.unmodifiable(_enabled);

  /// The uses the person chose in the intro (empty if they picked "everything", or never chose).
  Set<UseArea> get areas => Set.unmodifiable(_areas);

  /// Whether this tool is on. A tool that needs another is on only if that is too (flashcards need the assistant).
  bool on(Feature f) => _enabled.contains(f) && (f != Feature.flashcards || _enabled.contains(Feature.assistant));

  /// Whether every tool is on.
  bool get allOn => _enabled.length == Feature.values.length;

  Future<void> load() async {
    final text = await _read(enabledKey);
    if (text != null) {
      try {
        _enabled = {for (final id in jsonDecode(text) as List) ?Feature.byId(id as String)};
        // tools the saved list did not know of are on
        final known = await _read(knownKey);
        final knew = known == null ? {for (final f in Feature.values) if (!_added.contains(f)) f} : {for (final id in jsonDecode(known) as List) ?Feature.byId(id as String)};
        _enabled = {..._enabled, for (final f in Feature.values) if (!knew.contains(f)) f};
      } catch (_) {
        _enabled = FeaturePresets.everything;
      }
    }
    final areas = await _read(areasKey);
    if (areas != null) {
      try {
        _areas = {for (final id in jsonDecode(areas) as List) ...UseArea.values.where((a) => a.name == id)};
      } catch (_) {
        _areas = {};
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    await _write(enabledKey, jsonEncode([for (final f in Feature.values) if (_enabled.contains(f)) f.name]));
    await _write(areasKey, jsonEncode([for (final a in UseArea.values) if (_areas.contains(a)) a.name]));
    await _write(knownKey, jsonEncode([for (final f in Feature.values) f.name]));
  }

  /// Switches one tool on or off.
  Future<void> set(Feature f, bool value) async {
    if (value == _enabled.contains(f)) return;
    _enabled = {..._enabled};
    value ? _enabled.add(f) : _enabled.remove(f);
    await _save();
    notifyListeners();
  }

  /// Switches on exactly [features], remembering that they came from [areas] (none for a preset that is not made of uses).
  Future<void> apply(Set<Feature> features, {Set<UseArea> areas = const {}}) async {
    _enabled = {...features};
    _areas = {...areas};
    await _save();
    notifyListeners();
  }

  /// Every tool on.
  Future<void> showAll() => apply(FeaturePresets.everything);
}

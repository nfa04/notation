import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Size;

import '../ai/flashcards.dart' show Flashcard;
import '../data/bookmark_repository.dart';
import '../data/card_repository.dart';
import '../data/note_activity.dart';
import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../extensions/draw_result.dart';
import '../extensions/extension_host.dart';
import '../extensions/note_format.dart';
import '../extensions/pdf_text.dart';
import '../l10n/language.dart';
import '../markdown/markdown_formatting.dart' show decideChanges;
import '../models/authorship.dart';
import '../models/canvas_models.dart';
import '../models/image_item.dart';
import '../models/page_background.dart';
import '../models/page_format.dart';
import '../models/rich_text.dart';

/// What the assistant (`agentTools`) can do with a note, for a note that is not open in an editor: the same calls as the editor's
/// ([ExtensionApi]), done on the note as the database holds it. A note that is open must be changed through its editor instead, which
/// would write over this.
class StoredNoteApi extends ExtensionApi {
  final NoteRepository repository;
  final String noteId;

  /// Where flashcards are kept, and the bookmarks of pages (which follow the pages when they are moved); null: not offered.
  final CardRepository? _cards;
  final BookmarkRepository? bookmarks;

  StoredNoteApi(this.repository, this.noteId, {CardRepository? cards, this.bookmarks}) : _cards = cards;

  Future<NoteData> _load() async {
    final note = await repository.loadNote(noteId);
    if (note == null) throw ExtensionError('There is no such note.');
    return note;
  }

  /// A note without a written document (a PDF, an infinite canvas): text goes on the page in text boxes.
  static bool _hasNoDocument(NoteData note) => note.pdfPath != null || note.pageFormat.isInfinite;

  /// The text of the note that can be changed, as the editor's assistant sees it (and calls it): the written document and the text
  /// boxes on layers that are not hidden or locked. [save] writes it back.
  Future<({List<RichInlineTextController> texts, List<String> labels, Future<void> Function() save})> _texts() async {
    final note = await _load();
    final document = RichInlineTextController()..text = note.documentText;
    document.attributes.addAll([for (final s in note.documentSpans) s.copy()]);
    final parts = <({String label, RichInlineTextController text})>[
      (label: tr('The written document'), text: document),
      for (final page in note.textBoxes.keys.toList()..sort())
        for (final box in note.textBoxes[page]!)
          if (note.layers.byId(box.layer).editable) (label: tr('Text box on page {n} (size {size})', {'n': page + 1, 'size': box.fontSize.round()}), text: box.controller),
    ];
    return (
      texts: [for (final p in parts) p.text],
      labels: [for (final p in parts) p.label],
      save: () async {
        note.documentText = document.text;
        note.documentSpans = [for (final s in document.attributes) s.copy()];
        await repository.saveNote(note);
      },
    );
  }

  @override
  Future<Map<String, Object?>> note() async {
    final info = await repository.noteInfo(noteId);
    return {'id': noteId, 'title': info?.title ?? '', 'text': await repository.text.noteText(noteId, limit: 20000)};
  }

  /// At the end of the written document, or as a text box under the last thing on the last page where there is none.
  @override
  Future<void> insertText(String text) async {
    final note = await _load();
    if (_hasNoDocument(note)) {
      final page = math.max(0, NoteHeld.of(note).pages - 1);
      var bottom = note.pdfPath == null ? 0.0 : 24.0;
      for (final b in note.textBoxes[page] ?? const <TextBoxWidgetModel>[]) {
        bottom = math.max(bottom, b.position.dy + (b.size.height > 0 ? b.size.height : 24.0));
      }
      for (final s in note.strokes[page] ?? const <DrawingStroke>[]) {
        for (final p in s.points) {
          bottom = math.max(bottom, p.dy);
        }
      }
      final box = TextBoxWidgetModel(id: 'mcp-${NoteRepository.newId()}', position: Offset(40, math.min(bottom + 16, 1050)), size: const Size(720, 0), initialText: text, fontSize: 14);
      await repository.putTextBox(noteId, page, box);
      return;
    }
    final now = note.documentText;
    final gap = now.trim().isEmpty ? '' : (now.endsWith('\n\n') ? '' : (now.endsWith('\n') ? '\n' : '\n\n'));
    note.documentText = '$now$gap$text';
    await repository.saveNote(note);
  }

  @override
  Future<void> insertTextAt(String text, {String? after, String? before, bool atStart = false}) async {
    // (a note with no written text yet has nothing to be at the start of: the text goes where text goes in it)
    if (atStart && (await _load()).documentText.trim().isEmpty) return insertText(text);
    final t = await _texts();
    insertNoteText(t.texts, text, after: after, before: before, atStart: atStart);
    await t.save();
  }

  @override
  Future<String> inspectText(String target) async {
    final t = await _texts();
    return describeNoteFormatting(t.texts, t.labels, target: target);
  }

  /// Replaces the whole written document with [text] (the formatting belonged to the old text).
  Future<void> setDocument(String text) async {
    final note = await _load();
    if (_hasNoDocument(note)) throw ExtensionError('This note has no written document (it is a PDF or an infinite canvas).');
    note.documentText = text;
    note.documentSpans = [];
    await repository.saveNote(note);
  }

  @override
  Future<int> replaceText(String find, String replacement, {bool all = false}) async {
    final t = await _texts();
    final n = replaceNoteText(t.texts, find, replacement, all: all);
    await t.save();
    return n;
  }

  @override
  Future<String> formatText(Map<String, Object?> options) async {
    final format = NoteFormat.fromJson(options);
    final t = await _texts();
    final out = formatNoteText(t.texts, format);
    await t.save();
    return out;
  }

  @override
  Future<void> setTitle(String title) => repository.renameNote(noteId, title);

  // ---- tracked changes, flashcards and the text of a PDF

  @override
  Future<int> resolveChanges({required bool accept}) async {
    final t = await _texts();
    var settled = 0;
    for (final text in t.texts) {
      final edits = decideChanges(text.text, accept: accept);
      if (edits.isEmpty) continue;
      text.replaceRanges(edits);
      settled += edits.length;
    }
    if (settled == 0) throw ExtensionError('The note has no tracked changes ({++put in++} or {--taken out--}).');
    await t.save();
    return settled;
  }

  @override
  Future<int> addCards(List<Map<String, String>> cards) async {
    final keep = _cards;
    if (keep == null) throw ExtensionError('Flashcards cannot be made here.');
    await _load();
    return keep.addAll(noteId, [for (final c in cards) Flashcard(c['front']!, c['back']!)]);
  }

  Future<List<String>> _pdfPages(String? id) async {
    if (id != null && id != noteId) throw ExtensionError('That is the PDF of another note: give that note.');
    final pages = await repository.text.pdfPages(noteId);
    return pages ?? (throw ExtensionError('There is no PDF to read in this note (it is not a PDF note, or the app has not read its text yet).'));
  }

  @override
  Future<String> readPdf({String? id, int? from, int? to}) async => readPdfPages(await _pdfPages(id), from: from, to: to);

  @override
  Future<List<Map<String, Object?>>> searchPdf(String query, {String? id}) async => searchPdfPages(await _pdfPages(id), query);

  // ---- pages

  static double _round(double v) => (v * 10).roundToDouble() / 10;

  static bool _hasWrittenDocument(NoteData n) => n.pdfPath == null && !n.pageFormat.isInfinite && n.documentText.trim().isNotEmpty;

  static bool _used(NoteData n, int i) =>
      (i == 0 && _hasWrittenDocument(n)) ||
      [n.strokes, n.textBoxes, n.images, n.highlights].any((m) => ((m[i] as List?) ?? const []).isNotEmpty);

  /// How many pages the note has, as the editor counts them: a PDF its own, a notebook the last that has something and one blank after.
  static int _pageCount(NoteData n) {
    if (n.pdfPath != null) return math.max(NoteHeld.of(n).pages, n.pdfPageCount ?? 1);
    var last = -1;
    for (final i in {0, ...n.strokes.keys, ...n.textBoxes.keys, ...n.images.keys, ...n.highlights.keys}) {
      if (i > last && _used(n, i)) last = i;
    }
    return last + 2;
  }

  /// The page number [page] (from 1) as an index.
  static int _index(NoteData n, int? page) {
    if (n.pageFormat.isInfinite && n.pdfPath == null) throw ExtensionError('This note is an infinite canvas: it has no pages.');
    if (page == null) return 0;
    final count = _pageCount(n);
    if (page < 1 || page > count) throw ExtensionError('There is no page $page: the note has $count pages.');
    return page - 1;
  }

  @override
  Future<List<Map<String, Object?>>> pages() async {
    final n = await _load();
    if (n.pageFormat.isInfinite && n.pdfPath == null) throw ExtensionError('This note is an infinite canvas: it has no pages.');
    final width = n.pageFormat.widthUnits(landscape: n.landscape);
    return [
      for (var i = 0; i < _pageCount(n); i++)
        {
          'page': i + 1,
          'kind': i == 0 && _hasWrittenDocument(n) ? 'written' : (n.pdfPath == null ? 'notebook' : 'pdf'),
          'strokes': (n.strokes[i] ?? const []).length,
          'textBoxes': (n.textBoxes[i] ?? const []).length,
          'images': (n.images[i] ?? const []).length,
          // (a PDF page has the size of the file's page: the editor knows it, the database does not)
          'width': n.pdfPath == null ? width.round() : null,
          'height': n.pdfPath == null ? (width * n.pageFormat.aspect(landscape: n.landscape)).round() : null,
        },
    ];
  }

  /// Gives everything on page `i` the page `to(i)` (null: it goes away), and the bookmarks with it. Only for a notebook: a PDF has to be
  /// rewritten for that, which the editor does.
  Future<void> _reshape(NoteData n, int? Function(int page) to) async {
    if (n.pdfPath != null) throw ExtensionError('The pages of a PDF can only be changed while the note is open in the app.');
    Map<int, List<T>> moved<T>(Map<int, List<T>> m) {
      final out = <int, List<T>>{};
      m.forEach((page, items) {
        final k = to(page);
        if (k != null) out.putIfAbsent(k, () => []).addAll(items);
      });
      return out;
    }

    n.strokes = moved(n.strokes);
    n.textBoxes = moved(n.textBoxes);
    n.images = moved(n.images);
    n.highlights = moved(n.highlights);
    await repository.saveNote(n);
    final marks = bookmarks;
    if (marks != null) await marks.replace(noteId, moveBookmarks(await marks.list(noteId), to));
  }

  @override
  Future<int> addPage({int? at}) async {
    final n = await _load();
    final count = _pageCount(n);
    _index(n, at == null ? null : math.min(at, count));
    if (at != null && at > count + 1) throw ExtensionError('There is no page $at: the note has $count pages.');
    // (a notebook always ends with a blank page: adding one at its end is having it)
    if (at == null) return count;
    final index = at - 1;
    if (index == 0 && _hasWrittenDocument(n)) throw ExtensionError('Page 1 holds the written document: add the page after it.');
    await _reshape(n, (i) => i >= index ? i + 1 : i);
    return at;
  }

  @override
  Future<void> deletePage(int page) async {
    final n = await _load();
    final index = _index(n, page);
    if (index == 0 && _hasWrittenDocument(n)) throw ExtensionError('Page $page holds the written document: it cannot be deleted. Take the text out instead.');
    await _reshape(n, (i) => i == index ? null : (i > index ? i - 1 : i));
  }

  @override
  Future<void> movePage(int page, int to) async {
    final n = await _load();
    final from = _index(n, page), target = _index(n, to);
    if (_hasWrittenDocument(n) && (from == 0 || target == 0)) throw ExtensionError('Page 1 holds the written document: it stays where it is.');
    if (from == target) return;
    await _reshape(n, (i) {
      if (i == from) return target;
      if (from < target && i > from && i <= target) return i - 1;
      if (from > target && i >= target && i < from) return i + 1;
      return i;
    });
  }

  @override
  Future<String> setupPage(Map<String, Object?> options) async {
    final n = await _load();
    if (n.pdfPath != null || n.pageFormat.isInfinite) throw ExtensionError('The paper of this note cannot be set up (it is a PDF or a canvas).');
    final said = <String>[];
    PageFormat? format;
    bool? landscape;
    PageBackground? background;
    final paper = options['paper'];
    if (paper != null) {
      format = PageFormat.papers.where((f) => f.name == '$paper'.toLowerCase().trim()).firstOrNull ??
          (throw ExtensionError('"paper" has to be one of: ${PageFormat.papers.map((f) => f.name).join(', ')}.'));
    }
    final orientation = options['orientation'];
    if (orientation != null) {
      if (orientation != 'portrait' && orientation != 'landscape') throw ExtensionError('"orientation" has to be portrait or landscape.');
      landscape = orientation == 'landscape';
    }
    final back = options['background'];
    if (back != null) {
      background = PageBackground.values.where((b) => b.name == '$back'.toLowerCase().trim()).firstOrNull ??
          (throw ExtensionError('"background" has to be one of: ${PageBackground.values.map((b) => b.name).join(', ')}.'));
    }
    final margins = options['margins'];
    final units = <String, double>{};
    if (margins != null) {
      if (margins is! Map) throw ExtensionError('"margins" has to be {left, right, top, bottom} in millimetres.');
      for (final entry in margins.entries) {
        final side = entry.key, mm = entry.value;
        if (!const ['left', 'right', 'top', 'bottom'].contains(side) || mm is! num || !mm.isFinite || mm < 0 || mm > 80) {
          throw ExtensionError('"margins" has to be {left, right, top, bottom}, each a number of millimetres from 0 to 80.');
        }
        units[side as String] = mm * PageFormat.a4Units / 210;
      }
    }
    if (format == null && landscape == null && background == null && units.isEmpty) throw ExtensionError('Say at least one of "paper", "orientation", "background" and "margins".');
    if (format != null) n.pageFormat = format;
    if (landscape != null) n.landscape = landscape;
    if (background != null) n.background = background;
    if (units['left'] != null) n.marginLeft = units['left']!;
    if (units['right'] != null) n.marginRight = units['right']!;
    if (units['top'] != null) n.marginTop = units['top']!;
    if (units['bottom'] != null) n.marginBottom = units['bottom']!;
    await repository.saveNote(n);
    if (format != null) said.add('paper ${format.label}');
    if (landscape != null) said.add(landscape ? 'landscape' : 'portrait');
    if (background != null) said.add('${background.label} paper');
    if (units.isNotEmpty) said.add('margins');
    return said.join(', ');
  }

  // ---- text boxes, pictures and drawing

  @override
  Future<List<Map<String, Object?>>> textBoxes() async {
    final n = await _load();
    return [
      for (final page in n.textBoxes.keys.toList()..sort())
        for (final b in n.textBoxes[page]!)
          {
            'id': b.id,
            'page': page + 1,
            'x': _round(b.position.dx),
            'y': _round(b.position.dy),
            'width': _round(b.size.width),
            'text': b.controller.text.length > 200 ? '${b.controller.text.substring(0, 200)}...' : b.controller.text,
          },
    ];
  }

  @override
  Future<String> addTextBox(String text, {int? page, double? x, double? y, double? width}) async {
    final n = await _load();
    if (!n.layers.byId(baseLayerId).editable) throw ExtensionError('The layer in use is hidden or locked: nothing can be added to it.');
    final index = n.pageFormat.isInfinite && n.pdfPath == null ? 0 : _index(n, page);
    final id = 'mcp-${NoteRepository.newId()}';
    final box = TextBoxWidgetModel(id: id, position: Offset(x ?? 40, y ?? 40), size: Size(width ?? 260, 0), initialText: text, fontSize: 14);
    await repository.putTextBox(noteId, index, box);
    return id;
  }

  TextBoxWidgetModel _boxOf(NoteData n, String id) {
    for (final boxes in n.textBoxes.values) {
      for (final b in boxes) {
        if (b.id == id) return b;
      }
    }
    throw ExtensionError('There is no text box with the id "$id". textBoxes.list has the ids.');
  }

  @override
  Future<void> moveTextBox(String id, {int? page, double? x, double? y, double? width}) async {
    final n = await _load();
    final box = _boxOf(n, id);
    final to = page == null ? null : _index(n, page);
    if (width != null) box.size = Size(width, box.size.height);
    box.position = Offset(math.max(0, x ?? box.position.dx), math.max(0, y ?? box.position.dy));
    if (to != null) {
      for (final boxes in n.textBoxes.values) {
        boxes.remove(box);
      }
      n.textBoxes.putIfAbsent(to, () => []).add(box);
    }
    await repository.saveNote(n);
  }

  @override
  Future<void> deleteTextBox(String id) async {
    final n = await _load();
    final box = _boxOf(n, id);
    for (final boxes in n.textBoxes.values) {
      boxes.remove(box);
    }
    await repository.saveNote(n);
  }

  ({int page, ImageItem image}) _imageOf(NoteData n, String id) {
    for (final entry in n.images.entries) {
      for (final m in entry.value) {
        if (m.id == id) return (page: entry.key, image: m);
      }
    }
    throw ExtensionError('There is no picture with the id "$id". images.list has the ids.');
  }

  @override
  Future<List<Map<String, Object?>>> images() async {
    final n = await _load();
    return [
      for (final page in n.images.keys.toList()..sort())
        for (final m in n.images[page]!)
          {'id': m.id, 'page': page + 1, 'x': _round(m.position.dx), 'y': _round(m.position.dy), 'width': _round(m.size.width), 'height': _round(m.size.height)},
    ];
  }

  @override
  Future<void> moveImage(String id, {int? page, double? x, double? y, double? width}) async {
    final n = await _load();
    final found = _imageOf(n, id);
    final to = page == null ? null : _index(n, page);
    final m = found.image;
    if (width != null) {
      final w = math.max(40.0, width);
      m.size = Size(w, w / m.aspect);
    }
    m.position = Offset(math.max(0, x ?? m.position.dx), math.max(0, y ?? m.position.dy));
    if (to != null && to != found.page) {
      n.images[found.page]?.remove(m);
      n.images.putIfAbsent(to, () => []).add(m);
    }
    await repository.saveNote(n);
  }

  @override
  Future<void> deleteImage(String id) async {
    final n = await _load();
    final found = _imageOf(n, id);
    n.images[found.page]?.remove(found.image);
    await repository.saveNote(n);
  }

  @override
  Future<int> drawStrokes(List<Map<String, Object?>> strokes, {int? page}) async {
    final n = await _load();
    if (!n.layers.byId(baseLayerId).editable) throw ExtensionError('The layer in use is hidden or locked: nothing can be drawn on it.');
    final index = n.pageFormat.isInfinite && n.pdfPath == null ? 0 : _index(n, page);
    final drawn = parseDrawnStrokes(strokes, color: const Color(0xFF000000), width: 2);
    for (final s in drawn) {
      s.author = Authorship.current;
    }
    if (drawn.isEmpty) return 0;
    n.strokes.putIfAbsent(index, () => []).addAll(drawn);
    await repository.saveNote(n);
    return drawn.length;
  }
}

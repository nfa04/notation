import 'dart:typed_data';
import 'dart:ui';

import '../data/note_pdfs.dart';
import 'pdf_content_editor.dart';

/// Edits what the PDF of a note really contains, by the number of the page in the note: for a note with one PDF that is the file's page,
/// for one with several PDFs the page of the file the page table says. Each file is opened the first time one of its pages is asked for,
/// and is saved on its own: a file nobody edited stays as it was.
class NotePdfEditor {
  final NotePdfs? _table;
  final Future<PdfContentEditor> Function(int file) _open;
  final _editors = <int, Future<PdfContentEditor>>{};
  final _touched = <int>{};

  NotePdfEditor._(this._table, this._open);

  /// Edits the one PDF [editor] has open.
  factory NotePdfEditor.single(PdfContentEditor editor) => NotePdfEditor._(null, (_) async => editor);

  /// Edits the files of [table]: [open] gives the editor of file number `f` (called at most once for each).
  factory NotePdfEditor.table(NotePdfs table, Future<PdfContentEditor> Function(int file) open) => NotePdfEditor._(table, open);

  /// The file page [page] of the note is in (null for a blank page, which has nothing to edit), and which page of it.
  (int file, int page)? where(int page) {
    final table = _table;
    if (table == null) return (0, page);
    if (page < 0 || page >= table.layout.length) return null;
    final ref = table.layout[page];
    return ref.isBlank ? null : (ref.file, ref.page);
  }

  /// The number of the file page [page] is in.
  int? fileOf(int page) => where(page)?.$1;

  /// The files an edit was made in.
  Set<int> get touched => Set.of(_touched);

  Future<PdfContentEditor> _editor(int file) => _editors.putIfAbsent(file, () => _open(file));

  Future<T> _at<T>(int page, T ifBlank, Future<T> Function(PdfContentEditor editor, int page) call, {bool edits = false}) async {
    final at = where(page);
    if (at == null) return ifBlank;
    final editor = await _editor(at.$1);
    if (edits) _touched.add(at.$1);
    return call(editor, at.$2);
  }

  Future<Size> pageSize(int page) => _at(page, Size.zero, (e, p) => e.pageSize(p));

  Future<List<PdfEditObject>> objects(int page) => _at(page, const <PdfEditObject>[], (e, p) => e.objects(p));

  Future<PdfFontInfo> fontInfo(int page, PdfEditObject line) => _at(page, const PdfFontInfo(name: ''), (e, p) => e.fontInfo(p, line));

  Future<void> setText(int page, PdfEditObject line, String text, {String? family, double sizeFactor = 1, bool uniform = false}) =>
      _at(page, null, (e, p) => e.setText(p, line, text, family: family, sizeFactor: sizeFactor, uniform: uniform), edits: true);

  Future<void> removeObject(int page, PdfEditObject object) => _at(page, null, (e, p) => e.removeObject(p, object), edits: true);

  Future<void> moveObject(int page, PdfEditObject object, Offset delta) => _at(page, null, (e, p) => e.moveObject(p, object, delta), edits: true);

  Future<void> resizeObject(int page, PdfEditObject object, Rect to) => _at(page, null, (e, p) => e.resizeObject(p, object, to), edits: true);

  Future<void> rotateObject(int page, PdfEditObject object, double degrees) => _at(page, null, (e, p) => e.rotateObject(p, object, degrees), edits: true);

  Future<void> formatText(int page, PdfEditObject line, {int? color, bool? bold, bool? italic, bool? underline, bool? strikethrough}) =>
      _at(page, null, (e, p) => e.formatText(p, line, color: color, bold: bold, italic: italic, underline: underline, strikethrough: strikethrough), edits: true);

  /// File number [file] as edited.
  Future<Uint8List> save(int file) async => (await _editor(file)).save();

  Future<void> close() async {
    final open = _editors.values.toList();
    _editors.clear();
    for (final e in open) {
      try {
        await (await e).close();
      } catch (_) {
        // (an editor that never opened has nothing to close)
      }
    }
  }
}

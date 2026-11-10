import 'dart:typed_data';
import 'dart:ui';

import 'package:pdfrx/pdfrx.dart' show PdfrxEntryFunctions;

import 'pdf_edit_session.dart';
import 'pdf_edit_types.dart';
import 'pdfium_backend_ffi.dart';

const pdfContentEditingSupported = true;

// ---- on the PDFium worker isolate
//
// PDFium is not thread-safe and pdfrx hands it callbacks of its own isolate (for fonts), so it may only be called from the
// isolate pdfrx uses for it. [PdfContentEditor] sends each call there; the sessions live there.

final _sessions = <int, PdfEditSession>{};
var _nextSession = 0;

typedef _Call = (int session, String op, List<Object?> args);

/// What a call on the worker gives back: the value, or what went wrong.
typedef _Answer = (Object? value, String? error);

_Answer _run(_Call call) {
  final (id, op, args) = call;
  try {
    if (op == 'open') {
      final session = PdfEditSession.open(FfiPdfiumBackend(modulePath: args[1] as String?), args[0]! as Uint8List, fallbackFonts: (args[2]! as Map).cast<String, Uint8List>());
      _sessions[++_nextSession] = session;
      return (_nextSession, null);
    }
    final s = _sessions[id];
    if (s == null) return (null, 'The PDF is no longer open for editing.');
    switch (op) {
      case 'pageSize':
        return (s.pageSize(args[0]! as int), null);
      case 'objects':
        return (s.objects(args[0]! as int), null);
      case 'setText':
        s.setText(args[0]! as int, args[1]! as PdfEditObject, args[2]! as String, family: args[3] as String?, sizeFactor: args[4]! as double, uniform: args[5]! as bool);
      case 'remove':
        s.removeObject(args[0]! as int, args[1]! as PdfEditObject);
      case 'move':
        s.moveObject(args[0]! as int, args[1]! as PdfEditObject, args[2]! as Offset);
      case 'resize':
        s.resizeObject(args[0]! as int, args[1]! as PdfEditObject, args[2]! as Rect);
      case 'rotate':
        s.rotateObject(args[0]! as int, args[1]! as PdfEditObject, args[2]! as double);
      case 'format':
        final a = args[2]! as Map;
        s.formatText(args[0]! as int, args[1]! as PdfEditObject,
            color: a['color'] as int?, bold: a['bold'] as bool?, italic: a['italic'] as bool?, underline: a['underline'] as bool?, strikethrough: a['strike'] as bool?);
      case 'font':
        return (s.fontInfo(args[0]! as int, args[1]! as PdfEditObject), null);
      case 'arrange':
        s.arrange((args[0]! as List).cast<int?>(), args[1]! as Size);
      case 'save':
        return (s.save(), null);
      case 'close':
        _sessions.remove(id)?.close();
    }
    return (null, null);
  } on PdfEditException catch (e) {
    return (null, e.message);
  } catch (e) {
    return (null, 'PDF editing failed: $e');
  }
}

/// Edits what an imported PDF really contains (its text, pictures and shapes) through PDFium's page objects, unlike the overlay
/// the editor draws on top of a page. The edited file is written whole by [save]. [close] when done.
///
/// Page objects are known by their place on the page, which changes when one is removed: ask for [objects] again after an edit.
class PdfContentEditor {
  final int _id;
  PdfContentEditor._(this._id);

  /// Opens [bytes]; [modulePath] points at PDFium when it is not where the app bundles it, [fallbackFonts] are TrueType fonts
  /// by [PdfFontInfo.key] to set text in when the PDF's own font lacks the characters. Throws a [PdfEditException] for a PDF that is damaged or
  /// needs a password.
  static Future<PdfContentEditor> open(Uint8List bytes, {String? modulePath, Map<String, Uint8List> fallbackFonts = const {}}) async =>
      PdfContentEditor._(await _send(0, 'open', [bytes, modulePath, fallbackFonts]) as int);

  static Future<Object?> _send(int id, String op, [List<Object?> args = const []]) async {
    final (value, error) = await PdfrxEntryFunctions.instance.compute<_Call, _Answer>(_run, (id, op, args));
    if (error != null) throw PdfEditException(error);
    return value;
  }

  /// Size of page [pageIndex] as shown, in points.
  Future<Size> pageSize(int pageIndex) async => await _send(_id, 'pageSize', [pageIndex]) as Size;

  /// What can be edited on page [pageIndex], bottom-most first. Text nobody can see (the hidden layer of a scan that was run
  /// through text recognition) is left out, and text drawn piece by piece is made into lines.
  Future<List<PdfEditObject>> objects(int pageIndex) async => (await _send(_id, 'objects', [pageIndex]) as List).cast<PdfEditObject>();

  /// Puts [text] in place of the text of [line]. It stays in the PDF's own font when that can show the new text; otherwise it
  /// is set again in a stand-in font that can: [family] ("sans", "serif", "mono") says which, [sizeFactor] how much bigger.
  Future<void> setText(int pageIndex, PdfEditObject line, String text, {String? family, double sizeFactor = 1, bool uniform = false}) =>
      _send(_id, 'setText', [pageIndex, line, text, family, sizeFactor, uniform]);

  Future<void> removeObject(int pageIndex, PdfEditObject object) => _send(_id, 'remove', [pageIndex, object]);

  /// Moves [object] by [delta] points on the page as shown.
  Future<void> moveObject(int pageIndex, PdfEditObject object, Offset delta) => _send(_id, 'move', [pageIndex, object, delta]);

  /// Fits [object] to [to], a rectangle of the page as shown (see [PdfEditObject.rect] for where it is now).
  Future<void> resizeObject(int pageIndex, PdfEditObject object, Rect to) => _send(_id, 'resize', [pageIndex, object, to]);

  /// Turns [object] by [degrees] clockwise about the middle of its box.
  Future<void> rotateObject(int pageIndex, PdfEditObject object, double degrees) => _send(_id, 'rotate', [pageIndex, object, degrees]);

  /// Changes how [line] looks: colour (0xAARRGGBB), bold, italic, underline, strikethrough; what is null stays.
  Future<void> formatText(int pageIndex, PdfEditObject line, {int? color, bool? bold, bool? italic, bool? underline, bool? strikethrough}) =>
      _send(_id, 'format', [pageIndex, line, {'color': color, 'bold': bold, 'italic': italic, 'underline': underline, 'strike': strikethrough}]);

  /// The font [line] is set in.
  Future<PdfFontInfo> fontInfo(int pageIndex, PdfEditObject line) async => await _send(_id, 'font', [pageIndex, line]) as PdfFontInfo;

  /// Gives the PDF the pages [order] says: each the number of a page it has (at most once; the others are deleted), or null for a
  /// new blank page of [blank] points.
  Future<void> arrange(List<int?> order, Size blank) => _send(_id, 'arrange', [order, blank]);

  /// The edited PDF.
  Future<Uint8List> save() async => await _send(_id, 'save') as Uint8List;

  Future<void> close() => _send(_id, 'close');
}

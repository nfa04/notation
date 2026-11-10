import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'pdf_edit_session.dart';
import 'pdf_edit_types.dart';
import 'pdfium_backend_web.dart';

const pdfContentEditingSupported = true;

/// Edits what an imported PDF really contains (its text, pictures and shapes) through PDFium's page objects, unlike the overlay
/// the editor draws on top of a page. The edited file is written whole by [save]. [close] when done.
///
/// In the browser PDFium runs on the page itself (see [WebPdfiumBackend]), so each call is done there and then; the methods are
/// asynchronous only to be the same as the ones of the apps.
///
/// Page objects are known by their place on the page, which changes when one is removed: ask for [objects] again after an edit.
class PdfContentEditor {
  final PdfEditSession _session;
  PdfContentEditor._(this._session);

  /// Opens [bytes]; [modulePath] is not used here (the PDFium of the page is the one the app ships), [fallbackFonts] are TrueType
  /// fonts by [PdfFontInfo.key] to set text in when the PDF's own font lacks the characters. Throws a [PdfEditException] for a PDF
  /// that is damaged or needs a password.
  static Future<PdfContentEditor> open(Uint8List bytes, {String? modulePath, Map<String, Uint8List> fallbackFonts = const {}}) async {
    final backend = await _guard(WebPdfiumBackend.create);
    return PdfContentEditor._(await _guard(() async => PdfEditSession.open(backend, bytes, fallbackFonts: fallbackFonts)));
  }

  static Future<T> _guard<T>(FutureOr<T> Function() body) async {
    try {
      return await body();
    } on PdfEditException {
      rethrow;
    } catch (e) {
      throw PdfEditException('PDF editing failed: $e');
    }
  }

  Future<T> _run<T>(T Function(PdfEditSession s) body) => _guard(() => body(_session));

  /// Size of page [pageIndex] as shown, in points.
  Future<Size> pageSize(int pageIndex) => _run((s) => s.pageSize(pageIndex));

  /// What can be edited on page [pageIndex], bottom-most first. Text nobody can see (the hidden layer of a scan that was run
  /// through text recognition) is left out, and text drawn piece by piece is made into lines.
  Future<List<PdfEditObject>> objects(int pageIndex) => _run((s) => s.objects(pageIndex));

  /// Puts [text] in place of the text of [line]. It stays in the PDF's own font when that can show the new text; otherwise it
  /// is set again in a stand-in font that can: [family] ("sans", "serif", "mono") says which, [sizeFactor] how much bigger.
  Future<void> setText(int pageIndex, PdfEditObject line, String text, {String? family, double sizeFactor = 1, bool uniform = false}) =>
      _run((s) => s.setText(pageIndex, line, text, family: family, sizeFactor: sizeFactor, uniform: uniform));

  Future<void> removeObject(int pageIndex, PdfEditObject object) => _run((s) => s.removeObject(pageIndex, object));

  /// Moves [object] by [delta] points on the page as shown.
  Future<void> moveObject(int pageIndex, PdfEditObject object, Offset delta) => _run((s) => s.moveObject(pageIndex, object, delta));

  /// Fits [object] to [to], a rectangle of the page as shown (see [PdfEditObject.rect] for where it is now).
  Future<void> resizeObject(int pageIndex, PdfEditObject object, Rect to) => _run((s) => s.resizeObject(pageIndex, object, to));

  /// Turns [object] by [degrees] clockwise about the middle of its box.
  Future<void> rotateObject(int pageIndex, PdfEditObject object, double degrees) => _run((s) => s.rotateObject(pageIndex, object, degrees));

  /// Changes how [line] looks: colour (0xAARRGGBB), bold, italic, underline, strikethrough; what is null stays.
  Future<void> formatText(int pageIndex, PdfEditObject line, {int? color, bool? bold, bool? italic, bool? underline, bool? strikethrough}) =>
      _run((s) => s.formatText(pageIndex, line, color: color, bold: bold, italic: italic, underline: underline, strikethrough: strikethrough));

  /// The font [line] is set in.
  Future<PdfFontInfo> fontInfo(int pageIndex, PdfEditObject line) => _run((s) => s.fontInfo(pageIndex, line));

  /// Gives the PDF the pages [order] says: each the number of a page it has (at most once; the others are deleted), or null for a
  /// new blank page of [blank] points.
  Future<void> arrange(List<int?> order, Size blank) => _run((s) => s.arrange(order, blank));

  /// The edited PDF.
  Future<Uint8List> save() => _run((s) => s.save());

  Future<void> close() => _run((s) => s.close());
}

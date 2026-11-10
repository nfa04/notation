import 'dart:typed_data';
import 'dart:ui';

import 'pdf_edit_types.dart';

const pdfContentEditingSupported = false;

/// Placeholder where PDFium cannot be reached: [open] always throws.
class PdfContentEditor {
  PdfContentEditor._();

  static Future<PdfContentEditor> open(Uint8List bytes, {String? modulePath, Map<String, Uint8List> fallbackFonts = const {}}) =>
      Future.error(const PdfEditException('Editing a PDF is not available on this platform.'));

  Future<Size> pageSize(int pageIndex) async => Size.zero;
  Future<List<PdfEditObject>> objects(int pageIndex) async => const [];
  Future<void> setText(int pageIndex, PdfEditObject line, String text, {String? family, double sizeFactor = 1, bool uniform = false}) async {}
  Future<void> removeObject(int pageIndex, PdfEditObject object) async {}
  Future<void> moveObject(int pageIndex, PdfEditObject object, Offset delta) async {}
  Future<void> rotateObject(int pageIndex, PdfEditObject object, double degrees) async {}
  Future<void> resizeObject(int pageIndex, PdfEditObject object, Rect to) async {}
  Future<void> formatText(int pageIndex, PdfEditObject line, {int? color, bool? bold, bool? italic, bool? underline, bool? strikethrough}) async {}
  Future<PdfFontInfo> fontInfo(int pageIndex, PdfEditObject line) async => const PdfFontInfo(name: '');
  Future<void> arrange(List<int?> order, Size blank) async {}
  Future<Uint8List> save() async => Uint8List(0);
  Future<void> close() async {}
}

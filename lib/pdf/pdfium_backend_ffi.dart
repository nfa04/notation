import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

import 'pdfium_backend.dart';

/// [PdfiumBackend] on the PDFium the app bundles, through `dart:ffi`. Only to be used on the isolate pdfrx uses for PDFium.
class FfiPdfiumBackend implements PdfiumBackend {
  final PDFium _p;

  /// [modulePath] points at PDFium when it is not where the app bundles it.
  FfiPdfiumBackend({String? modulePath}) : _p = getPdfium(modulePath: modulePath ?? Pdfrx.pdfiumModulePath) {
    _p.FPDF_InitLibrary();
  }

  // what the backend keeps for a document until it is closed: its file, and the fonts loaded into it
  final _documentData = <int, ffi.Pointer<ffi.Uint8>>{};
  final _fontData = <ffi.Pointer<ffi.Uint8>>[];
  var _passwordNeeded = false;

  FPDF_DOCUMENT _d(int h) => ffi.Pointer.fromAddress(h);
  FPDF_PAGE _pg(int h) => ffi.Pointer.fromAddress(h);
  FPDF_PAGEOBJECT _o(int h) => ffi.Pointer.fromAddress(h);
  FPDF_TEXTPAGE _t(int h) => ffi.Pointer.fromAddress(h);
  FPDF_FONT _f(int h) => ffi.Pointer.fromAddress(h);

  @override
  int loadDocument(Uint8List bytes) {
    final buffer = malloc<ffi.Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    final doc = _p.FPDF_LoadMemDocument(buffer.cast(), bytes.length, ffi.nullptr);
    if (doc.address == 0) {
      malloc.free(buffer);
      _passwordNeeded = _p.FPDF_GetLastError() == FPDF_ERR_PASSWORD;
      return 0;
    }
    _documentData[doc.address] = buffer;
    return doc.address;
  }

  @override
  bool get lastLoadNeededPassword => _passwordNeeded;

  @override
  void closeDocument(int doc) {
    _p.FPDF_CloseDocument(_d(doc));
    final buffer = _documentData.remove(doc);
    if (buffer != null) malloc.free(buffer);
    for (final data in _fontData) {
      malloc.free(data);
    }
    _fontData.clear();
  }

  @override
  int pageCount(int doc) => _p.FPDF_GetPageCount(_d(doc));
  @override
  int loadPage(int doc, int index) => _p.FPDF_LoadPage(_d(doc), index).address;
  @override
  void closePage(int page) => _p.FPDF_ClosePage(_pg(page));
  @override
  double pageWidth(int page) => _p.FPDF_GetPageWidthF(_pg(page));
  @override
  double pageHeight(int page) => _p.FPDF_GetPageHeightF(_pg(page));
  @override
  int loadTextPage(int page) => _p.FPDFText_LoadPage(_pg(page)).address;
  @override
  void closeTextPage(int textPage) => _p.FPDFText_ClosePage(_t(textPage));
  @override
  void deletePage(int doc, int index) => _p.FPDFPage_Delete(_d(doc), index);

  @override
  bool movePagesToFront(int doc, List<int> indices) {
    final buffer = malloc<ffi.Int>(indices.length);
    try {
      for (var n = 0; n < indices.length; n++) {
        buffer[n] = indices[n];
      }
      return _p.FPDF_MovePages(_d(doc), buffer, indices.length, 0) != 0;
    } finally {
      malloc.free(buffer);
    }
  }

  @override
  int newPage(int doc, int index, double width, double height) => _p.FPDFPage_New(_d(doc), index, width, height).address;

  @override
  Uint8List? save(int doc) {
    final out = BytesBuilder(copy: false);
    final callable = ffi.NativeCallable<ffi.Int Function(ffi.Pointer<FPDF_FILEWRITE_>, ffi.Pointer<ffi.Void>, ffi.UnsignedLong)>.isolateLocal(
      (ffi.Pointer<FPDF_FILEWRITE_> self, ffi.Pointer<ffi.Void> data, int size) {
        out.add(Uint8List.fromList(data.cast<ffi.Uint8>().asTypedList(size)));
        return 1;
      },
      exceptionalReturn: 0,
    );
    final writer = malloc<FPDF_FILEWRITE_>();
    try {
      writer.ref
        ..version = 1
        ..WriteBlock = callable.nativeFunction;
      if (_p.FPDF_SaveAsCopy(_d(doc), writer, 0) == 0) return null;
    } finally {
      malloc.free(writer);
      callable.close();
    }
    return out.takeBytes();
  }

  @override
  (int, int) pageToDevice(int page, int width, int height, double x, double y) {
    final dx = malloc<ffi.Int>(2);
    try {
      _p.FPDF_PageToDevice(_pg(page), 0, 0, width, height, 0, x, y, dx, dx + 1);
      return (dx[0], dx[1]);
    } finally {
      malloc.free(dx);
    }
  }

  @override
  (double, double) deviceToPage(int page, int width, int height, int x, int y) {
    final px = malloc<ffi.Double>(2);
    try {
      _p.FPDF_DeviceToPage(_pg(page), 0, 0, width, height, 0, x, y, px, px + 1);
      return (px[0], px[1]);
    } finally {
      malloc.free(px);
    }
  }

  @override
  int countObjects(int page) => _p.FPDFPage_CountObjects(_pg(page));
  @override
  int getObject(int page, int index) => _p.FPDFPage_GetObject(_pg(page), index).address;
  @override
  int objectType(int object) => _p.FPDFPageObj_GetType(_o(object));

  @override
  List<double>? bounds(int object) {
    final f = malloc<ffi.Float>(4);
    try {
      if (_p.FPDFPageObj_GetBounds(_o(object), f, f + 1, f + 2, f + 3) == 0) return null;
      return [f[0], f[1], f[2], f[3]];
    } finally {
      malloc.free(f);
    }
  }

  @override
  List<double>? matrix(int object) {
    final m = malloc<FS_MATRIX>();
    try {
      if (_p.FPDFPageObj_GetMatrix(_o(object), m) == 0) return null;
      return [m.ref.a, m.ref.b, m.ref.c, m.ref.d, m.ref.e, m.ref.f];
    } finally {
      malloc.free(m);
    }
  }

  @override
  bool setMatrix(int object, List<double> v) {
    final m = malloc<FS_MATRIX>();
    try {
      m.ref
        ..a = v[0]
        ..b = v[1]
        ..c = v[2]
        ..d = v[3]
        ..e = v[4]
        ..f = v[5];
      return _p.FPDFPageObj_SetMatrix(_o(object), m) != 0;
    } finally {
      malloc.free(m);
    }
  }

  @override
  void transform(int object, double a, double b, double c, double d, double e, double f) => _p.FPDFPageObj_Transform(_o(object), a, b, c, d, e, f);

  @override
  int? fillColor(int object) {
    final rgba = malloc<ffi.UnsignedInt>(4);
    try {
      if (_p.FPDFPageObj_GetFillColor(_o(object), rgba, rgba + 1, rgba + 2, rgba + 3) == 0) return null;
      return (rgba[3] & 0xFF) << 24 | (rgba[0] & 0xFF) << 16 | (rgba[1] & 0xFF) << 8 | (rgba[2] & 0xFF);
    } finally {
      malloc.free(rgba);
    }
  }

  @override
  void setFillColor(int object, int argb) => _p.FPDFPageObj_SetFillColor(_o(object), (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF);

  @override
  void insertObject(int page, int object) => _p.FPDFPage_InsertObject(_pg(page), _o(object));
  @override
  void insertObjectAt(int page, int object, int index) => _p.FPDFPage_InsertObjectAtIndex(_pg(page), _o(object), index);
  @override
  bool removeObject(int page, int object) => _p.FPDFPage_RemoveObject(_pg(page), _o(object)) != 0;
  @override
  void destroyObject(int object) => _p.FPDFPageObj_Destroy(_o(object));
  @override
  void generateContent(int page) => _p.FPDFPage_GenerateContent(_pg(page));

  @override
  bool isInvisibleText(int object) => _p.FPDFTextObj_GetTextRenderMode(_o(object)) == FPDF_TEXT_RENDERMODE.FPDF_TEXTRENDERMODE_INVISIBLE;

  @override
  String textOf(int object, int textPage) {
    final bytes = _p.FPDFTextObj_GetText(_o(object), _t(textPage), ffi.nullptr, 0); // (with the terminating zero)
    if (bytes <= 2) return '';
    final buffer = malloc<ffi.Uint16>(bytes ~/ 2);
    try {
      _p.FPDFTextObj_GetText(_o(object), _t(textPage), buffer.cast(), bytes);
      return String.fromCharCodes(buffer.asTypedList(bytes ~/ 2 - 1));
    } finally {
      malloc.free(buffer);
    }
  }

  @override
  double? fontSize(int object) {
    final size = malloc<ffi.Float>();
    try {
      return _p.FPDFTextObj_GetFontSize(_o(object), size) == 0 ? null : size.value;
    } finally {
      malloc.free(size);
    }
  }

  @override
  int fontOf(int object) => _p.FPDFTextObj_GetFont(_o(object)).address;

  @override
  String fontName(int font) {
    final length = _p.FPDFFont_GetBaseFontName(_f(font), ffi.nullptr, 0);
    if (length <= 1) return '';
    final buffer = malloc<ffi.Char>(length);
    try {
      _p.FPDFFont_GetBaseFontName(_f(font), buffer, length);
      return utf8.decode(buffer.cast<ffi.Uint8>().asTypedList(length - 1), allowMalformed: true);
    } finally {
      malloc.free(buffer);
    }
  }

  @override
  bool fontIsEmbedded(int font) => _p.FPDFFont_GetIsEmbedded(_f(font)) != 0;
  @override
  int fontFlags(int font) => _p.FPDFFont_GetFlags(_f(font));
  @override
  int fontWeight(int font) => _p.FPDFFont_GetWeight(_f(font));

  @override
  int countChars(int textPage) => _p.FPDFText_CountChars(_t(textPage));
  @override
  int charObject(int textPage, int index) => _p.FPDFText_GetTextObject(_t(textPage), index).address;
  @override
  int charUnicode(int textPage, int index) => _p.FPDFText_GetUnicode(_t(textPage), index);

  @override
  List<double>? charBox(int textPage, int index) {
    final box = malloc<ffi.Double>(4);
    try {
      if (_p.FPDFText_GetCharBox(_t(textPage), index, box, box + 1, box + 2, box + 3) == 0) return null;
      return [box[0], box[1], box[2], box[3]];
    } finally {
      malloc.free(box);
    }
  }

  @override
  bool setText(int object, String text) {
    final units = text.codeUnits;
    final buffer = malloc<ffi.Uint16>(units.length + 1);
    try {
      buffer.asTypedList(units.length + 1)
        ..setAll(0, units)
        ..[units.length] = 0;
      return _p.FPDFText_SetText(_o(object), buffer.cast()) != 0;
    } finally {
      malloc.free(buffer);
    }
  }

  @override
  bool setCharcodes(int object, List<int> codes) {
    final buffer = malloc<ffi.Uint32>(codes.length);
    try {
      buffer.asTypedList(codes.length).setAll(0, codes);
      return _p.FPDFText_SetCharcodes(_o(object), buffer, codes.length) != 0;
    } finally {
      malloc.free(buffer);
    }
  }

  @override
  int createTextObject(int doc, int font, double size) => _p.FPDFPageObj_CreateTextObj(_d(doc), _f(font), size).address;

  @override
  int createFilledRect(double x, double y, double width, double height, int argb) {
    final object = _p.FPDFPageObj_CreateNewRect(x, y, width, height);
    setFillColor(object.address, argb);
    _p.FPDFPath_SetDrawMode(object, FPDF_FILLMODE_ALTERNATE, 0);
    return object.address;
  }

  @override
  int loadTrueTypeFont(int doc, Uint8List bytes) {
    final data = malloc<ffi.Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final font = _p.FPDFText_LoadFont(_d(doc), data, bytes.length, FPDF_FONT_TRUETYPE, 1);
    if (font.address == 0) {
      malloc.free(data);
      return 0;
    }
    _fontData.add(data); // (PDFium reads the font from here when the PDF is saved)
    return font.address;
  }

  @override
  int loadStandardFont(int doc, String name) {
    final c = name.toNativeUtf8();
    try {
      return _p.FPDFText_LoadStandardFont(_d(doc), c.cast()).address;
    } finally {
      malloc.free(c);
    }
  }

  @override
  void closeFont(int font) => _p.FPDFFont_Close(_f(font));
}

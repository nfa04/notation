import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'pdfium_backend.dart';

@JS('pdfiumSyncLoad')
external JSPromise<JSObject> _pdfiumSyncLoad(JSString workerScript, JSUint8Array wasmBytes);

/// [PdfiumBackend] on PDFium compiled to WebAssembly, run on the page itself (web/pdfium_sync.js loads it): the module pdfrx
/// ships, but not through pdfrx's worker, which does not let the page call PDFium's page-object functions.
class WebPdfiumBackend implements PdfiumBackend {
  final JSObject _exports;
  final JSObject _loader;
  final JSObject _memory;

  WebPdfiumBackend._(this._loader)
      : _exports = _loader.getProperty<JSObject>('exports'.toJS),
        _memory = _loader.getProperty<JSObject>('exports'.toJS).getProperty<JSObject>('memory'.toJS);

  static Future<WebPdfiumBackend>? _shared;

  /// The backend (one PDFium for the whole app: it is loaded the first time).
  static Future<WebPdfiumBackend> create() => _shared ??= _load().onError((e, s) {
        _shared = null;
        throw e!;
      });

  static Future<WebPdfiumBackend> _load() async {
    final script = await rootBundle.loadString('packages/pdfrx/assets/pdfium_worker.js');
    final wasm = (await rootBundle.load('packages/pdfrx/assets/pdfium.wasm')).buffer.asUint8List();
    return WebPdfiumBackend._(await _pdfiumSyncLoad(script.toJS, wasm.toJS).toDart);
  }

  // ---- calling PDFium and reading its memory

  num _c(String name, [List<num> args = const []]) {
    final r = _exports.callMethodVarArgs<JSAny?>(name.toJS, [for (final a in args) a.toJS]);
    return r == null ? 0 : (r as JSNumber).toDartDouble;
  }

  int _i(String name, [List<num> args = const []]) => _c(name, args).toInt();

  /// The module's memory as it is now (it may move when it grows: never kept).
  ByteData get _mem => (_memory.getProperty<JSArrayBuffer>('buffer'.toJS)).toDart.asByteData();
  Uint8List _bytes(int at, int length) => (_memory.getProperty<JSArrayBuffer>('buffer'.toJS)).toDart.asUint8List(at, length);

  int _alloc(int bytes) {
    final p = _i('malloc', [bytes < 1 ? 1 : bytes]);
    if (p == 0) throw StateError('PDFium is out of memory');
    return p;
  }

  void _free(int p) => _c('free', [p]);

  /// Runs [body] with [bytes] bytes of memory, freed after.
  T _with<T>(int bytes, T Function(int p) body) {
    final p = _alloc(bytes);
    try {
      return body(p);
    } finally {
      _free(p);
    }
  }

  double _f32(int at) => _mem.getFloat32(at, Endian.little);
  double _f64(int at) => _mem.getFloat64(at, Endian.little);
  int _i32(int at) => _mem.getInt32(at, Endian.little);
  int _u32(int at) => _mem.getUint32(at, Endian.little);

  // what the backend keeps for a document until it is closed: its file, and the fonts loaded into it
  final _documentData = <int, int>{};
  final _fontData = <int>[];
  var _passwordNeeded = false;

  @override
  int loadDocument(Uint8List bytes) {
    final buffer = _alloc(bytes.length);
    _bytes(buffer, bytes.length).setAll(0, bytes);
    final doc = _i('FPDF_LoadMemDocument', [buffer, bytes.length, 0]);
    if (doc == 0) {
      _free(buffer);
      _passwordNeeded = _i('FPDF_GetLastError') == 4;
      return 0;
    }
    _documentData[doc] = buffer;
    return doc;
  }

  @override
  bool get lastLoadNeededPassword => _passwordNeeded;

  @override
  void closeDocument(int doc) {
    _c('FPDF_CloseDocument', [doc]);
    final buffer = _documentData.remove(doc);
    if (buffer != null) _free(buffer);
    for (final data in _fontData) {
      _free(data);
    }
    _fontData.clear();
  }

  @override
  int pageCount(int doc) => _i('FPDF_GetPageCount', [doc]);
  @override
  int loadPage(int doc, int index) => _i('FPDF_LoadPage', [doc, index]);
  @override
  void closePage(int page) => _c('FPDF_ClosePage', [page]);
  @override
  double pageWidth(int page) => _c('FPDF_GetPageWidthF', [page]).toDouble();
  @override
  double pageHeight(int page) => _c('FPDF_GetPageHeightF', [page]).toDouble();
  @override
  int loadTextPage(int page) => _i('FPDFText_LoadPage', [page]);
  @override
  void closeTextPage(int textPage) => _c('FPDFText_ClosePage', [textPage]);
  @override
  void deletePage(int doc, int index) => _c('FPDFPage_Delete', [doc, index]);

  @override
  bool movePagesToFront(int doc, List<int> indices) => _with(indices.length * 4, (p) {
        for (var n = 0; n < indices.length; n++) {
          _mem.setInt32(p + n * 4, indices[n], Endian.little);
        }
        return _i('FPDF_MovePages', [doc, p, indices.length, 0]) != 0;
      });

  @override
  int newPage(int doc, int index, double width, double height) => _i('FPDFPage_New', [doc, index, width, height]);

  @override
  Uint8List? save(int doc) {
    final out = BytesBuilder(copy: false);
    final callback = ((JSNumber self, JSNumber data, JSNumber size) {
      out.add(Uint8List.fromList(_bytes(data.toDartInt, size.toDartInt)));
      return 1.toJS;
    }).toJS;
    final slot = _loader.callMethodVarArgs<JSNumber>('addFunction'.toJS, [callback, 'iiii'.toJS]).toDartInt;
    try {
      return _with(8, (writer) {
        // FPDF_FILEWRITE: the version (1), then the function PDFium hands each block to
        _mem.setInt32(writer, 1, Endian.little);
        _mem.setInt32(writer + 4, slot, Endian.little);
        return _i('FPDF_SaveAsCopy', [doc, writer, 0]) == 0 ? null : out.takeBytes();
      });
    } finally {
      _loader.callMethodVarArgs<JSAny?>('removeFunction'.toJS, [slot.toJS]);
    }
  }

  @override
  (int, int) pageToDevice(int page, int width, int height, double x, double y) => _with(8, (p) {
        _c('FPDF_PageToDevice', [page, 0, 0, width, height, 0, x, y, p, p + 4]);
        return (_i32(p), _i32(p + 4));
      });

  @override
  (double, double) deviceToPage(int page, int width, int height, int x, int y) => _with(16, (p) {
        _c('FPDF_DeviceToPage', [page, 0, 0, width, height, 0, x, y, p, p + 8]);
        return (_f64(p), _f64(p + 8));
      });

  @override
  int countObjects(int page) => _i('FPDFPage_CountObjects', [page]);
  @override
  int getObject(int page, int index) => _i('FPDFPage_GetObject', [page, index]);
  @override
  int objectType(int object) => _i('FPDFPageObj_GetType', [object]);

  @override
  List<double>? bounds(int object) => _with(16, (p) {
        if (_i('FPDFPageObj_GetBounds', [object, p, p + 4, p + 8, p + 12]) == 0) return null;
        return [_f32(p), _f32(p + 4), _f32(p + 8), _f32(p + 12)];
      });

  @override
  List<double>? matrix(int object) => _with(24, (p) {
        if (_i('FPDFPageObj_GetMatrix', [object, p]) == 0) return null;
        return [for (var k = 0; k < 6; k++) _f32(p + k * 4)];
      });

  @override
  bool setMatrix(int object, List<double> v) => _with(24, (p) {
        for (var k = 0; k < 6; k++) {
          _mem.setFloat32(p + k * 4, v[k], Endian.little);
        }
        return _i('FPDFPageObj_SetMatrix', [object, p]) != 0;
      });

  @override
  void transform(int object, double a, double b, double c, double d, double e, double f) => _c('FPDFPageObj_Transform', [object, a, b, c, d, e, f]);

  @override
  int? fillColor(int object) => _with(16, (p) {
        if (_i('FPDFPageObj_GetFillColor', [object, p, p + 4, p + 8, p + 12]) == 0) return null;
        return (_u32(p + 12) & 0xFF) << 24 | (_u32(p) & 0xFF) << 16 | (_u32(p + 4) & 0xFF) << 8 | (_u32(p + 8) & 0xFF);
      });

  @override
  void setFillColor(int object, int argb) => _c('FPDFPageObj_SetFillColor', [object, (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF]);

  @override
  void insertObject(int page, int object) => _c('FPDFPage_InsertObject', [page, object]);
  @override
  void insertObjectAt(int page, int object, int index) => _c('FPDFPage_InsertObjectAtIndex', [page, object, index]);
  @override
  bool removeObject(int page, int object) => _i('FPDFPage_RemoveObject', [page, object]) != 0;
  @override
  void destroyObject(int object) => _c('FPDFPageObj_Destroy', [object]);
  @override
  void generateContent(int page) => _c('FPDFPage_GenerateContent', [page]);

  @override
  bool isInvisibleText(int object) => _i('FPDFTextObj_GetTextRenderMode', [object]) == 3;

  @override
  String textOf(int object, int textPage) {
    final bytes = _i('FPDFTextObj_GetText', [object, textPage, 0, 0]); // (with the terminating zero)
    if (bytes <= 2) return '';
    return _with(bytes, (p) {
      _c('FPDFTextObj_GetText', [object, textPage, p, bytes]);
      final units = Uint16List.view(Uint8List.fromList(_bytes(p, bytes)).buffer, 0, bytes ~/ 2 - 1);
      return String.fromCharCodes(units);
    });
  }

  @override
  double? fontSize(int object) => _with(4, (p) => _i('FPDFTextObj_GetFontSize', [object, p]) == 0 ? null : _f32(p));

  @override
  int fontOf(int object) => _i('FPDFTextObj_GetFont', [object]);

  @override
  String fontName(int font) {
    final length = _i('FPDFFont_GetBaseFontName', [font, 0, 0]);
    if (length <= 1) return '';
    return _with(length, (p) {
      _c('FPDFFont_GetBaseFontName', [font, p, length]);
      return utf8.decode(_bytes(p, length - 1), allowMalformed: true);
    });
  }

  @override
  bool fontIsEmbedded(int font) => _i('FPDFFont_GetIsEmbedded', [font]) != 0;
  @override
  int fontFlags(int font) => _i('FPDFFont_GetFlags', [font]);
  @override
  int fontWeight(int font) => _i('FPDFFont_GetWeight', [font]);

  @override
  int countChars(int textPage) => _i('FPDFText_CountChars', [textPage]);
  @override
  int charObject(int textPage, int index) => _i('FPDFText_GetTextObject', [textPage, index]);
  @override
  int charUnicode(int textPage, int index) => _c('FPDFText_GetUnicode', [textPage, index]).toInt() & 0xFFFFFFFF;

  @override
  List<double>? charBox(int textPage, int index) => _with(32, (p) {
        if (_i('FPDFText_GetCharBox', [textPage, index, p, p + 8, p + 16, p + 24]) == 0) return null;
        return [_f64(p), _f64(p + 8), _f64(p + 16), _f64(p + 24)];
      });

  @override
  bool setText(int object, String text) {
    final units = text.codeUnits;
    return _with((units.length + 1) * 2, (p) {
      final mem = _mem;
      for (var k = 0; k < units.length; k++) {
        mem.setUint16(p + k * 2, units[k], Endian.little);
      }
      mem.setUint16(p + units.length * 2, 0, Endian.little);
      return _i('FPDFText_SetText', [object, p]) != 0;
    });
  }

  @override
  bool setCharcodes(int object, List<int> codes) => _with(codes.length * 4, (p) {
        final mem = _mem;
        for (var k = 0; k < codes.length; k++) {
          mem.setUint32(p + k * 4, codes[k], Endian.little);
        }
        return _i('FPDFText_SetCharcodes', [object, p, codes.length]) != 0;
      });

  @override
  int createTextObject(int doc, int font, double size) => _i('FPDFPageObj_CreateTextObj', [doc, font, size]);

  @override
  int createFilledRect(double x, double y, double width, double height, int argb) {
    final object = _i('FPDFPageObj_CreateNewRect', [x, y, width, height]);
    setFillColor(object, argb);
    _c('FPDFPath_SetDrawMode', [object, 1, 0]); // (fill, alternate rule; no outline)
    return object;
  }

  @override
  int loadTrueTypeFont(int doc, Uint8List bytes) {
    final data = _alloc(bytes.length);
    _bytes(data, bytes.length).setAll(0, bytes);
    final font = _i('FPDFText_LoadFont', [doc, data, bytes.length, 2, 1]); // (TrueType, as a CID font)
    if (font == 0) {
      _free(data);
      return 0;
    }
    _fontData.add(data); // (PDFium reads the font from here when the PDF is saved)
    return font;
  }

  @override
  int loadStandardFont(int doc, String name) {
    final text = name.codeUnits;
    return _with(text.length + 1, (p) {
      final bytes = _bytes(p, text.length + 1);
      bytes.setAll(0, text);
      bytes[text.length] = 0;
      return _i('FPDFText_LoadStandardFont', [doc, p]);
    });
  }

  @override
  void closeFont(int font) => _c('FPDFFont_Close', [font]);
}

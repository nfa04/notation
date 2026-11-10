import 'dart:typed_data';

/// The part of PDFium the PDF editor ([PdfEditSession]) needs, with every handle (document, page, page object, font) an int, so
/// that the editing itself is written once. Two things implement it: PDFium through `dart:ffi` where that exists, and PDFium
/// compiled to WebAssembly, called from the page itself, in the browser.
///
/// Synchronous: PDFium is not thread-safe, a backend is only used from the one place that made it. A handle of 0 is "none".
abstract class PdfiumBackend {
  static const objectText = 1;
  static const objectPath = 2;
  static const objectImage = 3;

  // ---- documents and pages

  /// Opens [bytes] (kept until [closeDocument]); 0 when that failed, and [lastLoadNeededPassword] says why.
  int loadDocument(Uint8List bytes);
  bool get lastLoadNeededPassword;
  void closeDocument(int doc);
  int pageCount(int doc);
  int loadPage(int doc, int index);
  void closePage(int page);
  double pageWidth(int page);
  double pageHeight(int page);
  int loadTextPage(int page);
  void closeTextPage(int textPage);
  void deletePage(int doc, int index);

  /// Moves the pages [indices] (each once) to the start of the document, in that order.
  bool movePagesToFront(int doc, List<int> indices);

  /// A new blank page at [index]; 0 when that failed. Closed again by the caller with [closePage].
  int newPage(int doc, int index, double width, double height);

  /// The whole document as a PDF file; null when PDFium could not write it.
  Uint8List? save(int doc);

  // ---- where things are

  /// Page space (origin bottom left) to whole device units of a [width] x [height] view of the page, [x] and [y] across and down.
  (int, int) pageToDevice(int page, int width, int height, double x, double y);
  (double, double) deviceToPage(int page, int width, int height, int x, int y);

  // ---- page objects

  int countObjects(int page);
  int getObject(int page, int index);
  int objectType(int object);

  /// left, bottom, right, top in page space; null when it has none.
  List<double>? bounds(int object);

  /// a, b, c, d, e, f; null when it has none.
  List<double>? matrix(int object);
  bool setMatrix(int object, List<double> m);
  void transform(int object, double a, double b, double c, double d, double e, double f);

  /// 0xAARRGGBB; null when the object has no fill colour.
  int? fillColor(int object);
  void setFillColor(int object, int argb);

  void insertObject(int page, int object);
  void insertObjectAt(int page, int object, int index);

  /// Takes [object] off [page] (it is then the caller's to [destroyObject]); false when it was not on it.
  bool removeObject(int page, int object);
  void destroyObject(int object);

  /// Writes the page's objects back into the page's content, so that [save] has them.
  void generateContent(int page);

  // ---- text

  bool isInvisibleText(int object);

  /// What a text object says ([textPage] is the page's text index).
  String textOf(int object, int textPage);

  /// The size the PDF sets (before the text matrix); null when it has none.
  double? fontSize(int object);
  int fontOf(int object);
  String fontName(int font);
  bool fontIsEmbedded(int font);
  int fontFlags(int font);
  int fontWeight(int font);

  int countChars(int textPage);

  /// The text object character [index] belongs to; 0 for none.
  int charObject(int textPage, int index);
  int charUnicode(int textPage, int index);

  /// left, right, bottom, top in page space; null when the character has none.
  List<double>? charBox(int textPage, int index);

  bool setText(int object, String text);
  bool setCharcodes(int object, List<int> codes);
  int createTextObject(int doc, int font, double size);

  /// A filled rectangle (no outline) in page space.
  int createFilledRect(double x, double y, double width, double height, int argb);

  /// A TrueType font loaded into [doc] from [bytes] (which the backend keeps until [closeDocument]); 0 when PDFium refuses it.
  int loadTrueTypeFont(int doc, Uint8List bytes);
  int loadStandardFont(int doc, String name);
  void closeFont(int font);
}

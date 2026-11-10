import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/painting.dart';
import 'package:pdfrx/pdfrx.dart';

import '../ai/device_memory.dart';
import '../data/note_repository.dart';
import '../models/pdf_models.dart';

/// The resolutions the settings offer; null in the setting means the device decides.
const pdfDpiChoices = [150, 200, 250, 300];

/// The resolution picked for the device when the user has not chosen one: 250 dpi where there is memory to spare (6 GB or more), 200 elsewhere.
Future<int> defaultPdfDpi() async {
  final ram = await totalRamMb();
  return ram != null && ram >= 6000 ? 250 : 200;
}

/// The most pages are rendered at: the resolution chosen in the settings, else [defaultPdfDpi]. On screen a page is drawn as wide as
/// the screen shows it ([pagePixelWidth]), never wider than this; exports of pages use it as it is.
Future<int> pdfRenderDpi(NoteRepository repository) async {
  final saved = int.tryParse(await repository.settings.get('pdf_dpi') ?? '');
  return saved ?? await defaultPdfDpi();
}

/// The widest a page's picture is made, whatever the screen: a page of a poster would otherwise take hundreds of MB.
const maxPagePixelWidth = 2400;

/// How many pixels across the picture of a page is made with, for a page that is [screenPixels] across on the screen at the normal
/// size: that many, rounded up to a step (so that a slightly different window does not render every page again), never more than the
/// page at [dpi] and never more than [maxPagePixelWidth]. A page [pageWidth] points wide.
///
/// Pictures used to be made at the resolution of the settings whatever the screen: 1654 to 2067 pixels across for an A4 page, where a
/// tablet shows about 1200. Each pixel more is time in PDFium, a copy, an upload to the graphics memory and memory kept.
int pagePixelWidth({required double screenPixels, required double pageWidth, required int dpi}) {
  final stepped = ((screenPixels / 256).ceil() * 256).clamp(512, maxPagePixelWidth);
  final ceiling = (pageWidth * dpi / 72).round();
  return math.max(1, math.min(stepped, ceiling));
}

/// Renders [page] [pixelWidth] wide, with its height in proportion.
///
/// [cancel] stops the render between its slices (it then throws); [priority] tells pdfrx how soon it is needed among its other renders.
Future<PdfPageData> loadPdfPicture(PdfPage page, int pixelWidth, {PdfPageRenderCancellationToken? cancel, PdfPageRenderPriority? priority}) async {
  final image = await renderPageImage(page, pixelWidth, cancel: cancel, priority: priority);
  return PdfPageData(image: image, pageWidth: page.width, pageHeight: page.height);
}

/// The width in pixels the whole of a page would have to be rendered at to be sharp where it is [neededPixels] across on screen; 0 if
/// its picture, [normal] pixels across, is sharp enough. Steps of a quarter, so that a pinch does not render at every size.
int hiResPixelWidth(double neededPixels, {required int normal}) {
  if (neededPixels <= normal * 1.1) return 0;
  var width = normal.toDouble();
  while (width < neededPixels) {
    width *= 1.25;
  }
  return math.min(16384, (width / 64).ceil() * 64);
}

/// Renders [page] [pixelWidth] wide (narrower if the picture would be more than [maxPixels] in all: a phone has no memory for more).
/// The caller owns the image.
Future<ui.Image> renderPageImage(PdfPage page, int pixelWidth, {double maxPixels = 16e6, PdfPageRenderCancellationToken? cancel, PdfPageRenderPriority? priority}) async {
  final aspect = page.height / page.width;
  final width = pixelWidth.toDouble().clamp(1.0, math.sqrt(maxPixels / aspect));
  final image = await page.render(
    fullWidth: width,
    fullHeight: width * aspect,
    backgroundColor: 0xFFFFFFFF,
    cancellationToken: cancel,
    priority: priority,
  );
  if (image == null) throw StateError('page ${page.pageNumber} could not be rendered');
  try {
    return await image.createImage();
  } finally {
    image.dispose();
  }
}

/// Renders the part [pixels] of [page] as it is when the whole page is [fullWidth] pixels across: only what is on the screen, when
/// zoomed in, instead of the whole page at that size. The caller owns the image.
Future<ui.Image> renderPageRegion(PdfPage page, int fullWidth, Rect pixels, {PdfPageRenderCancellationToken? cancel, PdfPageRenderPriority? priority}) async {
  final image = await page.render(
    x: pixels.left.round(),
    y: pixels.top.round(),
    width: math.max(1, pixels.width.round()),
    height: math.max(1, pixels.height.round()),
    fullWidth: fullWidth.toDouble(),
    fullHeight: fullWidth * page.height / page.width,
    backgroundColor: 0xFFFFFFFF,
    cancellationToken: cancel,
    priority: priority,
  );
  if (image == null) throw StateError('page ${page.pageNumber} could not be rendered');
  try {
    return await image.createImage();
  } finally {
    image.dispose();
  }
}

/// The text of a page as PDFium has it: its characters and a rectangle for each, four numbers a character (left, top, right, bottom
/// in PDF points, from the bottom left), with what is needed to place them.
typedef PdfRawWords = ({String text, Float64List rects, double width, double height, int rotation, int number});

/// Reads the text of [page] from PDFium (on pdfrx's isolate). What [pdfWordsOf] then makes of it is the costly part.
Future<PdfRawWords> readPdfText(PdfPage page) async {
  final raw = await page.loadText();
  final chars = raw?.charRects ?? const <PdfRect>[];
  final rects = Float64List(chars.length * 4);
  for (var i = 0; i < chars.length; i++) {
    final r = chars[i];
    rects[i * 4] = r.left;
    rects[i * 4 + 1] = r.top;
    rects[i * 4 + 2] = r.right;
    rects[i * 4 + 3] = r.bottom;
  }
  return (text: raw?.fullText ?? '', rects: rects, width: page.width, height: page.height, rotation: page.rotation.index, number: page.pageNumber);
}

/// The lines and words of a page from its [raw] text, worked out on another isolate: pdfrx's reading order and line breaks, then
/// [linesOf]. (On the main isolate this held the screen still for each page that came in: thousands of characters, a RegExp each.)
Future<PdfPageWords> pdfWordsOf(PdfRawWords raw) => raw.text.isEmpty
    ? Future.value(PdfPageWords(pageWidth: raw.width, pageHeight: raw.height, lines: const []))
    : compute(_wordsOf, raw, debugLabel: 'pdf words');

/// [readPdfText] and [pdfWordsOf] in one.
Future<PdfPageWords> loadPdfWords(PdfPage page) async => pdfWordsOf(await readPdfText(page));

Future<PdfPageWords> _wordsOf(PdfRawWords raw) async {
  final page = _RawTextPage(raw);
  final structured = await page.loadStructuredText();
  return PdfPageWords(
    pageWidth: raw.width,
    pageHeight: raw.height,
    lines: linesOf(structured.fragments.map((f) => PdfFragment(f.text, [for (final r in f.charRects) r.toRect(page: page)]))),
  );
}

/// A page that is only its text, read before: pdfrx's text layout asks a page for its text, size and turn, nothing else, and this
/// lets it run on an isolate that has no PDFium.
class _RawTextPage extends PdfPage {
  final PdfRawWords raw;
  _RawTextPage(this.raw);

  @override
  int get pageNumber => raw.number;
  @override
  double get width => raw.width;
  @override
  double get height => raw.height;
  @override
  PdfPageRotation get rotation => PdfPageRotation.values[raw.rotation & 3];
  @override
  bool get isLoaded => true;

  @override
  Future<PdfPageRawText?> loadText() async {
    final r = raw.rects;
    return PdfPageRawText(raw.text, [for (var i = 0; i + 3 < r.length; i += 4) PdfRect(r[i], r[i + 1], r[i + 2], r[i + 3])]);
  }

  @override
  PdfDocument get document => throw UnsupportedError('only the text of the page is here');
  @override
  Future<PdfImage?> render({int x = 0, int y = 0, int? width, int? height, double? fullWidth, double? fullHeight, int? backgroundColor, PdfPageRotation? rotationOverride, PdfAnnotationRenderingMode annotationRenderingMode = PdfAnnotationRenderingMode.annotationAndForms, int flags = PdfPageRenderFlags.none, PdfPageRenderCancellationToken? cancellationToken, PdfPageRenderPriority? priority}) =>
      throw UnsupportedError('only the text of the page is here');
  @override
  PdfPageRenderCancellationToken createCancellationToken() => throw UnsupportedError('only the text of the page is here');
  @override
  Future<List<PdfLink>> loadLinks({bool compact = false, bool enableAutoLinkDetection = true}) async => const [];
}

/// A piece of page text with one rectangle per character.
class PdfFragment {
  final String text;
  final List<Rect> charRects;

  const PdfFragment(this.text, this.charRects);
}

/// Groups PDFium's text fragments (words, spaces, and the last word of a line
/// carrying a trailing line break) into lines of words.
List<PdfTextLine> linesOf(Iterable<PdfFragment> fragments) {
  final lines = <PdfTextLine>[];
  var words = <PdfTextWord>[];
  var texts = <String>[];
  var index = 0;

  void endLine() {
    if (words.isNotEmpty) {
      var box = Rect.fromLTRB(words.first.xMin, words.first.yMin, words.first.xMax, words.first.yMax);
      for (final w in words) {
        box = box.expandToInclude(Rect.fromLTRB(w.xMin, w.yMin, w.xMax, w.yMax));
      }
      lines.add(PdfTextLine(
        xMin: box.left,
        yMin: box.top,
        xMax: box.right,
        yMax: box.bottom,
        text: texts.join(' '),
        words: words,
      ));
    }
    words = [];
    texts = [];
    index = 0;
  }

  for (final f in fragments) {
    final breaksLine = f.text.endsWith('\n') || f.text.endsWith('\r');
    final word = f.text.replaceAll(RegExp(r'[\r\n]+$'), '');

    if (word.trim().isNotEmpty && word.length <= f.charRects.length) {
      // only the word's own characters: the line break's rectangles are dummies
      var box = f.charRects.first;
      for (final r in f.charRects.take(word.length)) {
        box = box.expandToInclude(r);
      }
      words.add(PdfTextWord(
        xMin: box.left,
        yMin: box.top,
        xMax: box.right,
        yMax: box.bottom,
        text: word,
        startIndex: index,
        endIndex: index + word.length,
      ));
      texts.add(word);
      index += word.length + 1; // the space the words are joined with
    }
    if (breaksLine) endLine();
  }
  endLine();
  return lines;
}

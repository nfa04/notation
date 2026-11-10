import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'canvas_models.dart' show newElementId;

/// A word of a PDF page, with its rectangle in page units and where it is in the page text.
class PdfTextWord {
  final double xMin;
  final double yMin;
  final double xMax;
  final double yMax;
  final String text;
  final int startIndex;
  final int endIndex;

  PdfTextWord({
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
    required this.text,
    required this.startIndex,
    required this.endIndex,
  });
}

/// A line of text of a PDF page (made of words), used to select and highlight text.
class PdfTextLine {
  final double xMin;
  final double yMin;
  final double xMax;
  final double yMax;
  final String text;
  final List<PdfTextWord> words;

  PdfTextLine({
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
    required this.text,
    required this.words,
  });
}

/// The words of a PDF page, in lines, in PDF points from the top left. Read apart from the picture ([PdfPageData]): the picture shows
/// as soon as it is there, and the words, which only selecting, highlighting and finding need, follow.
class PdfPageWords {
  final double pageWidth;
  final double pageHeight;
  final List<PdfTextLine> lines;

  const PdfPageWords({required this.pageWidth, required this.pageHeight, required this.lines});
}

/// The picture of a PDF page as the editor shows it, and the size of the page.
class PdfPageData {
  /// The rendered page. Whoever keeps the data owns this handle and lets go of it with [release]; whoever shows it keeps a handle of
  /// its own (`image.clone()`), which stays good after that.
  final ui.Image image;

  /// The size of the page in PDF points (what [image] shows all of).
  final double pageWidth;
  final double pageHeight;

  PdfPageData({
    required this.image,
    required this.pageWidth,
    required this.pageHeight,
  });

  bool _released = false;

  /// Whether [image] can still be used: it cannot once the data was let go of (the lines and sizes can).
  bool get alive => !_released;

  /// What [image] takes in memory (the pixels are 4 bytes each, whatever is on the page).
  int get bytes => image.width * image.height * 4;

  /// Lets go of [image]. More than once is fine.
  void release() {
    if (_released) return;
    _released = true;
    image.dispose();
  }

  /// The page as PNG, for what needs a file format (an export). Encoding a page takes a while (200 ms to over a second), which is why
  /// the editor shows the picture itself and not a PNG of it.
  Future<Uint8List> png() async {
    if (_released) throw StateError('the page was let go of');
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }
}

/// The colours text can be highlighted in, by name.
const highlightColors = <(String, Color)>[
  ('Yellow', Color(0x66FFFF00)),
  ('Green', Color(0x6669F0AE)),
  ('Pink', Color(0x66FF80AB)),
  ('Orange', Color(0x66FFAB40)),
  ('Blue', Color(0x6640C4FF)),
];

/// A marked piece of a PDF page (or of a written page).
class PdfHighlight {
  /// Names the mark across devices and saves.
  final String id;
  final Rect rect;
  final Color color;

  /// The id of the text box with the comment, when this marks the text a comment is about
  /// (it is exported as a comment of the PDF, with that text).
  final String? commentBox;

  /// Who made the mark; null if not known.
  final String? author;

  PdfHighlight({String? id, required this.rect, required this.color, this.commentBox, this.author}) : id = id ?? newElementId();
}

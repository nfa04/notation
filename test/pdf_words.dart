import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/pdf/pdf_text_layer.dart';

/// Where the words that read [word] are on the screen: a page's text layer is one render object, not a widget for each word.
List<Rect> pdfWords(WidgetTester tester, String word) => [
      for (final e in find.byType(PdfTextLayer).evaluate())
        if (e.renderObject is RenderPdfTextLayer) ...(e.renderObject! as RenderPdfTextLayer).wordRects(word),
    ];

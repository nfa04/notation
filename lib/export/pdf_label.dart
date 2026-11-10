import 'package:flutter/widgets.dart' show Matrix4;
import 'package:pdf/pdf.dart' as pw;

import '../models/canvas_models.dart';
import '../models/stroke_label.dart';

/// The fonts the labels of a PDF page are written in (built in ones, made when the first label needs them): letters outside Latin-1
/// are left out of a PDF.
class PdfLabelFonts {
  final pw.PdfDocument document;
  PdfLabelFonts(this.document);

  late final pw.PdfFont regular = pw.PdfFont.helvetica(document);
  late final pw.PdfFont bold = pw.PdfFont.helveticaBold(document);

  pw.PdfFont of(bool isBold) => isBold ? bold : regular;

  /// [text] without the letters the font cannot write.
  String supported(String text, bool isBold) {
    final font = of(isBold);
    return String.fromCharCodes(text.runes.where(font.isRuneSupported));
  }

  double measure(String text, double size, bool isBold) => of(isBold).stringMetrics(supported(text, isBold)).width * size;
}

/// Writes the label of [stroke] on [canvas] of a page [pageHeight] tall (the PDF counts up from the bottom, the page down from the top).
void drawLabelOnPdf(pw.PdfGraphics canvas, double pageHeight, DrawingStroke stroke, PdfLabelFonts fonts) {
  final label = stroke.label;
  if (label == null) return;
  final color = label.colorFor(stroke.color, stroke.fill);
  final runs = layoutLabel(stroke.points, stroke.isClosed, stroke.width, label, fonts.measure);
  if (runs.isEmpty) return;
  final font = fonts.of(label.bold);
  canvas
    ..saveContext()
    ..setGraphicState(pw.PdfGraphicState(opacity: color.a))
    ..setFillColor(pw.PdfColor(color.r, color.g, color.b));
  for (final run in runs) {
    final text = fonts.supported(run.text, label.bold);
    if (text.isEmpty) continue;
    canvas
      ..saveContext()
      ..setTransform(Matrix4.identity()
        ..translateByDouble(run.origin.dx, pageHeight - run.origin.dy, 0, 1)
        ..rotateZ(-run.angle))
      ..drawString(font, run.size, text, 0, 0)
      ..restoreContext();
  }
  canvas.restoreContext();
}


import 'dart:ui';

import 'package:pdf/pdf.dart' as pw;

import '../ink/ink_clusters.dart';
import '../ink/ink_grouping.dart';
import '../models/canvas_models.dart';
import '../search/search_query.dart';

/// The setting that switches the text under the handwriting of an exported PDF off (`0`); it is on otherwise.
const pdfInkTextSetting = 'pdf_handwriting_text';

/// One line of what the handwriting says, and where the ink of it is on the page.
class InkTextLine {
  final String text;

  /// In the units of the page, counted down from its top (like the strokes).
  final Rect box;

  const InkTextLine(this.text, this.box);

  @override
  String toString() => 'InkTextLine($text, $box)';
}

/// Puts the lines of [text] (what was read of [cluster]: one line to a line of writing, a space between words) where the lines of
/// writing are. The reader cut the strokes into lines with [groupIntoLines] to read them, so the same cut gives the same lines;
/// when the numbers do not match (a reading from an older version, say) the block is cut into as many equal rows.
List<InkTextLine> inkTextLines(InkCluster cluster, String text) {
  final texts = text.split('\n');
  final written = groupIntoLines([for (final s in cluster.strokes) if (s.color.a > 0.9 && Brushes.writes(s.brush)) s]);
  final boxes = written.length == texts.length
      ? [for (final line in written) line.map((c) => c.bounds).reduce((a, b) => a.expandToInclude(b))]
      : [
          for (var i = 0; i < texts.length; i++)
            Rect.fromLTRB(cluster.bounds.left, cluster.bounds.top + cluster.bounds.height * i / texts.length, cluster.bounds.right,
                cluster.bounds.top + cluster.bounds.height * (i + 1) / texts.length),
        ];
  // a line with a few small letters ("so", "an") is lower than its neighbours, but is as big as they are: the size of the writing
  // is what most of the lines say
  final heights = [for (final b in boxes) b.height]..sort();
  final usual = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];
  return [
    for (var i = 0; i < texts.length; i++)
      if (texts[i].trim().isNotEmpty)
        InkTextLine(texts[i].trim(), boxes[i].height >= usual * 0.8 ? boxes[i] : Rect.fromLTRB(boxes[i].left, boxes[i].bottom - usual * 0.8, boxes[i].right, boxes[i].bottom)),
  ];
}

/// Writes [lines] on [canvas] (a page [pageHeight] tall, counting up from its bottom) as text that is not drawn: a PDF viewer can select it,
/// search it and copy it, and shows nothing for it. Each line is stretched to the width of its ink, so that a word is selected where
/// it is written. Letters the font cannot write are left out.
void drawInkText(pw.PdfGraphics canvas, double pageHeight, Iterable<InkTextLine> lines, pw.PdfFont font) {
  for (final line in lines) {
    // (a letter that is left out leaves one space, not two)
    final text = String.fromCharCodes(line.text.runes.where(font.isRuneSupported)).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    // as big as the line is tall: a viewer marks a line from the baseline up to the height of a capital (or more, from the descender
    // to the ascender), and the baseline is a fifth of the line above its bottom, where the tails of g and y end
    final size = line.box.height.clamp(4.0, 150.0);
    final natural = font.stringMetrics(text).width * size;
    if (natural <= 0) continue;
    final stretch = (line.box.width / natural).clamp(0.05, 20.0);
    canvas.drawString(font, size, text, line.box.left, pageHeight - line.box.bottom + size * 0.2, scale: stretch, mode: pw.PdfTextRenderingMode.invisible);
  }
}

/// What the handwriting of a note says, for the text under it in an exported PDF: what was read before (kept for the search, or
/// in memory while the note is open), and what is read now, within a time (an export does not wait for a whole notebook).
class PdfInkText {
  /// What was read before, by the key of the block of writing.
  final Map<String, String> known;

  /// Reads the strokes of a block; null: nothing is read now.
  final Future<String> Function(List<DrawingStroke> strokes)? read;

  /// How long the export waits for readings.
  final Duration budget;

  final Stopwatch _clock = Stopwatch();

  /// What was read now, for the database to keep (the next export, the search and a conversion find it there).
  final List<InkText> fresh = [];

  /// How many blocks of writing are left without text because the time was out or the reader failed.
  int unread = 0;

  PdfInkText({required this.known, this.read, this.budget = const Duration(seconds: 60)});

  /// The lines of text for the writing in [strokes] of [page] (the strokes the page shows: what is on a hidden layer is not among them).
  Future<List<InkTextLine>> pageLines(int page, Iterable<DrawingStroke> strokes) async {
    // (finding the blocks of writing on a page costs: nothing to put under them, nothing to find)
    if (known.isEmpty && read == null) return const [];
    _clock.start();
    final lines = <InkTextLine>[];
    for (final cluster in clusterStrokes(page, strokes)) {
      var text = known[cluster.key];
      if (text == null) {
        final reader = read;
        if (reader == null) continue;
        if (_clock.elapsed > budget) {
          unread++;
          continue;
        }
        try {
          text = (await reader(cluster.strokes)).trim();
          known[cluster.key] = text;
          fresh.add(InkText(key: cluster.key, page: page, text: text, bounds: cluster.bounds));
        } catch (_) {
          unread++;
          continue;
        }
      }
      if (text.isNotEmpty) lines.addAll(inkTextLines(cluster, text));
    }
    return lines;
  }
}

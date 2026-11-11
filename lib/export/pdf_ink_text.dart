import 'dart:math' as math;
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
/// writing are. The reader cut the strokes into lines with [groupIntoLines] to read them, so the same cut gives the same lines.
/// When the numbers do not match, the lines of text are matched to the lines of writing by length (see [alignLines]): the reading
/// is kept trimmed, so an unread first or last line is missing, and a piece the model wrote over several lines has more.
List<InkTextLine> inkTextLines(InkCluster cluster, String text) {
  final texts = text.split('\n').map((t) => t.trim()).toList();
  final written = groupIntoLines([for (final s in cluster.strokes) if (s.color.a > 0.9 && Brushes.writes(s.brush)) s]);
  final List<Rect> boxes;
  final List<String> said;
  if (written.isEmpty) {
    // (nothing to go by: the block is cut into as many equal rows)
    boxes = [
      for (var i = 0; i < texts.length; i++)
        Rect.fromLTRB(cluster.bounds.left, cluster.bounds.top + cluster.bounds.height * i / texts.length, cluster.bounds.right,
            cluster.bounds.top + cluster.bounds.height * (i + 1) / texts.length),
    ];
    said = texts;
  } else {
    boxes = [for (final line in written) line.map((c) => c.bounds).reduce((a, b) => a.expandToInclude(b))];
    said = alignLines(texts, [for (final b in boxes) b.width]);
  }
  // a line with a few small letters ("so", "an") is lower than its neighbours, but is as big as they are: the size of the writing
  // is what most of the lines say
  final heights = [for (final b in boxes) b.height]..sort();
  final usual = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];
  return [
    for (var i = 0; i < said.length; i++)
      if (said[i].isNotEmpty)
        InkTextLine(said[i], boxes[i].height >= usual * 0.8 ? boxes[i] : Rect.fromLTRB(boxes[i].left, boxes[i].bottom - usual * 0.8, boxes[i].right, boxes[i].bottom)),
  ];
}

/// The text of each line of writing (as wide as [widths]) from the [texts] that were read, which may be more or fewer than the lines:
/// with fewer, the missing ones are at the start or the end (an unread line is empty, and what is read is trimmed), and the place that
/// fits the lengths best is taken; with more, neighbouring texts are joined, where the lengths fit best. Always as many as [widths].
List<String> alignLines(List<String> texts, List<double> widths) {
  final n = texts.length, m = widths.length;
  if (n == m) return texts;
  final chars = [for (final t in texts) t.length];
  final total = chars.fold<int>(0, (a, b) => a + b);
  final wide = widths.fold<double>(0, (a, b) => a + b);
  if (total == 0 || wide <= 0) return [...texts.take(m), for (var i = n; i < m; i++) ''];
  final density = total / wide; // letters to a unit of width
  double cost(int letters, int line) => (math.log((letters + 1) / (density * widths[line] + 1))).abs();
  if (n < m) {
    // (the first text goes to line [lead])
    var best = 0;
    var bestCost = double.infinity;
    for (var lead = 0; lead <= m - n; lead++) {
      var c = 0.0;
      for (var i = 0; i < n; i++) {
        if (chars[i] > 0) c += cost(chars[i], lead + i);
      }
      if (c < bestCost) {
        bestCost = c;
        best = lead;
      }
    }
    return [for (var j = 0; j < m; j++) j >= best && j < best + n ? texts[j - best] : ''];
  }
  // n > m: cut the texts into m runs, the cheapest way (dp[j][i]: the first j lines have the first i texts)
  final prefix = [0];
  for (final c in chars) {
    prefix.add(prefix.last + c);
  }
  final dp = List.generate(m + 1, (_) => List<double>.filled(n + 1, double.infinity));
  final cut = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
  dp[0][0] = 0;
  for (var j = 1; j <= m; j++) {
    for (var i = j; i <= n - (m - j); i++) {
      for (var k = j - 1; k < i; k++) {
        if (dp[j - 1][k].isInfinite) continue;
        final c = dp[j - 1][k] + cost(prefix[i] - prefix[k], j - 1);
        if (c < dp[j][i]) {
          dp[j][i] = c;
          cut[j][i] = k;
        }
      }
    }
  }
  final out = List.filled(m, '');
  var i = n;
  for (var j = m; j >= 1; j--) {
    final k = cut[j][i];
    out[j - 1] = texts.sublist(k, i).where((t) => t.isNotEmpty).join(' ');
    i = k;
  }
  return out;
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

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

  /// The words as they are written, left to right (the strokes that lie together, split at the gaps between words): what the
  /// words of [text] are laid over, when there are as many. Empty where it is not known.
  final List<InkWordBox> words;

  const InkTextLine(this.text, this.box, {this.words = const []});

  @override
  String toString() => 'InkTextLine($text, $box)';
}

/// The strokes of one written word and the box round them.
class InkWordBox {
  final Rect box;
  final List<DrawingStroke> strokes;
  const InkWordBox(this.box, this.strokes);
}

/// Splits the [strokes] of one line into the words they are written as: strokes whose boxes touch or lie closer than [gap] (in
/// the units of the page) in the direction of the line belong to one word (a fraction, with its bar, is one).
List<InkWordBox> splitIntoWords(List<DrawingStroke> strokes, double gap) {
  final boxes = {for (final s in strokes) s: strokeBounds(s)};
  final sorted = [...strokes]..sort((a, b) => boxes[a]!.left.compareTo(boxes[b]!.left));
  final out = <InkWordBox>[];
  for (final s in sorted) {
    final b = boxes[s]!;
    if (out.isNotEmpty && b.left - out.last.box.right <= gap) {
      final last = out.removeLast();
      out.add(InkWordBox(last.box.expandToInclude(b), [...last.strokes, s]));
    } else {
      out.add(InkWordBox(b, [s]));
    }
  }
  return out;
}

/// The [strokes] of one line cut into exactly [count] words, at the widest gaps between them in the direction of the line (the
/// reader says how many words there are, so the gaps need no threshold). Null when the strokes do not fall apart into that many.
List<InkWordBox>? splitIntoWordCount(List<DrawingStroke> strokes, int count) {
  if (count < 1 || strokes.length < count) return null;
  final boxes = {for (final s in strokes) s: strokeBounds(s)};
  final sorted = [...strokes]..sort((a, b) => boxes[a]!.left.compareTo(boxes[b]!.left));
  // the gap before each stroke: how far its left edge is from the right edge of everything before it
  final gaps = <({int at, double size})>[];
  var reach = boxes[sorted.first]!.right;
  for (var i = 1; i < sorted.length; i++) {
    final b = boxes[sorted[i]]!;
    gaps.add((at: i, size: b.left - reach));
    reach = math.max(reach, b.right);
  }
  if (gaps.length < count - 1) return null;
  final widest = [...gaps]..sort((a, b) => b.size.compareTo(a.size));
  final cuts = widest.take(count - 1).toList();
  // (a cut where the strokes touch or overlap is no gap between words)
  if (cuts.any((g) => g.size <= 0)) return null;
  // (and the gaps that are cut are clearly wider than those that are not: otherwise the cut is a guess)
  final rest = widest.skip(count - 1);
  if (cuts.isNotEmpty && rest.isNotEmpty && cuts.last.size < rest.first.size * 1.4) return null;
  final at = {for (final c in cuts) c.at};
  final out = <InkWordBox>[];
  var current = <DrawingStroke>[];
  for (var i = 0; i < sorted.length; i++) {
    if (at.contains(i) && current.isNotEmpty) {
      out.add(InkWordBox(current.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b)), current));
      current = [];
    }
    current.add(sorted[i]);
  }
  out.add(InkWordBox(current.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b)), current));
  return out;
}

/// The lines of writing of [cluster] as the reader was given them, each with the words it is written in (see [splitIntoWords]).
List<({Rect box, List<InkWordBox> words})> inkWrittenLines(InkCluster cluster) {
  final written = groupIntoLines([for (final s in cluster.strokes) if (s.color.a > 0.9 && Brushes.writes(s.brush)) s]);
  if (written.isEmpty) return const [];
  final boxes = [for (final line in written) line.map((c) => c.bounds).reduce((a, b) => a.expandToInclude(b))];
  final heights = [for (final b in boxes) b.height]..sort();
  final usual = heights[heights.length ~/ 2];
  return [for (var i = 0; i < written.length; i++) (box: boxes[i], words: splitIntoWords([for (final c in written[i]) ...c.strokes], usual * 0.3))];
}

/// Puts the lines of [text] (what was read of [cluster]: one line to a line of writing, a space between words) where the lines of
/// writing are. The reader cut the strokes into lines with [groupIntoLines] to read them, so the same cut gives the same lines.
/// When the numbers do not match, the lines of text are matched to the lines of writing by length (see [alignLines]): the reading
/// is kept trimmed, so an unread first or last line is missing, and a piece the model wrote over several lines has more.
List<InkTextLine> inkTextLines(InkCluster cluster, String text) {
  final texts = plainI(text).split('\n').map((t) => t.trim()).toList();
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
        InkTextLine(
          said[i],
          boxes[i].height >= usual * 0.8 ? boxes[i] : Rect.fromLTRB(boxes[i].left, boxes[i].bottom - usual * 0.8, boxes[i].right, boxes[i].bottom),
          words: written.isEmpty ? const [] : splitIntoWords([for (final c in written[i]) ...c.strokes], usual * 0.3),
        ),
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

/// How wide a letter is written (narrow ones take less), to tell where a word is in a line: the reader keeps no box per word.
double _letterWidth(String c) {
  if ('iIl.,;:\'’!|jt ()/'.contains(c)) return 0.5;
  if ('fr'.contains(c)) return 0.7;
  if ('mwMW'.contains(c)) return 1.5;
  return 1;
}

final _mathSpan = RegExp(r'\$\$([^$]+)\$\$|\$([^$]+)\$');

/// Whether [t] (with no dollar signs) is LaTeX that the reader did not put between them: a command, or a sub- or superscript in braces.
final _bareLatex = RegExp(r'\\[a-zA-Z]+|[_^]\s*\{|\{\s*[^{}\s]');

/// [text] with the LaTeX the reader wrote turned into what a person would select and copy: `$\frac{1}{2}$` is `1/2`, `$S _ { n }$` is
/// `S_n`, and the dollar signs, braces, spacing commands and the spaces the reader puts between the signs of a formula are gone. (As
/// LaTeX the string was several times as long as the formula is written wide, so its letters were squeezed on top of each other under the
/// ink, and a viewer showed them apart.)
String plainText(String text) {
  final out = StringBuffer();
  var at = 0;
  // (what is outside the dollar signs is LaTeX too when it has commands in it: the reader put the signs where it thought best)
  void outside(String part) => out.write(_bareLatex.hasMatch(part) ? ' ${_plainMaths(part)} ' : part.replaceAll(r'$', ' '));
  for (final m in _mathSpan.allMatches(text)) {
    outside(text.substring(at, m.start));
    out.write(' ${_plainMaths(m[1] ?? m[2]!)} ');
    at = m.end;
  }
  outside(text.substring(at));
  return out.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

/// A space that is meant (round a word like `in`), not one the reader put between the signs.
const _meant = '\u0001';

String _plainMaths(String latex) {
  var t = latex.replaceAll(r'$', ' ');
  String grouped(String s) {
    final plain = s.replaceAll(RegExp(r'\s+'), '');
    return RegExp(r'^[\w.]+$').hasMatch(plain) ? plain : '($plain)';
  }

  // (\frac{a}{b} several times over, the inner ones first)
  final frac = RegExp(r'\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}');
  for (var i = 0; i < 6 && frac.hasMatch(t); i++) {
    t = t.replaceAllMapped(frac, (m) => '{${grouped(m[1]!)}/${grouped(m[2]!)}}');
  }
  t = t.replaceAllMapped(RegExp(r'\\binom\s*\{([^{}]*)\}\s*\{([^{}]*)\}'), (m) => '${_meant}binom(${m[1]!.trim()},${m[2]!.trim()})');
  const symbols = {
    'leq': '<=', 'le': '<=', 'geq': '>=', 'ge': '>=', 'neq': '!=', 'ne': '!=', 'rightarrow': '->', 'to': '->', 'leftarrow': '<-', 'Rightarrow': '=>',
    'Leftrightarrow': '<=>', 'times': '×', 'cdot': '·', 'pm': '±', 'div': '÷', 'mid': '|', 'sim': '~', 'approx': '~=', 'infty': 'inf',
  };
  t = t
      .replaceAll(RegExp(r'\\(left|right|big|Big|bigg|Bigg|displaystyle|mathrm|mathbf|mathit|text|operatorname)(?![a-zA-Z])'), '')
      .replaceAll(RegExp(r'\\[,;:! ]|\\quad|\\qquad'), '')
      .replaceAll(RegExp(r'\\\\|&'), _meant)
      .replaceAllMapped(RegExp(r'\\([a-zA-Z]+)'), (m) {
    final sign = symbols[m[1]];
    if (sign == null) return '$_meant${m[1]}$_meant';
    return const {'×', '·', '±', '÷', '|', '~', 'inf'}.contains(sign) ? sign : '$_meant$sign$_meant';
  }).replaceAll(RegExp(r'[{}]'), '');
  // (whatever space is left was the reader's: the signs of a formula run on)
  return t.replaceAll(RegExp(r'\s+'), '').replaceAll(_meant, ' ').replaceAll(RegExp(r' +'), ' ').trim();
}

/// The words of [text] (one line) and where each one is across [width] (counting from 0): a word takes its share of the line by the
/// letters in it, the space after it included, so that the words run on without a gap whatever the ink does.
List<({String text, double left, double right})> placeWords(String text, double width) {
  final words = RegExp(r'\S+\s?').allMatches(text).map((m) => m[0]!).toList();
  final weights = [for (final w in words) w.split('').fold(0.0, (a, c) => a + _letterWidth(c))];
  final total = weights.fold(0.0, (a, b) => a + b);
  if (words.isEmpty || total <= 0) return const [];
  final out = <({String text, double left, double right})>[];
  var at = 0.0;
  for (var i = 0; i < words.length; i++) {
    final to = at + width * weights[i] / total;
    out.add((text: words[i], left: at, right: to));
    at = to;
  }
  return out;
}

/// Writes [lines] on [canvas] (a page [pageHeight] tall, counting up from its bottom) as text that is not drawn: a PDF viewer can select it,
/// search it and copy it, and shows nothing for it. Each word is stretched to the place it takes in its line of ink, so that a word is
/// selected where it is written and no letter is stretched or squeezed far from its natural width (a viewer takes a wide gap for a
/// space and a squeezed pair for one letter). Letters the font cannot write are left out.
void drawInkText(pw.PdfGraphics canvas, double pageHeight, Iterable<InkTextLine> lines, pw.PdfFont font) {
  for (final line in lines) {
    // (a letter that is left out leaves one space, not two)
    final text = plainText(String.fromCharCodes(line.text.runes.where(font.isRuneSupported)));
    if (text.isEmpty) continue;
    // as big as the line is tall: a viewer marks a line from the baseline up to the height of a capital (or more, from the descender
    // to the ascender), and the baseline is a fifth of the line above its bottom, where the tails of g and y end
    final size = line.box.height.clamp(4.0, 150.0);
    final words = placeWords(text, line.box.width);
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      final natural = font.stringMetrics(w.text).width * size;
      if (natural <= 0) continue;
      final stretch = ((w.right - w.left) / natural).clamp(0.2, 5.0);
      canvas.drawString(font, size, w.text, line.box.left + w.left, pageHeight - line.box.bottom + size * 0.2, scale: stretch, mode: pw.PdfTextRenderingMode.invisible);
    }
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

/// [text] with the i that carries a stroke instead of a dot (read as ì, í, î or ï: a hurried dot is a tick) written as a plain i. The
/// reader takes the tick for an accent; a word with an accent on its i is rarely written by hand in the languages the notes are in.
String plainI(String text) => text.replaceAllMapped(RegExp('[ìíîïĩ]|[ÌÍÎÏĨ]'), (m) => m[0]!.toLowerCase() == m[0] ? 'i' : 'I');

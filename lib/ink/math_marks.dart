import 'dart:math' as math;
import 'dart:ui';

import '../algebra/checker.dart';
import 'ink_clusters.dart';

/// What the checker found for one line of handwritten maths, and where that line is.
class MathMark {
  final int page;

  /// Names the strokes of the line (see `InkCluster.key`): a correction of what was read is made for it.
  final String key;

  /// The line on its page.
  final Rect rect;

  /// The line as it was read (LaTeX).
  final String latex;
  final LineCheck check;

  /// All the lines of the worked solution this line is in (in order, with the lines that are not maths too), and which
  /// of them this is: what the sheet of a mark shows, the same as the sheet of the manual check.
  final List<({String key, String? latex})> solution;
  final int index;

  /// Other readings of this line (made with a thinner and a thicker pen) that differ from [latex].
  final List<String> others;

  /// Whether the line is marked as a mistake but another reading of it is not: the writing may have been misread, and the mark says "not sure"
  /// instead of "wrong". (A mistake that every reading shows stays a mistake.)
  final bool doubtful;

  const MathMark(this.page, this.key, this.rect, this.latex, this.check, {this.solution = const [], this.index = 0, this.others = const [], this.doubtful = false});
}

/// Whether line [i] of [lines] is not a mistake with one of the [alternatives] (other readings of it) in its place, the other lines as they are.
bool readsOtherwise(List<String?> lines, int i, Iterable<String> alternatives) => alternatives.any((alt) {
      final trial = [...lines]..[i] = alt;
      return !checkLines(trial)[i].isProblem;
    });

/// Whether two readings of the same writing are the same formula as far as it matters here: spacing, `\left` and `\right`, and braces around
/// a single character (`x^{2}` and `x^2`) do not count.
bool sameReading(String a, String b) => _plain(a) == _plain(b);

String _plain(String s) {
  var t = s.replaceAll(RegExp(r'\\(?:left|right|quad|qquad)(?![a-zA-Z])|\\[,;:! ]'), '').replaceAll(RegExp(r'\s+'), '');
  final single = RegExp(r'\{([A-Za-z0-9])\}');
  while (single.hasMatch(t)) {
    t = t.replaceAllMapped(single, (m) => m[1]!);
  }
  return t;
}

/// A line of writing that has been read: where it is, and its LaTeX (null if it is not maths or not read yet).
typedef ReadLine = ({int page, String key, Rect rect, String? latex});

/// Groups the lines of maths that follow each other into worked solutions, checks them ([checkLines]) and says what
/// there is to show next to which line. Each line goes on from the solution whose last line it follows most closely
/// (below it, near, and about under it), so that two columns of working, or a note beside a line (`| -3`), do not tear a
/// solution apart. A line that is not maths (or not read yet) is in the solution all the same, and ends the chain of
/// steps there; a line beside another one starts a solution of its own.
class MathMarker {
  final Map<String, List<LineCheck>> _checked = {};

  /// The marks for [lines] (in any order). [others] holds, by the key of a line, the other readings that were made of it (see
  /// `InkPrefetcher.othersOf`): a line that is a mistake in the reading it has but not in one of the others is [MathMark.doubtful].
  List<MathMark> mark(Iterable<ReadLine> lines, {Map<String, List<String>> others = const {}}) {
    final byPage = <int, List<ReadLine>>{};
    for (final l in lines) {
      byPage.putIfAbsent(l.page, () => []).add(l);
    }
    final out = <MathMark>[];
    for (final e in byPage.entries) {
      final rows = e.value..sort((a, b) {
        final c = a.rect.top.compareTo(b.rect.top);
        return c != 0 ? c : a.rect.left.compareTo(b.rect.left);
      });
      final blocks = <List<ReadLine>>[];
      for (final row in rows) {
        List<ReadLine>? best;
        var bestCost = double.infinity;
        for (final block in blocks) {
          final last = block.last.rect;
          if (!_follows(last, row.rect)) continue;
          final cost = (row.rect.top - last.bottom) + 0.5 * (row.rect.left - last.left).abs();
          if (cost < bestCost) {
            bestCost = cost;
            best = block;
          }
        }
        best != null ? best.add(row) : blocks.add([row]);
      }
      for (final block in blocks) {
        final latex = [for (final l in block) _text(l)];
        if (latex.every((l) => l == null)) continue;
        final key = latex.map((l) => l ?? '\u0002').join('\u0001');
        if (_checked.length > 300) _checked.clear();
        final checks = _checked.putIfAbsent(key, () => checkLines(latex));
        final solution = [for (var i = 0; i < block.length; i++) (key: block[i].key, latex: latex[i])];
        for (var i = 0; i < block.length; i++) {
          if (latex[i] != null && !checks[i].isNothing) {
            final read = latex[i]!;
            final alternatives = <String>[
              for (final o in others[block[i].key] ?? const <String>[])
                if (!sameReading(o, read)) o,
            ];
            // (only for a line that is a mistake: the others are tried in its place, with the lines around it as they are)
            final doubtful = checks[i].isProblem && readsOtherwise(latex, i, alternatives);
            out.add(MathMark(e.key, block[i].key, block[i].rect, read, checks[i], solution: solution, index: i, others: alternatives, doubtful: doubtful));
          }
        }
      }
    }
    return out;
  }

  static String? _text(ReadLine l) {
    final t = l.latex;
    return t == null || t.trim().isEmpty ? null : t;
  }

  /// Whether [b] is the next line of a solution after [a]: below it, close, and about under it.
  static bool _follows(Rect a, Rect b) {
    if (onOneLine(a, b)) return false;
    final height = math.max(math.max(a.height, b.height), 24.0);
    if (b.top - a.bottom > 1.8 * height) return false;
    final overlap = math.min(a.right, b.right) - math.max(a.left, b.left);
    return overlap > 0 || (b.left - a.left).abs() < math.max(200.0, 8 * height);
  }
}

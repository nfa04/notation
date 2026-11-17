import 'dart:typed_data';

/// One change to a text: [removed] characters from [start] (counted in the OLD text) were replaced by [inserted].
class TextEdit {
  final int start;
  final int removed;
  final String inserted;
  const TextEdit(this.start, this.removed, this.inserted);

  @override
  String toString() => 'TextEdit($start, -$removed, +"$inserted")';

  @override
  bool operator ==(Object other) => other is TextEdit && other.start == start && other.removed == removed && other.inserted == inserted;

  @override
  int get hashCode => Object.hash(start, removed, inserted);
}

/// The changes that turn [a] into [b], in order and not touching each other (the starts count in [a]).
///
/// What matters about the changes is what they say about what a person did, because others change the same text at the same time:
///  - what was typed or deleted in one place is one change of exactly those characters (not a bigger one around it);
///  - two changes far apart are two changes, and what is between them is not touched (or everybody who writes at the same time would
///    put a copy of it in);
///  - a word that was replaced by another is one change, not the few letters that differ (the words `red` and `blue` have an `e` in
///    common, and the letters of two people's new words would be mixed);
///  - a change that could be put in several places that give the same text goes where a word begins.
///
/// What lies between the first and the last difference is compared word by word. Texts that differ in too many places ([maxCost]
/// words or pieces) come out as one change from the first difference to the last: correct, but coarser.
List<TextEdit> diffText(String a, String b, {int maxCost = 1500}) {
  if (a == b) return const [];
  final la = a.length, lb = b.length;
  var p = 0;
  final shortest = la < lb ? la : lb;
  while (p < shortest && a.codeUnitAt(p) == b.codeUnitAt(p)) {
    p++;
  }
  var s = 0;
  while (s < shortest - p && a.codeUnitAt(la - 1 - s) == b.codeUnitAt(lb - 1 - s)) {
    s++;
  }
  // (a pair of surrogates is never cut in two: the middle part starts and ends on whole characters)
  if (p > 0 && p < la && _isLow(a.codeUnitAt(p)) && _isHigh(a.codeUnitAt(p - 1))) p--;
  if (p > 0 && p < lb && _isLow(b.codeUnitAt(p)) && _isHigh(b.codeUnitAt(p - 1))) p--;
  if (s > 0 && la - s > 0 && _isLow(a.codeUnitAt(la - s)) && _isHigh(a.codeUnitAt(la - s - 1))) s--;
  if (s > 0 && lb - s > 0 && _isLow(b.codeUnitAt(lb - s)) && _isHigh(b.codeUnitAt(lb - s - 1))) s--;
  final n = la - p - s, m = lb - p - s;
  if (n == 0 || m == 0) return _slideToWords(a, [TextEdit(p, n, b.substring(p, p + m))]);
  final x = a.substring(p, p + n), y = b.substring(p, p + m);
  final xs = _tokens(x), ys = _tokens(y);
  final (xi, yi) = _Tokens.numbered(xs, ys);
  final steps = _myers(xi, yi, maxCost);
  if (steps == null) return _slideToWords(a, [TextEdit(p, n, y)]);
  final edits = <TextEdit>[];
  var i = 0, j = 0, k = 0;
  while (k < steps.length) {
    if (steps[k] == _keep) {
      i++;
      j++;
      k++;
      continue;
    }
    final startI = i, startJ = j;
    while (k < steps.length && steps[k] != _keep) {
      if (steps[k] == _delete) {
        i++;
      } else {
        j++;
      }
      k++;
    }
    final from = xs.starts[startI], to = xs.starts[i];
    edits.add(TextEdit(p + from, to - from, y.substring(ys.starts[startJ], ys.starts[j])));
  }
  return _slideToWords(a, edits);
}

bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
bool _isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;
bool _space(int u) => u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0xA0;
bool _wordChar(int u) => (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u > 0x7F;

/// A text cut into pieces: what is between spaces, a run of spaces, a line break. [starts] has where each begins
/// (and, last, the length).
class _Tokens {
  final List<String> pieces = [];
  final List<int> starts = [];

  /// The pieces as numbers, the same piece the same number in [a] and in [b].
  static (Int32List, Int32List) numbered(_Tokens a, _Tokens b) {
    final seen = <String, int>{};
    int id(String t) => seen.putIfAbsent(t, () => seen.length);
    return (Int32List.fromList([for (final t in a.pieces) id(t)]), Int32List.fromList([for (final t in b.pieces) id(t)]));
  }
}

_Tokens _tokens(String t) {
  final out = _Tokens();
  var i = 0;
  while (i < t.length) {
    final u = t.codeUnitAt(i);
    var j = i + 1;
    if (!_space(u)) {
      // (a word with what sticks to it - `[a:12]`, `**bold**`, `don't` - is one piece: punctuation of one word is never matched with
      // that of another)
      while (j < t.length && !_space(t.codeUnitAt(j))) {
        j++;
      }
    } else if (u != 0x0A) {
      while (j < t.length && _space(t.codeUnitAt(j)) && t.codeUnitAt(j) != 0x0A) {
        j++;
      }
    }
    out.starts.add(i);
    out.pieces.add(t.substring(i, j));
    i = j;
  }
  out.starts.add(t.length);
  return out;
}

/// How well a cut between two characters (null: the end of the text) is a place where a word, a line or a piece of markup begins or
/// ends: 2 beside a space, 1 elsewhere, 0 between two letters.
int _edge(int? x, int? y) {
  if (x == null || y == null) return 2;
  if (_space(x) != _space(y)) return 2;
  if (_wordChar(x) && _wordChar(y)) return 0;
  return 1;
}

/// A pure insertion or deletion can be made at several places that give the same text (put `[b] ` in front of `[b] ` or after it; or
/// `3] [a:` in the middle of `[a:4]`, which is the same thing a few characters on). The place where it begins and ends at the edge
/// of words is the one a person meant, and the one that keeps what others write next to it whole.
List<TextEdit> _slideToWords(String a, List<TextEdit> edits) {
  const reach = 96;
  final out = <TextEdit>[];
  for (var k = 0; k < edits.length; k++) {
    final e = edits[k];
    final inserting = e.removed == 0 && e.inserted.isNotEmpty;
    final deleting = e.inserted.isEmpty && e.removed > 0;
    if (!inserting && !deleting) {
      out.add(e);
      continue;
    }
    final n = inserting ? e.inserted.length : e.removed;
    final lo = k == 0 ? 0 : edits[k - 1].start + edits[k - 1].removed;
    final hi = k == edits.length - 1 ? a.length : edits[k + 1].start;
    // (the piece as it is put in at [q] or cut out of it)
    String pieceAt(int q, String rotated) => inserting ? rotated : a.substring(q, q + n);
    int? at(int q) => q >= 0 && q < a.length ? a.codeUnitAt(q) : null;
    int score(int q, String piece) => _edge(at(q - 1), piece.codeUnitAt(0)) + _edge(piece.codeUnitAt(piece.length - 1), at(inserting ? q : q + n));

    var bestQ = e.start;
    var bestPiece = pieceAt(e.start, e.inserted);
    var bestScore = score(bestQ, bestPiece);
    var bestMove = 0;
    void consider(int q, String rotated, int move) {
      final piece = pieceAt(q, rotated);
      final sc = score(q, piece);
      if (sc > bestScore || (sc == bestScore && move.abs() < bestMove.abs())) {
        bestScore = sc;
        bestQ = q;
        bestPiece = piece;
        bestMove = move;
      }
    }

    // to the right: the first character of the piece is the next one of the text
    var q = e.start;
    var rotated = e.inserted;
    for (var move = 1; move <= reach; move++) {
      final fits = inserting ? q < hi && q < a.length && a.codeUnitAt(q) == rotated.codeUnitAt(0) : q + n < a.length && q + n < hi && a.codeUnitAt(q) == a.codeUnitAt(q + n);
      if (!fits) break;
      if (inserting) rotated = rotated.substring(1) + a[q];
      q++;
      consider(q, rotated, move);
    }
    // to the left: the last character of the piece is the one before it
    q = e.start;
    rotated = e.inserted;
    for (var move = 1; move <= reach; move++) {
      final fits = q > lo && (inserting ? a.codeUnitAt(q - 1) == rotated.codeUnitAt(rotated.length - 1) : a.codeUnitAt(q - 1) == a.codeUnitAt(q + n - 1));
      if (!fits) break;
      if (inserting) rotated = a[q - 1] + rotated.substring(0, rotated.length - 1);
      q--;
      consider(q, rotated, -move);
    }
    out.add(inserting ? TextEdit(bestQ, 0, bestPiece) : TextEdit(bestQ, n, ''));
  }
  return _wholeCharacters(a, out);
}

/// An edit that starts or ends between the two halves of a character of two units is widened to hold all of it (and edits that
/// then touch are made one).
List<TextEdit> _wholeCharacters(String a, List<TextEdit> edits) {
  final out = <TextEdit>[];
  for (final e in edits) {
    var start = e.start, removed = e.removed, put = e.inserted;
    if (start > 0 && start < a.length && _isLow(a.codeUnitAt(start)) && _isHigh(a.codeUnitAt(start - 1))) {
      start--;
      removed++;
      put = a[start] + put;
    }
    final end = start + removed;
    if (end > 0 && end < a.length && _isLow(a.codeUnitAt(end)) && _isHigh(a.codeUnitAt(end - 1))) {
      removed++;
      put = put + a[end];
    }
    if (out.isNotEmpty && out.last.start + out.last.removed >= start) {
      final last = out.removeLast();
      final gap = start - (last.start + last.removed);
      out.add(TextEdit(last.start, (start + removed) - last.start, last.inserted + a.substring(last.start + last.removed, last.start + last.removed + gap) + put));
    } else {
      out.add(TextEdit(start, removed, put));
    }
  }
  return out;
}

const int _keep = 0, _delete = 1, _insert = 2;

/// The shortest script of keeps, deletes and inserts that turns [x] into [y] (Myers), or null when it is longer than [maxCost].
List<int>? _myers(Int32List x, Int32List y, int maxCost) {
  final n = x.length, m = y.length;
  final max = (n + m) < maxCost ? (n + m) : maxCost;
  final offset = max + 1;
  final v = Int32List(2 * max + 3);
  final trace = <Int32List>[];
  for (var d = 0; d <= max; d++) {
    // (what is needed of the table before this round: the part that can be reached, [-d - 1, d + 1])
    trace.add(Int32List.fromList(v.sublist(offset - d - 1, offset + d + 2)));
    for (var k = -d; k <= d; k += 2) {
      int xx;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        xx = v[offset + k + 1];
      } else {
        xx = v[offset + k - 1] + 1;
      }
      var yy = xx - k;
      while (xx < n && yy < m && x[xx] == y[yy]) {
        xx++;
        yy++;
      }
      v[offset + k] = xx;
      if (xx >= n && yy >= m) return _walkBack(trace, d, n, m);
    }
  }
  return null;
}

List<int> _walkBack(List<Int32List> trace, int last, int n, int m) {
  final out = <int>[];
  var xx = n, yy = m;
  for (var d = last; d > 0; d--) {
    final v = trace[d]; // (the table as it was before round d: index k + d + 1)
    int at(int k) => v[k + d + 1];
    final k = xx - yy;
    final int prevK;
    if (k == -d || (k != d && at(k - 1) < at(k + 1))) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = at(prevK), prevY = prevX - prevK;
    while (xx > prevX && yy > prevY) {
      out.add(_keep);
      xx--;
      yy--;
    }
    out.add(xx == prevX ? _insert : _delete);
    if (xx == prevX) {
      yy--;
    } else {
      xx--;
    }
  }
  while (xx > 0 && yy > 0) {
    out.add(_keep);
    xx--;
    yy--;
  }
  return out.reversed.toList();
}

/// [text] with [edits] (as [diffText] gives them) made.
String applyEdits(String text, List<TextEdit> edits) {
  final out = StringBuffer();
  var at = 0;
  for (final e in edits) {
    out.write(text.substring(at, e.start));
    out.write(e.inserted);
    at = e.start + e.removed;
  }
  out.write(text.substring(at));
  return out.toString();
}

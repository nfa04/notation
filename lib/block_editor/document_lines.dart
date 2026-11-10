import 'dart:math' as math;
import 'dart:typed_data';

import '../markdown/markdown_parser.dart';

/// A line of the written document as the block editor has it: every [MdBlock] is one, a blank line too. It keeps its [id] while the text
/// around it changes, so that what is on screen for it stays, and [version] says when its own text changed.
class DocumentLine {
  final int id;

  /// Where it is among the lines.
  int index;

  /// Goes up each time the line's text or block changes.
  int version = 0;

  /// Whether it shows something of the other lines (kept here: asking takes reading the line, and that is asked for at each key).
  bool? dependsOnOthers;

  /// Where the wrapped rows of the line end, down from its top, while it is more than one (null: it is not known, or there is one).
  List<double>? rows;
  bool rowsMoved = false;

  /// Where the line goes over from one sheet of paper to the next: after [at] of its own height comes a [gap] with nothing in it.
  List<({double at, double gap})> breaks = const [];

  /// How much further down than [y], a height in the line, that place is drawn.
  double shift(double y) {
    var by = 0.0;
    for (final b in breaks) {
      if (y >= b.at) by += b.gap;
    }
    return by;
  }

  /// The height in the line drawn at [y] below its top (in a gap: the end of the row above it).
  double natural(double y) {
    var at = y;
    for (final b in breaks) {
      if (at < b.at) return at;
      if (at < b.at + b.gap) return b.at - 1;
      at -= b.gap;
    }
    return at;
  }

  /// The render object of the line, while it has one.
  Object? render;

  /// How tall it is; an estimate until it was laid out once ([measured]).
  double height;
  bool measured = false;

  DocumentLine(this.id, this.index, this.height);
}

/// What an update changed: `[first, end)` are new or changed, and the lines after them were `[first, oldEnd)` before.
class LineChange {
  final int first, end, oldEnd;
  const LineChange(this.first, this.end, this.oldEnd);

  bool get sameCount => end == oldEnd;
}

/// The lines of the written document, with where each one is, down from the top of the text. A key that is pressed changes one of them:
/// the others keep their height, whatever comes before them, and are moved by adding up.
class DocumentLines {
  /// How tall a line that was not laid out yet may be.
  final double Function(MdBlock block) estimate;

  DocumentLines(this.estimate);

  List<MdBlock> blocks = const [];
  final List<DocumentLine> lines = [];
  String _text = '';
  var _nextId = 0;

  Float64List _tops = Float64List(1);

  /// `_tops[0..=_topsGood]` are right.
  var _topsGood = 0;

  int get length => lines.length;

  /// Takes over what [now] says. Null when it is what is here already.
  LineChange? update(ParsedText now) {
    if (identical(now.blocks, blocks)) return null;
    final old = blocks;
    final known = lines.isNotEmpty && now.changedFrom != null && identical(now.previous, _text);
    blocks = now.blocks;
    _text = now.text;
    final first = known ? blockAt(old, now.changedFrom!) : 0;
    final oldEnd = known ? blockAt(old, now.oldTo) + 1 : old.length;
    final end = known ? blockAt(blocks, now.changedTo) + 1 : blocks.length;
    final common = (oldEnd < end ? oldEnd : end) - first;
    // (the lines that stay are told by their place: one that only changed keeps what is on screen for it)
    for (var i = first; i < first + common; i++) {
      lines[i]
        ..version += 1
        ..dependsOnOthers = null
        ..measured = false;
    }
    final at = first + common;
    if (oldEnd > end) {
      lines.removeRange(at, oldEnd);
    } else if (end > oldEnd) {
      lines.insertAll(at, [for (var i = at; i < end; i++) DocumentLine(_nextId++, i, estimate(blocks[i]))]);
    }
    if (oldEnd != end) {
      for (var i = at; i < lines.length; i++) {
        lines[i].index = i;
      }
      _tops = Float64List(lines.length + 1);
      _topsGood = 0;
    } else if (first < _topsGood) {
      _topsGood = first;
    }
    return LineChange(first, end, oldEnd);
  }

  /// [line] is [height] tall. Says how much that changed it.
  double setHeight(DocumentLine line, double height) {
    line.measured = true;
    final change = height - line.height;
    if (change == 0 && !line.rowsMoved) return 0;
    line.rowsMoved = false;
    line.height = height;
    if (line.index < _topsGood) _topsGood = line.index;
    return change;
  }

  /// The sheets of paper the text is on: [room] of text on each, every [step] down from the top of the first (null: it is one long sheet).
  ({double room, double step})? sheets;

  /// How tall a wrapped row of a line that was not laid out yet may be.
  double rowHeight = 24;

  void setSheets(({double room, double step})? now) {
    if (now == sheets) return;
    sheets = now;
    _topsGood = 0;
  }

  /// How many sheets the text is on.
  int get sheetCount {
    final s = sheets;
    return s == null || lines.isEmpty ? 1 : (math.max(0.0, height - 1) / s.step).floor() + 1;
  }

  static const _types = {MdBlockType.table, MdBlockType.math, MdBlockType.rule, MdBlockType.toc, MdBlockType.pageBreak, MdBlockType.bibliography};

  /// The rows line [i] can be cut after.
  List<double> _rowsOf(int i) {
    final line = lines[i];
    if (_types.contains(blocks[i].type)) return [line.height];
    final known = line.rows;
    if (known != null && line.measured) return known;
    if (line.measured || line.height < rowHeight * 1.5) return [line.height];
    return [for (var y = rowHeight; y < line.height - 1; y += rowHeight) y, line.height];
  }

  /// Puts line [i] on the sheets: says where it starts, leaves in it where it goes over to the next sheet, and where it ends.
  (double, double) _place(int i, double from, double room, double step) {
    const slack = 0.5;
    final line = lines[i];
    var y = from;
    double sheet() => (y / step + 1e-9).floor() * step;
    // (a page break ends its sheet, and what is off the end of a sheet is on the next)
    if (i > 0 && blocks[i - 1].type == MdBlockType.pageBreak && y > sheet() + slack) y = sheet() + step;
    if (y >= sheet() + room - slack) y = sheet() + step;
    final top = y;
    final breaks = <({double at, double gap})>[];
    var start = top; // where what is left of the line is
    var done = 0.0;
    var placed = top;
    final rows = _rowsOf(i);
    while (true) {
      y = start;
      final end = sheet() + room;
      if (start + line.height - done <= end + slack) break;
      // the last row that still fits on this sheet
      double? fits;
      for (final r in rows) {
        if (r > done + 0.01 && start + r - done <= end + slack) fits = r;
      }
      if (fits == null) {
        if (start <= sheet() + slack) {
          // a row taller than the sheet: it runs over
          final r = rows.firstWhere((x) => x > done + 0.01, orElse: () => line.height);
          start += r - done;
          done = r;
          if (done >= line.height - 0.01) break;
          y = start;
          final next = sheet() + step;
          breaks.add((at: done, gap: next - start));
          start = next;
        } else if (done == 0) {
          placed = start = sheet() + step;
        } else {
          final next = sheet() + step;
          breaks.add((at: done, gap: next - start));
          start = next;
        }
        continue;
      }
      start += fits - done;
      done = fits;
      y = start;
      final next = sheet() + step;
      breaks.add((at: done, gap: next - start));
      start = next;
    }
    line.breaks = breaks.isEmpty ? const [] : breaks;
    return (placed, start + line.height - done);
  }

  void _tidy(int upTo) {
    final s = sheets;
    for (var i = _topsGood; i < upTo; i++) {
      if (s == null) {
        _tops[i + 1] = _tops[i] + lines[i].height;
      } else {
        final (top, end) = _place(i, i == 0 ? 0 : _ends[i - 1], s.room, s.step);
        _tops[i] = top;
        _ends[i] = end;
        _tops[i + 1] = end;
      }
    }
    if (upTo > _topsGood) _topsGood = upTo;
  }

  /// Where each line ends, on sheets.
  Float64List get _ends {
    if (_endsOf.length < lines.length + 1) _endsOf = Float64List(lines.length + 64);
    return _endsOf;
  }

  Float64List _endsOf = Float64List(1);

  /// Where line [index] starts.
  double topOf(int index) {
    _tidy(math.min(index + 1, lines.length));
    return _tops[index];
  }

  /// How tall the document is.
  double get height {
    _tidy(lines.length);
    return _tops[lines.length];
  }

  /// The line at [y] down from the top of the text.
  int lineAtY(double y) {
    _tidy(lines.length);
    var low = 0, high = lines.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_tops[middle] <= y) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  /// The line the place [offset] of the text is on.
  int lineAt(int offset) => blocks.isEmpty ? 0 : blockAt(blocks, offset);

  /// The first line that was never laid out, from [from] on, going round to the start; null: all were.
  int? firstUnmeasured(int from) {
    for (var i = from; i < lines.length; i++) {
      if (!lines[i].measured) return i;
    }
    for (var i = 0; i < from && i < lines.length; i++) {
      if (!lines[i].measured) return i;
    }
    return null;
  }
}

/// How a line stands in a comparison of two texts.
enum DiffKind { same, added, removed, gap }

class DiffLine {
  final DiffKind kind;
  final String text;
  const DiffLine(this.kind, this.text);

  @override
  String toString() => '${switch (kind) { DiffKind.same => '  ', DiffKind.added => '+ ', DiffKind.removed => '- ', DiffKind.gap => '..' }}$text';
}

/// What differs between the lines of [before] and [after], each change with [context] lines around it (what is between is a
/// [DiffKind.gap]), at most [maxLines] lines in all. Empty when they are the same.
List<DiffLine> lineDiff(String before, String after, {int context = 1, int maxLines = 60}) {
  if (before == after) return const [];
  final a = before.split('\n'), b = after.split('\n');
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final x = a.sublist(head, a.length - tail), y = b.sublist(head, b.length - tail);

  final ops = <DiffLine>[for (final l in a.sublist(0, head)) DiffLine(DiffKind.same, l)];
  if (x.length * y.length > 250000) {
    // (too much to match line by line: all of it is said to have changed)
    ops
      ..addAll(x.map((l) => DiffLine(DiffKind.removed, l)))
      ..addAll(y.map((l) => DiffLine(DiffKind.added, l)));
  } else {
    // the longest run of lines both have, and what is not in it
    final n = x.length, m = y.length;
    final common = List.generate(n + 1, (_) => List.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        common[i][j] = x[i] == y[j] ? common[i + 1][j + 1] + 1 : (common[i + 1][j] >= common[i][j + 1] ? common[i + 1][j] : common[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && x[i] == y[j]) {
        ops.add(DiffLine(DiffKind.same, x[i]));
        i++;
        j++;
      } else if (i < n && (j == m || common[i + 1][j] >= common[i][j + 1])) {
        ops.add(DiffLine(DiffKind.removed, x[i++]));
      } else {
        ops.add(DiffLine(DiffKind.added, y[j++]));
      }
    }
  }
  ops.addAll(a.sublist(a.length - tail).map((l) => DiffLine(DiffKind.same, l)));

  // only the changes and what is next to them
  final near = List.filled(ops.length, false);
  for (var k = 0; k < ops.length; k++) {
    if (ops[k].kind == DiffKind.same) continue;
    for (var d = -context; d <= context; d++) {
      if (k + d >= 0 && k + d < ops.length) near[k + d] = true;
    }
  }
  final out = <DiffLine>[];
  var skipped = 0;
  for (var k = 0; k < ops.length; k++) {
    if (near[k]) {
      // (a gap of one line is no shorter than the line)
      if (skipped == 1) {
        out.add(ops[k - 1]);
      } else if (skipped > 1) {
        out.add(DiffLine(DiffKind.gap, '$skipped'));
      }
      skipped = 0;
      out.add(ops[k]);
    } else {
      skipped++;
    }
  }
  // (what is left over after the last change is not shown, and not counted as a gap)
  if (out.length > maxLines) {
    final more = out.length - maxLines;
    return [...out.take(maxLines), DiffLine(DiffKind.gap, '$more')];
  }
  return out;
}

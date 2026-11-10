import 'dart:ui';

/// Where [alignDeltas] puts things: against the left, the middle (of left and right), the right, the top, the middle (of top and
/// bottom) or the bottom of everything that is aligned.
enum AlignTo { left, centre, right, top, middle, bottom }

/// How far each of [rects] has to move to be aligned [to] the box around all of them.
List<Offset> alignDeltas(List<Rect> rects, AlignTo to) {
  if (rects.isEmpty) return const [];
  var all = rects.first;
  for (final r in rects) {
    all = all.expandToInclude(r);
  }
  return [
    for (final r in rects)
      switch (to) {
        AlignTo.left => Offset(all.left - r.left, 0),
        AlignTo.centre => Offset(all.center.dx - r.center.dx, 0),
        AlignTo.right => Offset(all.right - r.right, 0),
        AlignTo.top => Offset(0, all.top - r.top),
        AlignTo.middle => Offset(0, all.center.dy - r.center.dy),
        AlignTo.bottom => Offset(0, all.bottom - r.bottom),
      },
  ];
}

/// How far each of [rects] has to move to lie in a row ([horizontal]) or a column with the same space between each two: the first and
/// the last (by place) stay where they are. Fewer than three move nothing.
List<Offset> distributeDeltas(List<Rect> rects, {required bool horizontal}) {
  final n = rects.length;
  final none = List.filled(n, Offset.zero);
  if (n < 3) return none;
  double start(Rect r) => horizontal ? r.left : r.top;
  double size(Rect r) => horizontal ? r.width : r.height;
  final order = List.generate(n, (i) => i)..sort((a, b) => (start(rects[a]) + size(rects[a]) / 2).compareTo(start(rects[b]) + size(rects[b]) / 2));
  final first = rects[order.first], last = rects[order.last];
  final span = start(last) + size(last) - start(first);
  final gap = (span - order.map((i) => size(rects[i])).reduce((a, b) => a + b)) / (n - 1);
  final out = List.of(none);
  var at = start(first);
  for (final i in order) {
    final d = at - start(rects[i]);
    out[i] = horizontal ? Offset(d, 0) : Offset(0, d);
    at += size(rects[i]) + gap;
  }
  return out;
}

/// The indexes of [rects] that lie over each other (within [gap] of each other), in groups: a drawing of a few lines is one thing to
/// align, not a few. Each group has its indexes in order, and the groups are in order of their first index.
List<List<int>> overlapGroups(List<Rect> rects, {double gap = 2}) {
  final parent = List.generate(rects.length, (i) => i);
  int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      if (rects[i].inflate(gap).overlaps(rects[j])) parent[find(j)] = find(i);
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < rects.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(i);
  }
  return groups.values.toList()..sort((a, b) => a.first.compareTo(b.first));
}

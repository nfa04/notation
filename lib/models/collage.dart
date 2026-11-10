import 'dart:ui';

/// Where pictures of the [proportions] (width over height) go to fill rows [width] wide, as a mood board is laid out: each
/// row holds as many as fit at about [rowHeight] and is then made as tall as it takes to fill the width exactly, so that the pictures
/// keep their proportions and are all the same height in a row, with [gap] between them. The last row is not stretched if it comes
/// short: its pictures keep [rowHeight]. The rectangles are in the order of the pictures, from (0, 0).
List<Rect> collageRects(List<double> proportions, {required double width, double rowHeight = 170, double gap = 8}) {
  final aspects = [for (final a in proportions) a <= 0 ? 1.0 : a];
  final out = <Rect>[];
  var row = <int>[];
  var top = 0.0;

  void flush({required bool stretch}) {
    if (row.isEmpty) return;
    final gaps = gap * (row.length - 1);
    final natural = row.fold(0.0, (sum, i) => sum + aspects[i]);
    final height = stretch ? (width - gaps) / natural : rowHeight;
    var left = 0.0;
    for (final i in row) {
      final w = aspects[i] * height;
      out.add(Rect.fromLTWH(left, top, w, height));
      left += w + gap;
    }
    top += height + gap;
    row = [];
  }

  for (var i = 0; i < aspects.length; i++) {
    row.add(i);
    final used = row.fold(0.0, (sum, k) => sum + aspects[k] * rowHeight) + gap * (row.length - 1);
    if (used >= width) flush(stretch: true);
  }
  flush(stretch: false);
  return out;
}

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke s(List<Offset> p) => DrawingStroke(color: const Color(0xFF000000), width: 2, points: p);
List<Offset> line(Offset a, Offset b, {int n = 12, double wob = 0, int seed = 1}) {
  final r = math.Random(seed);
  return [for (var i = 0; i <= n; i++) Offset(a.dx + (b.dx - a.dx) * i / n + (r.nextDouble() - .5) * wob, a.dy + (b.dy - a.dy) * i / n + (r.nextDouble() - .5) * wob)];
}

void main() {
  for (final h in [20.0, 30.0, 40.0, 50.0]) {
    for (final gap in [0.2, 0.5, 0.8]) {
      test('1 + 2 = 3, letters $h high, spaces ${gap}x that, is one line', () {
        final w = h * 0.5, g = h * gap;
        var x = 100.0;
        final y = 200.0;
        final st = <DrawingStroke>[];
        // 1
        st.add(s(line(Offset(x + w / 2, y), Offset(x + w / 2, y + h), wob: 1)));
        x += w + g;
        // +
        st.add(s(line(Offset(x, y + h / 2), Offset(x + w, y + h / 2 + 1), wob: 1)));
        st.add(s(line(Offset(x + w / 2, y + h / 4), Offset(x + w / 2, y + h * .75), wob: 1)));
        x += w + g;
        // 2 (curvy)
        st.add(s([for (var i = 0; i <= 20; i++) Offset(x + w * i / 20, y + h * (0.5 + 0.5 * math.sin(i / 20 * 6)))]));
        x += w + g;
        // =
        st.add(s(line(Offset(x, y + h * .35), Offset(x + w, y + h * .37), wob: 1)));
        st.add(s(line(Offset(x, y + h * .65), Offset(x + w, y + h * .62), wob: 1)));
        x += w + g;
        // 3
        st.add(s([for (var i = 0; i <= 20; i++) Offset(x + w * (0.5 + 0.5 * math.sin(i / 20 * 9)), y + h * i / 20)]));
        final cl = clusterStrokes(0, st);
        final rows = [for (final c in cl) ...rowsOf(c)];
        expect(cl, hasLength(1), reason: 'one formula is one cluster');
        expect(rows, hasLength(1), reason: 'and one row');
      });
    }
  }
}

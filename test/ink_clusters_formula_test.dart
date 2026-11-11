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
  group('lines of writing', groups);
  group('joined-up writing', joinedUp);
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

/// A stroke that fills the box from ([left], [top]) to ([right], [bottom]): down one side, up the other.
DrawingStroke box(double left, double top, double right, double bottom) =>
    s([Offset(left, top), Offset(left + (right - left) / 3, bottom), Offset(left + 2 * (right - left) / 3, bottom), Offset(right, top)]);

/// A line of writing from [x0] to [x1]: letters 25 high on the line at [y], every third one small.
List<DrawingStroke> words(double x0, double x1, double y) => [
      for (var x = x0, i = 0; x < x1; x += 20, i++) i % 3 == 2 ? box(x, y + 12, x + 9, y + 23) : box(x, y, x + 12, y + 25),
    ];

void groups() {
  test('the small e of a word under a fraction bar is not the dot of an i in the line below', () {
    final fraction = [
      ...words(100, 250, 845),
      ...words(300, 400, 845),
      s(line(const Offset(290, 883), const Offset(410, 883))),
      box(305, 906, 320, 936), // ρ
      box(335, 912, 350, 928), // M
      box(352, 916, 360, 922), // e
      box(362, 914, 385, 924), // er
    ];
    final below = [...words(30, 340, 952), box(351, 947, 355, 978)]; // ... l (right under the e)
    final lines = linesOfWriting([...fraction, ...below]);
    expect(lines, hasLength(2));
    expect(lines.first.toSet(), fraction.toSet());
    expect(lines.last.toSet(), below.toSet());
  });

  test('an exponent beside a big bracket stays with its formula, though its middle is as high as the line above', () {
    // (k = 1 and k, the limits of a sum on the line above that came into this block, each letter in two strokes)
    final limits = [
      s(line(const Offset(300, 1008), const Offset(301, 1023))), box(302, 1011, 310, 1023),
      s(line(const Offset(314, 1012), const Offset(322, 1012))), s(line(const Offset(314, 1017), const Offset(322, 1017))),
      s(line(const Offset(327, 1008), const Offset(328, 1022))),
      s(line(const Offset(600, 1008), const Offset(601, 1022))), box(602, 1012, 610, 1021),
    ];
    // = a (b c)² + d e f ..., letters 20 high, brackets far taller
    final formula = [
      s(line(const Offset(40, 1053), const Offset(54, 1053))), s(line(const Offset(40, 1060), const Offset(54, 1060))),
      box(70, 1048, 82, 1068), box(90, 1048, 102, 1068),
      s([const Offset(130, 1022), const Offset(118, 1052), const Offset(130, 1082)]), // (
      box(136, 1048, 148, 1068), box(154, 1048, 166, 1068),
      s([const Offset(170, 1022), const Offset(182, 1052), const Offset(170, 1082)]), // )
      box(185, 1021, 194, 1034), // ²
      s(line(const Offset(210, 1058), const Offset(224, 1058))), s(line(const Offset(217, 1051), const Offset(217, 1065))),
      box(240, 1030, 252, 1068), // d
      for (var x = 260.0; x < 520; x += 20) box(x, 1048, x + 12, 1068),
    ];
    final lines = linesOfWriting([...limits, ...formula]);
    expect(lines, hasLength(2));
    expect(lines.first.toSet(), limits.toSet());
    expect(lines.last.toSet(), formula.toSet());
  });
}

/// A joined-up word: one stroke from [x] across [width], small letters 10 high on the line at [y], with an ascender and a descender every
/// [rise] letters.
DrawingStroke joinedWord(double x, double y, double width, {int rise = 3, int seed = 0}) {
  final points = <Offset>[];
  final letters = (width / 12).round();
  for (var i = 0; i < letters; i++) {
    final left = x + i * width / letters;
    final top = (i + seed) % rise == 0 ? y - 26 : y - 10;
    // (and a descender, a g, every [rise] letters too)
    final bottom = (i + seed) % rise == 1 ? y + 12 : y;
    points.addAll([Offset(left, y), Offset(left + 4, top), Offset(left + 8, bottom), Offset(left + 10, y - 3)]);
  }
  return s(points);
}

void joinedUp() {
  test('lines of joined-up writing close together are told apart, a short last line too', () {
    // (a word a stroke, as high as nearly four small letters: lines 32 apart touch, and are less than a word's height apart)
    List<DrawingStroke> lineAt(double y, List<double> widths) {
      var x = 50.0;
      return [
        for (var i = 0; i < widths.length; i++) joinedWord((x += i == 0 ? 0 : widths[i - 1] + 18), y + (i.isEven ? 0 : 1.5), widths[i], seed: i),
      ];
    }

    final lines = [lineAt(60, [70, 90, 110, 80, 100]), lineAt(92, [90, 60, 80, 120, 70]), lineAt(124, [80, 50])];
    final found = linesOfWriting([for (final l in lines) ...l]);
    expect(found, hasLength(3));
    for (var i = 0; i < 3; i++) {
      expect(found[i].toSet(), lines[i].toSet());
    }
  });
}

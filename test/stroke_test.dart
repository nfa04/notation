import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/canvas_models.dart';

void main() {
  test('isNear measures to the segments, not just the points', () {
    final s = DrawingStroke(color: const Color(0xFF000000), width: 2, points: const [Offset(0, 0), Offset(100, 0)]);
    expect(s.isNear(const Offset(50, 5), 5), isTrue); // between the two points
    expect(s.isNear(const Offset(50, 7), 5), false); // 7 > 5 + 1
    expect(s.isNear(const Offset(105, 0), 5), isTrue);
    expect(s.isNear(const Offset(120, 0), 5), isFalse);
  });
}

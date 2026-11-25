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

  test('a quick sweep of the eraser takes a line it passed between two events', () {
    final s = DrawingStroke(color: const Color(0xFF000000), width: 1, points: const [Offset(50, 0), Offset(50, 100)]);
    // two events 60 apart, one on each side of the line: neither is near it, the way between them crosses it
    expect(s.isNear(const Offset(80, 50), 10), isFalse);
    expect(s.isNear(const Offset(80, 50), 10, from: const Offset(20, 50)), isTrue);
    // a way that passes beside the line, not over it
    expect(s.isNear(const Offset(80, 150), 10, from: const Offset(20, 150)), isFalse);
    expect(s.isNear(const Offset(80, 108), 10, from: const Offset(20, 108)), isTrue); // (within reach of its end)
  });
}

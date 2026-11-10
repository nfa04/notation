import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/canvas_models.dart';

void main() {
  const square = [Offset(0, 0), Offset(100, 0), Offset(100, 100), Offset(0, 100)];

  DrawingStroke line(List<Offset> pts) => DrawingStroke(color: const Color(0xFF000000), width: 3, points: pts);

  test('points inside and outside a shape', () {
    expect(pointInPolygon(const Offset(50, 50), square), isTrue);
    expect(pointInPolygon(const Offset(150, 50), square), isFalse);
  });

  test('a stroke is picked when at least half of it is inside', () {
    expect(line(const [Offset(10, 10), Offset(90, 90)]).mostlyInside(square), isTrue);
    expect(line(const [Offset(10, 10), Offset(150, 150), Offset(300, 300)]).mostlyInside(square), isFalse);
    expect(line(const [Offset(200, 10), Offset(300, 90)]).mostlyInside(square), isFalse);
  });

  test('a shape with fewer than three points selects nothing', () {
    expect(line(const [Offset(10, 10)]).mostlyInside(const [Offset(0, 0), Offset(100, 100)]), isFalse);
  });

  test('a long stroke with few points counts by its length', () {
    // mouse-like: three points, the last far outside; most of the length is outside
    final mostlyOut = line(const [Offset(10, 50), Offset(20, 50), Offset(600, 50)]);
    expect(mostlyOut.mostlyInside(square), isFalse); // 2 of 3 points inside, but 10 of 590 units
    // and the other way round: the long part is inside
    final mostlyIn = line(const [Offset(5, 50), Offset(95, 50), Offset(120, 50)]);
    expect(mostlyIn.mostlyInside(square), isTrue);
  });
}

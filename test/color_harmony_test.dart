import 'package:flutter/painting.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/color_harmony.dart';

void main() {
  const red = Color(0xFFFF0000);

  test('complementary is the colour opposite on the wheel', () {
    final c = harmonyOf(red, Harmony.complementary);
    expect(c.first, red);
    expect(c.last.toARGB32(), 0xFF00FFFF);
  });

  test('triadic turns by 120 degrees each way', () {
    final c = harmonyOf(red, Harmony.triadic);
    expect(c.map((x) => x.toARGB32()), [0xFFFF0000, 0xFF00FF00, 0xFF0000FF]);
  });

  test('analogous has the colour in the middle, neighbours at 30 degrees', () {
    final c = harmonyOf(red, Harmony.analogous);
    expect(c[1], red);
    expect(c[0].toARGB32(), 0xFFFF0080);
    expect(c[2].toARGB32(), 0xFFFF8000);
  });

  test('a grey has no hue to turn', () {
    const grey = Color(0xFF808080);
    for (final h in Harmony.values) {
      expect(harmonyOf(grey, h).every((c) => c.toARGB32() == grey.toARGB32()), isTrue);
    }
  });
}

import 'package:flutter/painting.dart';

/// Colour harmonies: sets of colours that go well together, found by turning the hue of a colour round the colour wheel.
enum Harmony { complementary, triadic, analogous }

/// The colours of [kind] built on [base], [base] itself first. Only the hue turns: lightness and saturation stay the colour's own
/// (a grey has no hue to turn, so its harmonies are the grey again).
List<Color> harmonyOf(Color base, Harmony kind) {
  final hsl = HSLColor.fromColor(base);
  Color turned(double degrees) => hsl.withHue((hsl.hue + degrees) % 360).toColor();
  final turns = switch (kind) {
    Harmony.complementary => const [0.0, 180.0],
    Harmony.triadic => const [0.0, 120.0, 240.0],
    Harmony.analogous => const [-30.0, 0.0, 30.0],
  };
  return [
    for (final t in turns)
      if (t == 0) base else turned(t < 0 ? t + 360 : t),
  ];
}

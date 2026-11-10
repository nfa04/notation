import 'package:flutter/painting.dart';

import '../l10n/language.dart';

const _names = <(String, int)>[
  ('Black', 0xFF000000),
  ('Dark grey', 0xFF505050),
  ('Grey', 0xFF9E9E9E),
  ('White', 0xFFFFFFFF),
  ('Red', 0xFFE53935),
  ('Red', 0xFFFF5252),
  ('Red', 0xFFD50000),
  ('Orange', 0xFFFF9800),
  ('Yellow', 0xFFFFEB3B),
  ('Green', 0xFF43A047),
  ('Green', 0xFF4CAF50),
  ('Teal', 0xFF009688),
  ('Cyan', 0xFF00BCD4),
  ('Blue', 0xFF2962FF),
  ('Blue', 0xFF448AFF),
  ('Blue', 0xFF2196F3),
  ('Dark blue', 0xFF1A237E),
  ('Purple', 0xFF8E24AA),
  ('Pink', 0xFFEC407A),
  ('Brown', 0xFF795548),
];

/// What to call [c] to someone who cannot see it: the nearest of a few colour names (see-through colours say so).
String colorName(Color c) {
  var best = _names.first;
  var bestDistance = double.infinity;
  for (final n in _names) {
    final o = Color(n.$2);
    final dr = c.r - o.r, dg = c.g - o.g, db = c.b - o.b;
    // (the eye is most sensitive to green)
    final d = dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11;
    if (d < bestDistance) {
      bestDistance = d;
      best = n;
    }
  }
  final name = tr(best.$1);
  return c.a < 0.95 ? tr('{color}, see-through', {'color': name}) : name;
}

import 'dart:ui';

/// How the border of an event, task or day marker is drawn.
enum BorderKind {
  none('None'),
  solid('Solid'),
  dashed('Dashed'),
  dotted('Dotted'),

  /// A thick bar on the left edge.
  accent('Left bar');

  final String label;
  const BorderKind(this.label);

  static BorderKind? byName(String? name) {
    for (final k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// What the user customised on one calendar, event, task or day. Anything
/// left null falls back to the next level (see [StyleResolver]).
class ItemStyle {
  final Color? color;
  final BorderKind? border;
  final String? emoji;

  const ItemStyle({this.color, this.border, this.emoji});

  bool get isEmpty => color == null && border == null && (emoji == null || emoji!.isEmpty);

  ItemStyle copyWith({Color? color, BorderKind? border, String? emoji, bool clearColor = false, bool clearBorder = false, bool clearEmoji = false}) =>
      ItemStyle(
        color: clearColor ? null : (color ?? this.color),
        border: clearBorder ? null : (border ?? this.border),
        emoji: clearEmoji ? null : (emoji ?? this.emoji),
      );

  @override
  bool operator ==(Object other) =>
      other is ItemStyle && other.color == color && other.border == border && other.emoji == emoji;

  @override
  int get hashCode => Object.hash(color, border, emoji);
}

/// The look that applies to everything in the calendar that has no look of
/// its own. (The accent colour is not part of it: it belongs to the whole app,
/// see [AppTheme].)
class CalendarTheme {
  /// Page background of the calendar; null = the app's usual background.
  final Color? background;

  /// Corner radius of events, tasks and day cells.
  final double radius;
  final BorderKind border;
  final double borderWidth;

  /// Colours handed out to calendars that have none of their own.
  final List<Color> palette;

  /// Use [palette] for every calendar instead of the colours the servers or
  /// the phone report.
  final bool paletteOverridesServerColors;

  const CalendarTheme({
    this.background,
    this.radius = 6,
    this.border = BorderKind.accent,
    this.borderWidth = 2,
    this.palette = defaultPalette,
    this.paletteOverridesServerColors = false,
  });

  static const defaultPalette = [
    Color(0xFF4285F4),
    Color(0xFF34A853),
    Color(0xFFF9AB00),
    Color(0xFFE8710A),
    Color(0xFFA142F4),
    Color(0xFFD93025),
    Color(0xFF000000),
  ];

  /// The look the app had before customisation existed.
  static const standard = CalendarTheme();

  CalendarTheme copyWith({
    Color? background,
    bool clearBackground = false,
    double? radius,
    BorderKind? border,
    double? borderWidth,
    List<Color>? palette,
    bool? paletteOverridesServerColors,
  }) =>
      CalendarTheme(
        background: clearBackground ? null : (background ?? this.background),
        radius: radius ?? this.radius,
        border: border ?? this.border,
        borderWidth: borderWidth ?? this.borderWidth,
        palette: palette ?? this.palette,
        paletteOverridesServerColors: paletteOverridesServerColors ?? this.paletteOverridesServerColors,
      );

  Map<String, Object?> toJson() => {
        'background': background?.toARGB32(),
        'radius': radius,
        'border': border.name,
        'borderWidth': borderWidth,
        'palette': [for (final c in palette) c.toARGB32()],
        'paletteOverrides': paletteOverridesServerColors,
      };

  /// Reads a saved theme; anything missing or broken falls back to the standard.
  static CalendarTheme fromJson(Map<String, Object?> json) {
    Color? color(Object? v) => v is int ? Color(v) : null;
    final palette = json['palette'];
    return CalendarTheme(
      background: color(json['background']),
      radius: (json['radius'] as num?)?.toDouble() ?? standard.radius,
      border: BorderKind.byName(json['border'] as String?) ?? standard.border,
      borderWidth: (json['borderWidth'] as num?)?.toDouble() ?? standard.borderWidth,
      palette: palette is List && palette.isNotEmpty
          ? [for (final c in palette) if (color(c) != null) color(c)!]
          : defaultPalette,
      paletteOverridesServerColors: json['paletteOverrides'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarTheme &&
      other.background == background &&
      other.radius == radius &&
      other.border == border &&
      other.borderWidth == borderWidth &&
      other.paletteOverridesServerColors == paletteOverridesServerColors &&
      _sameColors(other.palette, palette);

  @override
  int get hashCode => Object.hash(background, radius, border, borderWidth, paletteOverridesServerColors, Object.hashAll(palette));

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A named theme to start from.
class ThemePreset {
  final String name;
  final String emoji;
  final CalendarTheme theme;

  const ThemePreset(this.name, this.emoji, this.theme);
}

const themePresets = [
  ThemePreset('Classic', '📅', CalendarTheme.standard),
  ThemePreset(
    'Sakura',
    '🌸',
    CalendarTheme(
      background: Color(0xFFFFF4F8),
      radius: 14,
      border: BorderKind.dashed,
      borderWidth: 1.6,
      palette: [Color(0xFFF48FB1), Color(0xFFCE93D8), Color(0xFFFFAB91), Color(0xFFF8BBD0), Color(0xFFB39DDB), Color(0xFFFFCC80)],
      paletteOverridesServerColors: true,
    ),
  ),
  ThemePreset(
    'Matcha',
    '🍵',
    CalendarTheme(
      background: Color(0xFFF4F9F1),
      radius: 10,
      border: BorderKind.solid,
      borderWidth: 1.5,
      palette: [Color(0xFF8BC48A), Color(0xFFC5D86D), Color(0xFFA5D6C4), Color(0xFFE6C98F), Color(0xFF9CB8A0), Color(0xFFD8A7A0)],
      paletteOverridesServerColors: true,
    ),
  ),
  ThemePreset(
    'Lavender',
    '💜',
    CalendarTheme(
      background: Color(0xFFF7F4FD),
      radius: 16,
      border: BorderKind.dotted,
      borderWidth: 2.2,
      palette: [Color(0xFFB4A7D6), Color(0xFF9FC5E8), Color(0xFFD5A6BD), Color(0xFFA2C4C9), Color(0xFFCFE2F3), Color(0xFFEAD1DC)],
      paletteOverridesServerColors: true,
    ),
  ),
  ThemePreset(
    'Peach',
    '🍑',
    CalendarTheme(
      background: Color(0xFFFFF6EF),
      radius: 12,
      border: BorderKind.solid,
      borderWidth: 2,
      palette: [Color(0xFFFFB38A), Color(0xFFFFD88A), Color(0xFFF4A6A6), Color(0xFFB5D8B0), Color(0xFFF7C6D9), Color(0xFFA8D0E6)],
      paletteOverridesServerColors: true,
    ),
  ),
  ThemePreset(
    'Ocean',
    '🌊',
    CalendarTheme(
      background: Color(0xFFF1F8FD),
      radius: 8,
      border: BorderKind.accent,
      borderWidth: 3,
      palette: [Color(0xFF5BB5E8), Color(0xFF4DB6AC), Color(0xFF7986CB), Color(0xFF81C7E5), Color(0xFF26A69A), Color(0xFF9FA8DA)],
      paletteOverridesServerColors: true,
    ),
  ),
];

/// Colours to pick from in the style dialogs.
const swatchColors = [
  Color(0xFFF48FB1), Color(0xFFEC6FA3), Color(0xFFE57373), Color(0xFFFF8A65),
  Color(0xFFFFB38A), Color(0xFFFFCC80), Color(0xFFFFD54F), Color(0xFFE6EE9C),
  Color(0xFFAED581), Color(0xFF81C784), Color(0xFF80CBC4), Color(0xFF80DEEA),
  Color(0xFF81D4FA), Color(0xFF64B5F6), Color(0xFF9FA8DA), Color(0xFFB39DDB),
  Color(0xFFCE93D8), Color(0xFFBCAAA4), Color(0xFFB0BEC5), Color(0xFF607D8B),
];

/// Emoji offered in the style dialogs (any other can be typed).
const cuteEmoji = [
  '🌸', '🌷', '🌼', '🍀', '🌈', '⭐', '✨', '💖', '💜', '💙',
  '🍓', '🍑', '🍒', '🍵', '🧁', '🍰', '🎀', '🦋', '🐱', '🐰',
  '🐻', '🌙', '☀️', '☁️', '📚', '✏️', '🎓', '💻', '🎵', '🎮',
  '🏃', '🧘', '🛒', '🎂', '✈️', '🏠', '💌', '🔔', '🎨', '☕',
];

/// A stable number for [text]: Dart's own hashCode may differ between runs,
/// and a calendar must keep its colour.
int stableHash(String text) {
  var h = 0x811C9DC5;
  for (final unit in text.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0x7FFFFFFF;
  }
  return h;
}

/// A server's calendar colour ("#RRGGBB", "#RRGGBBAA" or without the #), if valid.
Color? parseCalendarColor(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  if (h.length != 6 && h.length != 8) return null;
  final value = int.tryParse(h.substring(0, 6), radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

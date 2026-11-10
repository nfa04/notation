import 'package:flutter/material.dart';

import '../data/settings_repository.dart';

/// What the person needs to see and use the app comfortably, on top of what the system already offers (the system's text size,
/// bold text and reduced motion are followed; these can only add to them).
class AccessibilitySettings extends ChangeNotifier {
  static const _kScale = 'a11y_text_scale';
  static const _kContrast = 'a11y_contrast';
  static const _kMotion = 'a11y_reduce_motion';
  static const _kBold = 'a11y_bold';
  static const _kTargets = 'a11y_big_targets';
  static const _kRoomy = 'a11y_roomy_text';

  static const minScale = 0.8, maxScale = 2.0;

  final SettingsRepository? _settings;

  AccessibilitySettings(SettingsRepository this._settings);

  /// Remembers nothing: for tests and previews.
  AccessibilitySettings.inMemory({double textScale = 1, bool highContrast = false, bool reduceMotion = false, bool boldText = false, bool bigTargets = false, bool roomyText = false})
      : _settings = null,
        _textScale = textScale,
        _highContrast = highContrast,
        _reduceMotion = reduceMotion,
        _boldText = boldText,
        _bigTargets = bigTargets,
        _roomyText = roomyText;

  double _textScale = 1;
  bool _highContrast = false, _reduceMotion = false, _boldText = false, _bigTargets = false, _roomyText = false;

  /// How much bigger (or smaller) the text of the app is than the system makes it.
  double get textScale => _textScale;

  /// Stronger colours, text and borders.
  bool get highContrast => _highContrast;

  /// No sliding and fading between screens.
  bool get reduceMotion => _reduceMotion;

  bool get boldText => _boldText;

  /// Buttons with more room around them.
  bool get bigTargets => _bigTargets;

  /// More room between lines, words and letters (easier to follow for people with dyslexia or low vision).
  bool get roomyText => _roomyText;

  /// Whether anything differs from how the app comes.
  bool get changed => _textScale != 1 || _highContrast || _reduceMotion || _boldText || _bigTargets || _roomyText;

  Future<void> load() async {
    final s = _settings;
    if (s == null) return;
    _textScale = (double.tryParse(await s.get(_kScale) ?? '') ?? 1).clamp(minScale, maxScale);
    _highContrast = await s.get(_kContrast) == '1';
    _reduceMotion = await s.get(_kMotion) == '1';
    _boldText = await s.get(_kBold) == '1';
    _bigTargets = await s.get(_kTargets) == '1';
    _roomyText = await s.get(_kRoomy) == '1';
  }

  Future<void> _put(String key, String value) async {
    notifyListeners();
    await _settings?.set(key, value);
  }

  Future<void> setTextScale(double v) {
    _textScale = v.clamp(minScale, maxScale);
    return _put(_kScale, '$_textScale');
  }

  Future<void> setHighContrast(bool v) {
    _highContrast = v;
    return _put(_kContrast, v ? '1' : '0');
  }

  Future<void> setReduceMotion(bool v) {
    _reduceMotion = v;
    return _put(_kMotion, v ? '1' : '0');
  }

  Future<void> setBoldText(bool v) {
    _boldText = v;
    return _put(_kBold, v ? '1' : '0');
  }

  Future<void> setBigTargets(bool v) {
    _bigTargets = v;
    return _put(_kTargets, v ? '1' : '0');
  }

  Future<void> setRoomyText(bool v) {
    _roomyText = v;
    return _put(_kRoomy, v ? '1' : '0');
  }

  /// The system's own settings with these added: text as big as both ask for together, motion off if either wants it, bold if either.
  MediaQueryData apply(MediaQueryData system) => system.copyWith(
        textScaler: _textScale == 1 ? system.textScaler : _Scaled(system.textScaler, _textScale),
        disableAnimations: system.disableAnimations || _reduceMotion,
        boldText: system.boldText || _boldText,
        highContrast: system.highContrast || _highContrast,
      );

  /// A colour scheme for [seed]: with more contrast when asked for.
  ColorScheme scheme(Color seed, Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: seed, brightness: brightness, contrastLevel: _highContrast ? 1.0 : 0.0);

  /// [base] with the touch targets and the transitions this asks for.
  ThemeData theme(ThemeData base) {
    var t = base;
    if (_bigTargets) {
      t = t.copyWith(
        visualDensity: VisualDensity.comfortable,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(52, 52), tapTargetSize: MaterialTapTargetSize.padded)),
        listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
        iconTheme: t.iconTheme.copyWith(size: 28),
        chipTheme: t.chipTheme.copyWith(padding: const EdgeInsets.all(10)),
        navigationRailTheme: t.navigationRailTheme.copyWith(minWidth: 80, minExtendedWidth: 220),
      );
    }
    if (_roomyText) {
      t = t.copyWith(textTheme: _roomy(t.textTheme), primaryTextTheme: _roomy(t.primaryTextTheme));
    }
    if (_reduceMotion) {
      t = t.copyWith(pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _NoTransition(),
        TargetPlatform.iOS: _NoTransition(),
        TargetPlatform.linux: _NoTransition(),
        TargetPlatform.macOS: _NoTransition(),
        TargetPlatform.windows: _NoTransition(),
        TargetPlatform.fuchsia: _NoTransition(),
      }));
    }
    if (_highContrast) {
      t = t.copyWith(
        dividerTheme: DividerThemeData(color: t.colorScheme.onSurface.withValues(alpha: 0.6), thickness: 1.5),
        inputDecorationTheme: const InputDecorationTheme(enabledBorder: OutlineInputBorder(borderSide: BorderSide(width: 1.5))),
        // what is outlined, focused or selected stands out from what is not
        outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(side: BorderSide(color: t.colorScheme.onSurface, width: 1.5))),
        cardTheme: t.cardTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: t.colorScheme.onSurface.withValues(alpha: 0.6)))),
        focusColor: t.colorScheme.primary.withValues(alpha: 0.35),
        hoverColor: t.colorScheme.primary.withValues(alpha: 0.2),
        listTileTheme: t.listTileTheme.copyWith(selectedTileColor: t.colorScheme.primary.withValues(alpha: 0.18)),
        textTheme: _stronger(t.textTheme, t.colorScheme.onSurface),
      );
    }
    return t;
  }
}

/// [base] with 1.5 times the line height and a little space between letters and words.
TextTheme _roomy(TextTheme base) {
  TextStyle? r(TextStyle? s) => s?.copyWith(height: 1.5, letterSpacing: (s.letterSpacing ?? 0) + 0.3, wordSpacing: 2);
  return base.copyWith(
    displayLarge: r(base.displayLarge), displayMedium: r(base.displayMedium), displaySmall: r(base.displaySmall),
    headlineLarge: r(base.headlineLarge), headlineMedium: r(base.headlineMedium), headlineSmall: r(base.headlineSmall),
    titleLarge: r(base.titleLarge), titleMedium: r(base.titleMedium), titleSmall: r(base.titleSmall),
    bodyLarge: r(base.bodyLarge), bodyMedium: r(base.bodyMedium), bodySmall: r(base.bodySmall),
    labelLarge: r(base.labelLarge), labelMedium: r(base.labelMedium), labelSmall: r(base.labelSmall),
  );
}

/// [base] with the colour of its text fully the colour of the text (no softer greys).
TextTheme _stronger(TextTheme base, Color color) => base.apply(bodyColor: color, displayColor: color);

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) => child;
}

/// The system's text scaling, then ours on top.
class _Scaled extends TextScaler {
  final TextScaler base;
  final double factor;
  const _Scaled(this.base, this.factor);

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  double get textScaleFactor => base.scale(1) * factor;

  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = double.infinity}) =>
      TextScaler.linear((base.scale(1) * factor).clamp(minScaleFactor, maxScaleFactor));

  @override
  bool operator ==(Object other) => other is _Scaled && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

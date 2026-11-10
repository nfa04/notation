import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/settings_repository.dart';
import 'platform_look.dart';

/// How the whole app looks, as opposed to [CalendarTheme] which only dresses
/// the calendar.
class AppTheme extends ChangeNotifier {
  static const _kAccent = 'app_accent';
  static const _kLook = 'app_platform_look';

  /// The colour the app has had from the start.
  static const defaultAccent = Color(0xFF4285F4);

  final SettingsRepository? _settings;

  AppTheme(SettingsRepository this._settings);

  /// Remembers nothing: for tests and previews.
  AppTheme.inMemory([Color accent = defaultAccent])
      : _settings = null,
        _accent = accent;

  Color _accent = defaultAccent;

  /// Colours buttons, selections and markers in every part of the app.
  Color get accent => _accent;

  PlatformLook _look = PlatformLook.automatic;

  /// Whether the app is dressed like an iPhone app, like a Material one, or like the system it runs on.
  PlatformLook get look => _look;

  Future<void> load() async {
    final settings = _settings;
    if (settings == null) return;
    _look = PlatformLook.fromName(await settings.get(_kLook));
    final saved = await settings.get(_kAccent);
    if (saved != null) {
      _accent = Color(int.tryParse(saved) ?? defaultAccent.toARGB32());
      return;
    }
    // Until now the accent was saved inside the calendar theme: keep the
    // colour that was picked there.
    final legacy = await settings.get('calendar_theme');
    if (legacy != null) {
      try {
        final accent = (jsonDecode(legacy) as Map)['accent'];
        if (accent is int) _accent = Color(accent);
      } catch (_) {
        // unreadable: keep the default
      }
    }
  }

  Future<void> setAccent(Color color) async {
    if (color == _accent) return;
    _accent = color;
    notifyListeners();
    await _settings?.set(_kAccent, '${color.toARGB32()}');
  }

  Future<void> setLook(PlatformLook look) async {
    if (look == _look) return;
    _look = look;
    notifyListeners();
    await _settings?.set(_kLook, look.name);
}
}

import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import 'german.dart';

/// The translation tables, by language code (English is the text in the code).
const _tables = {'de': germanTexts};

/// The language of the app: what the person chose in the settings, or the language of the device.
///
/// The words of the app are written in English in the code; [tr] looks each one up in the
/// translation of the language in use and falls back to the English text, so a missing
/// translation shows English rather than nothing.
class AppLanguage extends ChangeNotifier {
  static const _key = 'app_language';

  /// The one the app uses. Tests that need another make their own with [AppLanguage.inMemory].
  static AppLanguage instance = AppLanguage.inMemory();

  /// The languages the app comes in, by code, with their name in their own language.
  static const names = {'en': 'English', 'de': 'Deutsch'};

  static const supportedLocales = [Locale('en'), Locale('de')];

  final SettingsRepository? _settings;

  AppLanguage(SettingsRepository this._settings);

  /// Remembers nothing: for tests and previews.
  AppLanguage.inMemory([String choice = 'system']) : _settings = null, _choice = choice;

  String _choice = 'system';

  /// "system" (follow the device) or a language code.
  String get choice => _choice;

  /// The language in use, as a code.
  String get code {
    if (names.containsKey(_choice)) return _choice;
    final device = PlatformDispatcher.instance.locale.languageCode;
    return names.containsKey(device) ? device : 'en';
  }

  Locale get locale => Locale(code);

  Future<void> load() async {
    final saved = await _settings?.get(_key);
    if (saved != null && (saved == 'system' || names.containsKey(saved))) _choice = saved;
  }

  Future<void> choose(String choice) async {
    if (choice == _choice) return;
    _choice = choice;
    await _settings?.set(_key, choice);
    notifyListeners();
  }
}

/// [text] in the language in use. `{name}` places in the text are filled from [args].
String tr(String text, [Map<String, Object?>? args]) {
  var out = text;
  out = _tables[AppLanguage.instance.code]?[text] ?? text;
  if (args != null) {
    for (final e in args.entries) {
      out = out.replaceAll('{${e.key}}', '${e.value}');
    }
  }
  return out;
}

/// One or many: [one] for 1, else [many]; both have `{n}`.
String trCount(int n, String one, String many) => tr(n == 1 ? one : many, {'n': n});

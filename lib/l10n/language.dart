import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import 'french.dart';
import 'german.dart';
import 'italian.dart';
import 'spanish.dart';

/// A language the app can come in: its code, its name in its own language and its translation table (English text -> text).
class LanguageEntry {
  final String code, name;
  final Map<String, String> texts;
  const LanguageEntry(this.code, this.name, this.texts);
}

/// The languages besides English. To add one: make `lib/l10n/<language>.dart` with its table and put it here (`docs/translating.md`).
/// A language whose table is still empty is not offered, so a table can be started without showing an English app under another name.
const languageEntries = [
  LanguageEntry('de', 'Deutsch', germanTexts),
  LanguageEntry('fr', 'Français', frenchTexts),
  LanguageEntry('es', 'Español', spanishTexts),
  LanguageEntry('it', 'Italiano', italianTexts),
];

/// The translation tables of the languages that are offered, by language code (English is the text in the code).
final _tables = {for (final l in languageEntries) if (l.texts.isNotEmpty) l.code: l.texts};

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
  static Map<String, String> get names => {'en': 'English', for (final l in languageEntries) if (l.texts.isNotEmpty) l.code: l.name};

  static List<Locale> get supportedLocales => [for (final code in names.keys) Locale(code)];

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

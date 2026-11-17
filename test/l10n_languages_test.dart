import 'package:flutter_test/flutter_test.dart';
import 'package:notes/l10n/german.dart';
import 'package:notes/l10n/language.dart';

Set<String> placeholders(String text) => {for (final m in RegExp(r'\{[A-Za-z0-9_]+\}').allMatches(text)) m.group(0)!};

void main() {
  group('the tables of the languages', () {
    for (final language in languageEntries) {
      test('${language.code}: only English texts of the app as keys, nothing empty, the {placeholders} unchanged', () {
        final stale = [for (final k in language.texts.keys) if (!germanTexts.containsKey(k)) k];
        final empty = [for (final e in language.texts.entries) if (e.value.trim().isEmpty) e.key];
        final changed = [for (final e in language.texts.entries) if (!(placeholders(e.key).containsAll(placeholders(e.value)) && placeholders(e.value).containsAll(placeholders(e.key)))) e.key];
        expect(stale, isEmpty, reason: 'keys that are no English text of the app (misspelt, or gone from the code)');
        expect(empty, isEmpty);
        expect(changed, isEmpty, reason: 'a {placeholder} was changed, dropped or added');
      });
    }

    test('a language is offered once it has texts, not before', () {
      expect(AppLanguage.names.keys, contains('en'));
      expect(AppLanguage.names.keys, contains('de'));
      for (final l in languageEntries) {
        expect(AppLanguage.names.containsKey(l.code), l.texts.isNotEmpty, reason: l.code);
      }
      expect(AppLanguage.supportedLocales.map((l) => l.languageCode), AppLanguage.names.keys);
    });

    test('a text missing from a language is shown in English', () {
      final before = AppLanguage.instance;
      addTearDown(() => AppLanguage.instance = before);
      AppLanguage.instance = AppLanguage.inMemory('de');
      expect(tr('Cancel'), germanTexts['Cancel'] ?? 'Cancel');
      expect(tr('A text no table has'), 'A text no table has');
      expect(tr('{n} apples', {'n': 3}), contains('3'));
    });
  });
}

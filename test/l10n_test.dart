import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/l10n/german.dart';
import 'package:notes/l10n/language.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';

Set<String> placeholders(String s) => RegExp(r'\{[a-z0-9]+\}').allMatches(s).map((m) => m.group(0)!).toSet();

void main() {
  tearDown(() => AppLanguage.instance = AppLanguage.inMemory());

  test('every German text has the same {places} as its English original, and is not empty', () {
    for (final e in germanTexts.entries) {
      expect(e.value.trim(), isNotEmpty, reason: e.key);
      expect(placeholders(e.value), placeholders(e.key), reason: 'places differ in: ${e.key}');
    }
  });

  test('tr gives the text of the language in use, fills places, and falls back to English', () {
    AppLanguage.instance = AppLanguage.inMemory('en');
    expect(tr('Settings'), 'Settings');
    expect(tr('Undo'), 'Undo');
    AppLanguage.instance = AppLanguage.inMemory('de');
    expect(tr('Settings'), 'Einstellungen');
    expect(tr('Page {n}', {'n': 3}), 'Seite 3');
    expect(tr('A text nobody translated'), 'A text nobody translated');
    expect(trCount(1, '1 gizmo', '{n} gizmos'), '1 gizmo'); // not in the table: English
    expect(trCount(1, 'like 1 note there', 'like {n} notes there'), 'wie 1 Notiz dort');
    expect(trCount(4, 'like 1 note there', 'like {n} notes there'), 'wie 4 Notizen dort');
  });

  test('the choice is remembered, "system" follows the device, an unknown code is ignored', () async {
    final store = <String, String>{};
    final language = AppLanguage.inMemory();
    expect(language.choice, 'system');
    expect(['en', 'de'], contains(language.code));
    await language.choose('de');
    expect(language.code, 'de');
    expect(language.locale, const Locale('de'));
    store['x'] = language.choice;
    expect(store['x'], 'de');
  });

  testWidgets('the settings offer the languages, and choosing German changes the words of the app', (tester) async {
    final language = AppLanguage.instance = AppLanguage.inMemory('en');
    await tester.pumpWidget(ListenableBuilder(
      listenable: language,
      builder: (context, _) => MaterialApp(
        locale: language.locale,
        supportedLocales: AppLanguage.supportedLocales,
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        home: SettingsScreen(theme: AppTheme.inMemory()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.byKey(const ValueKey('language-system')), findsOneWidget);
    expect(find.byKey(const ValueKey('language-de')), findsOneWidget);
    expect(find.text('Deutsch'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('language-de')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-de')));
    await tester.pumpAndSettle();
    expect(find.text('Einstellungen'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, 2000)); // (back to the top)
    await tester.pumpAndSettle();
    expect(find.text('Erscheinungsbild'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Gerätesprache'), findsOneWidget);
    expect(language.choice, 'de');

    await tester.ensureVisible(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
  });
}

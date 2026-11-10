import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/spelling/spell_service.dart';
import 'package:notes/style/app_theme.dart';

void main() {
  testWidgets('the settings are in tabs by category; one with nothing in it is not there', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory())));
    expect(find.byType(TabBar), findsNothing, reason: 'only "General": no tabs');
    expect(find.text('Accent color'), findsOneWidget);
  });

  testWidgets('each category has its own tab', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final features = FeatureSettings((k) async => null, (k, v) async {});
    final spell = SpellService((k) async => null, (k, v) async {}, languages: const [DictionaryLanguage('en_US', 'English', 'en', 'en_US', 1)]);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), features: features, spell: spell)));
    expect(find.byKey(const ValueKey('settings-tab-General')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-tab-Tools and writing')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-tab-AI and models')), findsNothing, reason: 'nothing of it here');

    expect(find.text('Accent color'), findsOneWidget);
    expect(find.text('Spell checking'), findsNothing, reason: 'that is under the tools');
    await tester.tap(find.byKey(const ValueKey('settings-tab-Tools and writing')));
    await tester.pumpAndSettle();
    expect(find.text('Accent color'), findsNothing);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Spell checking'), findsWidgets);
  });
}

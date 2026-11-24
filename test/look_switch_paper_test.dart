import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/paper_look.dart';
import 'package:notes/style/platform_look.dart';

void main() {
  setUpAll(AppDatabase.initFfi);
  for (final b in Brightness.values) {
  testWidgets('switching the look in the settings under the paper look does not throw ($b)', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppTheme.inMemory();
    await tester.pumpWidget(ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        var t = paperLook(ThemeData(useMaterial3: true, brightness: b, colorScheme: ColorScheme.fromSeed(seedColor: app.accent, brightness: b)));
        if (app.look.isIos) t = iosLook(t);
        return MaterialApp(theme: t, home: SettingsScreen(theme: app));
      },
    ));
    await tester.tap(find.byKey(const ValueKey('advanced-Advanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('platform-look')), matching: find.text('iOS')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('platform-look')), matching: find.text('Material')));
    await tester.pumpAndSettle();
  });
  }
}

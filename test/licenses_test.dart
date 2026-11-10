import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/legal/bundled_licenses.dart';
import 'package:notes/screens/about_settings.dart' show privacyPolicyUrl;
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';

void main() {
  test('every text of the bundled licences is in the app and not empty', () async {
    for (final l in bundledLicenses) {
      expect((await rootBundle.loadString(l.asset)).trim(), isNotEmpty, reason: l.asset);
    }
  });

  test('the licences of the fonts and the native libraries are added to the ones of Flutter', () async {
    registerBundledLicenses();
    final packages = <String>{};
    await for (final entry in LicenseRegistry.licenses) {
      packages.addAll(entry.packages);
    }
    for (final l in bundledLicenses) {
      expect(packages, contains(l.package));
    }
  });

  testWidgets('the settings open the page of the licences', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory())));
    await tester.tap(find.byKey(const ValueKey('about-licences')));
    // (the page shows a spinner while it reads the licences, so it never settles)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Notation'), findsWidgets);
  });

  testWidgets('the settings have a button to the privacy policy', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory())));
    expect(find.byKey(const ValueKey('about-privacy')), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(privacyPolicyUrl.scheme, 'https');
    expect(privacyPolicyUrl.path, endsWith('docs/privacy.md'));
  });
}

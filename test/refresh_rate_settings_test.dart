import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/refresh_rate_settings.dart';
import 'package:notes/style/refresh_rate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  /// What the Android side was told, in order.
  List<Map<Object?, Object?>> listen(WidgetTester tester) {
    final told = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(displayChannel, (call) async {
      if (call.method == 'highRefresh') told.add(call.arguments as Map<Object?, Object?>);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(displayChannel, null));
    return told;
  }

  // (the settings are in the database: each of its steps needs a turn of the real loop, then one of the test's)
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('off unless turned on; the battery level is chosen once it is on, and each change goes to Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final told = listen(tester);
    late NoteRepository repo;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      await repo.settings.set(highRefreshSetting, '');
      await repo.settings.set(highRefreshBatterySetting, '');
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RefreshRateSettings(repository: repo)))));
    await settle(tester);

    final toggle = find.byKey(const ValueKey('high-refresh'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse, reason: 'not ticked by default');
    expect(tester.widget<DropdownMenu<int?>>(find.byKey(const ValueKey('high-refresh-battery'))).enabled, isFalse);

    await tester.tap(toggle);
    await settle(tester);
    expect(told.last, {'on': true, 'offBelowBattery': null});
    expect(await tester.runAsync(() => repo.settings.get(highRefreshSetting)), '1');
    expect(tester.widget<DropdownMenu<int?>>(find.byKey(const ValueKey('high-refresh-battery'))).enabled, isTrue);

    await tester.tap(find.byKey(const ValueKey('high-refresh-battery')));
    await tester.pumpAndSettle();
    // (the menu also lays out every label out of sight, to know how wide it is: the one on screen is tapped)
    await tester.tap(find.widgetWithText(MenuItemButton, '20 %').hitTestable());
    await settle(tester);
    expect(told.last, {'on': true, 'offBelowBattery': 20});
    expect(await tester.runAsync(() => repo.settings.get(highRefreshBatterySetting)), '20');

    await tester.tap(toggle);
    await settle(tester);
    expect(told.last, {'on': false, 'offBelowBattery': 20}, reason: 'off again; the level is kept for the next time');
    debugDefaultTargetPlatformOverride = null; // (before the test ends: the binding checks it then)
  });

  test('what was saved is sent at the start, and only on Android', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final told = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(displayChannel, (call) async {
      told.add(call.arguments);
      return null;
    });
    final saved = {highRefreshSetting: '1', highRefreshBatterySetting: '30'};
    Future<String?> get(String key) async => saved[key];

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await applyRefreshRate(get);
    expect(told, isEmpty);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await applyRefreshRate(get);
    expect(told, [
      {'on': true, 'offBelowBattery': 30},
    ]);
    debugDefaultTargetPlatformOverride = null;
  });
}

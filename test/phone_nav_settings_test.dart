import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/phone_nav_settings.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a saved choice is read, and anything unusable means the usual four', () {
    expect(decodePhoneNav(null), defaultPhoneNav);
    expect(decodePhoneNav('2,0'), [2, 0]);
    expect(decodePhoneNav('2'), defaultPhoneNav, reason: 'two at least');
    expect(decodePhoneNav('x,99,0,1,6,9,2,10'), [0, 1, 6, 9, 2], reason: 'five at most, only places that exist');
  });

  testWidgets('places are added and taken out of the bar, between two and five, and kept', (tester) async {
    late NoteRepository repo;
    await tester.runAsync(() async => repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath)));
    phoneNavItems.value = defaultPhoneNav;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PhoneNavSettings(settings: repo.settings))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('phone-nav-2')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(phoneNavItems.value, [0, 1, 6, 9, 2]);
    expect((await tester.runAsync(() => repo.settings.get(phoneNavKey))), '0,1,6,9,2');

    await tester.tap(find.byKey(const ValueKey('phone-nav-8')));
    await tester.pump();
    expect(phoneNavItems.value.length, 5, reason: 'a sixth does not fit');

    for (final id in [9, 6, 1]) {
      await tester.tap(find.byKey(ValueKey('phone-nav-$id')));
      await tester.pump();
    }
    expect(phoneNavItems.value, [0, 2], reason: 'and not fewer than two');
    await tester.tap(find.byKey(const ValueKey('phone-nav-0')));
    await tester.pump();
    expect(phoneNavItems.value, [0, 2]);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  });
}

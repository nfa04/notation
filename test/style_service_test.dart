import 'dart:ui';


import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/style_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/calendar_style.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_remote.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DayEvent event({String? color, String cal = 'https://c/personal/', String uid = 'e1'}) => DayEvent(
    title: 't', start: DateTime(2026, 11, 5, 9), allDay: false, calendarName: 'Personal', color: color, calendarKey: cal, uid: uid);

void main() {
  setUpAll(AppDatabase.initFfi);

  late SettingsRepository settings;
  late StyleRepository repo;
  late StyleService service;
  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('styles');
    await db.delete('settings');
    settings = SettingsRepository(db);
    repo = StyleRepository(db);
    service = StyleService(repo, settings, AppTheme.inMemory());
    await service.load();
  });

  group('theme', () {
    test('survives a restart', () async {
      await service.setTheme(themePresets[1].theme);
      final again = StyleService(repo, settings, AppTheme.inMemory());
      await again.load();
      expect(again.theme, themePresets[1].theme);
    });

    test('a broken saved theme falls back instead of crashing', () async {
      await settings.set('calendar_theme', '{not json');
      final again = StyleService(repo, settings, AppTheme.inMemory());
      await again.load();
      expect(again.theme, CalendarTheme.standard);
    });

    test('missing fields in a saved theme get defaults', () {
      final t = CalendarTheme.fromJson({'radius': 20, 'accent': 0xFFFF0000}); // an old accent is ignored
      expect(t.radius, 20);
      expect(t.border, CalendarTheme.standard.border);
      expect(t.palette, isNotEmpty);
    });

    test('every preset round-trips through json', () {
      for (final p in themePresets) {
        expect(CalendarTheme.fromJson(p.theme.toJson()), p.theme, reason: p.name);
      }
    });
  });

  group('looks of single items', () {
    test('are saved, replaced and removed when emptied', () async {
      await service.setStyle(StyleScope.task, 't1', const ItemStyle(color: Color(0xFFFF00FF), emoji: '🌸'));
      var again = StyleService(repo, settings, AppTheme.inMemory());
      await again.load();
      expect(again.styleOf(StyleScope.task, 't1'), const ItemStyle(color: Color(0xFFFF00FF), emoji: '🌸'));

      await service.setStyle(StyleScope.task, 't1', const ItemStyle(border: BorderKind.dotted));
      await service.setStyle(StyleScope.day, '2026-11-05', const ItemStyle(emoji: '🎂'));
      again = StyleService(repo, settings, AppTheme.inMemory());
      await again.load();
      expect(again.styleOf(StyleScope.task, 't1'), const ItemStyle(border: BorderKind.dotted));
      expect(again.dayStyle(DateTime(2026, 11, 5))!.emoji, '🎂');

      await service.setStyle(StyleScope.task, 't1', const ItemStyle());
      again = StyleService(repo, settings, AppTheme.inMemory());
      await again.load();
      expect(again.styleOf(StyleScope.task, 't1'), isNull);
    });

    test('resetItems clears them all but keeps the theme', () async {
      await service.setTheme(themePresets[2].theme);
      await service.setStyle(StyleScope.event, 'a|b', const ItemStyle(emoji: '⭐'));
      await service.resetItems();
      final again = StyleService(repo, settings, AppTheme.inMemory());
      await again.load();
      expect(again.styleOf(StyleScope.event, 'a|b'), isNull);
      expect(again.theme, themePresets[2].theme);
    });
  });

  group('which look wins', () {
    test('an event\'s own look beats its calendar\'s, which beats the server\'s', () async {
      final e = event(color: '#336699');
      expect(service.resolveEvent(e).color, const Color(0xFF336699)); // server colour

      await service.setStyle(StyleScope.calendar, e.calendarKey, const ItemStyle(color: Color(0xFFAA0000), emoji: '📚'));
      expect(service.resolveEvent(e).color, const Color(0xFFAA0000));
      expect(service.resolveEvent(e).emoji, '📚');

      await service.setStyle(StyleScope.event, StyleService.eventKey(e), const ItemStyle(color: Color(0xFF00AA00), emoji: '🎂'));
      final r = service.resolveEvent(e);
      expect((r.color, r.emoji), (const Color(0xFF00AA00), '🎂'));

      // another event of the same calendar only has the calendar's look
      expect(service.resolveEvent(event(uid: 'e2')).color, const Color(0xFFAA0000));
    });

    test('border: own, then calendar, then the theme', () async {
      final e = event();
      expect(service.resolveEvent(e).border, CalendarTheme.standard.border);
      await service.setStyle(StyleScope.calendar, e.calendarKey, const ItemStyle(border: BorderKind.dashed));
      expect(service.resolveEvent(e).border, BorderKind.dashed);
      await service.setStyle(StyleScope.event, StyleService.eventKey(e), const ItemStyle(border: BorderKind.solid));
      expect(service.resolveEvent(e).border, BorderKind.solid);
    });

    test('a calendar without any colour gets one from the palette, always the same', () {
      final a = service.resolveEvent(event(cal: 'cal-a')).color;
      expect(CalendarTheme.defaultPalette, contains(a));
      expect(service.resolveEvent(event(cal: 'cal-a')).color, a);
      expect(service.resolveEvent(event(cal: 'cal-a', uid: 'other')).color, a);
    });

    test('the palette can replace the server colours, but not a colour the user chose', () async {
      await service.setTheme(CalendarTheme.standard.copyWith(paletteOverridesServerColors: true));
      final e = event(color: '#336699');
      expect(service.resolveEvent(e).color, isNot(const Color(0xFF336699)));
      await service.setStyle(StyleScope.calendar, e.calendarKey, const ItemStyle(color: Color(0xFF123456)));
      expect(service.resolveEvent(e).color, const Color(0xFF123456));
    });

    test('tasks use the accent unless styled', () async {
      const t = Task(id: 't1', title: 'x');
      expect(service.resolveTask(t).color, service.app.accent);
      await service.setStyle(StyleScope.task, 't1', const ItemStyle(color: Color(0xFFFF0000)));
      expect(service.resolveTask(t).color, const Color(0xFFFF0000));
    });

    test('the label gets the emoji in front', () {
      expect(const ResolvedStyle(color: Color(0xFF000000), border: BorderKind.none, borderWidth: 1, radius: 1, emoji: '🌸').label('Plan'), '🌸 Plan');
      expect(const ResolvedStyle(color: Color(0xFF000000), border: BorderKind.none, borderWidth: 1, radius: 1).label('Plan'), 'Plan');
    });
  });

  test('stableHash does not change between runs', () {
    expect(stableHash('abc'), stableHash('abc'));
    expect(stableHash('abc'), isNot(stableHash('abd')));
    expect(stableHash('abc'), 440920331); // pinned: a change would recolour every calendar
  });

  test('a pastel background becomes a dark tint in dark mode', () async {
    expect(service.backgroundFor(Brightness.light), isNull);
    await service.setTheme(CalendarTheme.standard.copyWith(background: const Color(0xFFFFF4F8)));
    expect(service.backgroundFor(Brightness.light), const Color(0xFFFFF4F8));
    final dark = service.backgroundFor(Brightness.dark)!;
    expect(dark.computeLuminance(), lessThan(0.05));
    expect(dark.r, greaterThan(dark.g)); // still a hint of pink
  });
}

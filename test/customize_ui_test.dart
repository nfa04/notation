import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/style_repository.dart' show StyleScope;
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/calendar_customize_screen.dart';
import 'package:notes/screens/calendar_view.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/calendar_style.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/style/styled_box.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('every border kind paints, also in boxes smaller than their corners', (tester) async {
    for (final kind in BorderKind.values) {
      for (final size in [const Size(120, 30), const Size(8, 3), const Size(1, 1)]) {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox.fromSize(
              size: size,
              child: StyledBox(
                style: ResolvedStyle(color: Colors.pink, border: kind, borderWidth: 4, radius: 20),
                padding: EdgeInsets.zero,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ));
        expect(tester.takeException(), isNull, reason: '$kind at $size');
      }
    }
  });

  group('calendar with looks', () {
    late TaskRepository tasks;
    late StyleService style;

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    Future<void> pump(WidgetTester tester, {int taskCount = 1}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('tasks');
        await db.delete('styles');
        await db.delete('settings');
        tasks = TaskRepository(db);
        for (var i = 1; i <= taskCount; i++) {
          await tasks.createTask('Task $i', dueDate: dayOf(DateTime.now()));
        }
        style = StyleService.inMemory();
      });
      await tester.pumpWidget(MaterialApp(home: CalendarView(repository: tasks, style: style)));
      await settle(tester);
    }

    testWidgets('a crowded day says how many more there are', (tester) async {
      await pump(tester, taskCount: 12);
      expect(find.textContaining(' more'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('long press a task: choose a color and emoji, and it shows everywhere', (tester) async {
      await pump(tester);
      // the chip in today's cell
      await tester.longPress(find.text('Task 1').first);
      await settle(tester);
      expect(find.text('Style this task'), findsOneWidget);

      await tester.tap(find.text('🌸'));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('swatch-${swatchColors[2].toARGB32()}')));
      await tester.pump();
      await tester.tap(find.text('Dashed'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      final saved = style.styleOf(StyleScope.task, (await tester.runAsync(() => tasks.listTasks()))!.single.id)!;
      expect(saved.emoji, '🌸');
      expect(saved.border, BorderKind.dashed);
      expect(saved.color, swatchColors[2]);
      // the chip and the side panel both carry the emoji now
      expect(find.text('🌸 Task 1'), findsNWidgets(2));
    });

    testWidgets('decorating a day puts a sticker on it', (tester) async {
      await pump(tester, taskCount: 0);
      await tester.tap(find.byTooltip('Decorate this day'));
      await settle(tester);
      await tester.tap(find.text('🎂'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(style.dayStyle(dayOf(DateTime.now()))!.emoji, '🎂');
      expect(find.text('🎂'), findsNWidgets(2)); // in the cell and next to the date
    });

    testWidgets('right click works like a long press', (tester) async {
      await pump(tester);
      final target = tester.getCenter(find.text('Task 1').first);
      final gesture = await tester.startGesture(target, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await gesture.up();
      await settle(tester);
      expect(find.text('Style this task'), findsOneWidget);
    });

    testWidgets('Reset in the dialog removes the look again', (tester) async {
      await pump(tester);
      final id = (await tester.runAsync(() => tasks.listTasks()))!.single.id;
      await style.setStyle(StyleScope.task, id, const ItemStyle(emoji: '⭐'));
      await tester.pump();
      await tester.longPress(find.text('⭐ Task 1').first);
      await settle(tester);
      await tester.tap(find.text('Reset'));
      await settle(tester);
      expect(style.styleOf(StyleScope.task, id), isNull);
      expect(find.text('⭐ Task 1'), findsNothing);
    });
  });

  testWidgets('the customize screen switches themes and shows them', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final style = StyleService.inMemory();
    await tester.pumpWidget(MaterialApp(home: CalendarCustomizeScreen(style: style)));
    await tester.pumpAndSettle();
    expect(style.theme, CalendarTheme.standard);

    await tester.tap(find.text('Sakura'));
    await tester.pumpAndSettle();
    expect(style.theme, themePresets.firstWhere((p) => p.name == 'Sakura').theme);

    // a single setting changes only that setting
    await tester.tap(find.text('Dotted'));
    await tester.pumpAndSettle();
    expect(style.theme.border, BorderKind.dotted);
    expect(style.app.accent, AppTheme.defaultAccent); // calendar themes leave the app's colour alone

    await tester.tap(find.text('Back to the classic theme'));
    await tester.pumpAndSettle();
    expect(style.theme, CalendarTheme.standard);
    expect(tester.takeException(), isNull);
  });
}

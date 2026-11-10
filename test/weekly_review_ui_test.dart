import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/reminders/reminder.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/review/weekly_review_service.dart';
import 'package:notes/screens/weekly_review_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'reminder_service_test.dart' show FakeSink;

class _Writer extends ChangeNotifier implements TextModelProvider {
  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get description => '';
  @override
  ProviderState get state => ProviderState.ready;
  @override
  String? get reason => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async => 'A good week.\nNext week:\n- Rest';
}

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the next Sunday evening', () {
    expect(nextSunday(DateTime(2026, 10, 29, 12)), DateTime(2026, 11, 1, 18)); // Thursday
    expect(nextSunday(DateTime(2026, 11, 1, 9)), DateTime(2026, 11, 1, 18)); // Sunday morning: today
    expect(nextSunday(DateTime(2026, 11, 1, 19)), DateTime(2026, 11, 8, 18)); // Sunday night: the next
    expect(nextSunday(DateTime(2026, 10, 26, 8)), DateTime(2026, 11, 1, 18)); // Monday
  });

  testWidgets('the review is made from the dialog with a summary, a Sunday reminder is set, and the note is opened', (tester) async {
    late Database db;
    late NoteRepository notes;
    late WeeklyReviewService review;
    late ReminderService reminders;
    final now = DateTime(2026, 10, 29, 12);
    String? opened;
    await tester.runAsync(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['notes', 'tasks', 'folders', 'reminders']) {
        await db.delete(t);
      }
      notes = NoteRepository(db);
      final id = await notes.createNote(title: 'Thermodynamics');
      await notes.setTimes(id, created: DateTime(2026, 10, 27), edited: DateTime(2026, 10, 28));
      review = WeeklyReviewService(repository: notes, tasks: TaskRepository(db), ai: AiService(providers: [_Writer()]), clock: () => now);
      reminders = ReminderService(reminders: ReminderRepository(db), tasks: TaskRepository(db), sink: FakeSink(), read: (_) async => null, write: (_, _) async {});
      await reminders.start();
    });
    addTearDown(() async {
      reminders.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(onPressed: () => showWeeklyReview(context, service: review, reminders: reminders, onOpenNote: (id) => opened = id), child: const Text('go'))),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-exists')), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('review-assistant'))).value, isTrue);

    await tester.tap(find.byKey(const ValueKey('review-remind')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('review-make')));
    for (var i = 0; i < 12 && opened == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    final text = (await tester.runAsync(() => notes.loadNote(opened!)))!.documentText;
    expect(text, contains('A good week.'));
    expect(text, contains('[Thermodynamics](note:'));
    expect(text, contains('- Rest'));
    final list = (await tester.runAsync(() => reminders.reminders.all()))!;
    expect(list.single.kind, ReminderKind.review);
    expect(list.single.repeat, Repeat.weekly);
    expect(list.single.at.weekday, DateTime.sunday);
    expect(list.single.at.hour, 18);
  });
}

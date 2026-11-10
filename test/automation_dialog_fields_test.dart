import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/screens/automations_view.dart';

void main() {
  Future<void Function()> openDialog(WidgetTester tester, {Automation? existing, List<({String id, String name})> templates = const []}) async {
    Automation? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => saved = await showDialog<Automation>(
            context: context,
            builder: (_) => AutomationDialog(
              existing: existing,
              folders: const [FolderEntry(id: 'f', parentId: null, name: 'Journal', noteCount: 0)],
              templates: templates,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => expect(saved, isNotNull);
  }

  Future<void> choose(WidgetTester tester, Key dropdown, String text) async {
    await tester.ensureVisible(find.byKey(dropdown));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(dropdown));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('a rule for a calendar event takes the minutes and makes a daily note entry', (tester) async {
    Automation? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => saved = await showDialog<Automation>(
            context: context,
            builder: (_) => const AutomationDialog(folders: [FolderEntry(id: 'f', parentId: null, name: 'Journal', noteCount: 0)]),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('automation-minutes')), findsNothing);
    await choose(tester, const ValueKey('automation-event'), 'A calendar event is about to start');
    expect(find.byKey(const ValueKey('automation-minutes')), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-scope')), findsNothing, reason: 'it is not about a note');
    await tester.enterText(find.byKey(const ValueKey('automation-minutes')), '0');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('automation-save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('automation-minutes')), '15');

    await choose(tester, const ValueKey('automation-action'), 'Add text to a note (or to a daily note)');
    expect(find.byKey(const ValueKey('automation-field-text')), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-field-title')), findsNothing, reason: 'only for a daily note');
    await choose(tester, const ValueKey('automation-field-where'), 'A daily note (made if it is not there)');
    expect(find.byKey(const ValueKey('automation-field-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-field-folder')), findsOneWidget);
    await choose(tester, const ValueKey('automation-field-folder'), 'Journal');
    await tester.enterText(find.byKey(const ValueKey('automation-field-text')), 'Meeting: {title} at {start}');
    await tester.pump();
    await save(tester);

    expect(saved!.event, AutomationEvent.calendarEventStarting);
    expect(saved!.action, AutomationAction.appendToNote);
    expect(saved!.params, {'minutes': '15', 'where': 'daily', 'title': 'Daily {date}', 'folder': 'f', 'text': 'Meeting: {title} at {start}'});
  });

  testWidgets('what the event offers is listed in the help of the task, and a required setting keeps the rule from being saved', (tester) async {
    await openDialog(tester);
    await choose(tester, const ValueKey('automation-event'), 'A task is done');
    await choose(tester, const ValueKey('automation-action'), 'Add a task to the calendar');
    expect(find.textContaining('{due} the day the task was due'), findsOneWidget);

    await choose(tester, const ValueKey('automation-action'), 'Set a reminder');
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('automation-save'))).onPressed, isNotNull, reason: 'a reminder needs nothing typed');
    await choose(tester, const ValueKey('automation-action'), 'Make a new note from a template');
    expect(find.text('There are no templates here.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('automation-save'))).onPressed, isNull, reason: 'the template is required');
  });

  testWidgets('a template is chosen from the list and kept, a rule that is changed shows what it had', (tester) async {
    Automation? saved;
    final existing = const Automation(
        id: 'x', event: AutomationEvent.taskCompleted, action: AutomationAction.setReminder, params: {'when': 'inAWeek', 'text': 'Check {title}'});
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => saved = await showDialog<Automation>(
            context: context,
            builder: (_) => AutomationDialog(existing: existing, folders: const [], templates: const [(id: 'lecture', name: 'Lecture'), (id: 'saved:7', name: 'My plan')]),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('automation-field-text'))).controller!.text, 'Check {title}');
    expect(find.text('In a week (9:00)'), findsOneWidget);

    await choose(tester, const ValueKey('automation-action'), 'Make a new note from a template');
    await choose(tester, const ValueKey('automation-field-template'), 'My plan');
    await save(tester);
    expect(saved!.action, AutomationAction.createNoteFromTemplate);
    expect(saved!.params['template'], 'saved:7');
    expect(saved!.params['title'], '{title}');
    expect(saved!.params.containsKey('when'), isFalse, reason: 'what belonged to the other action is gone');
  });
}

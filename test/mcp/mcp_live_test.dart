import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/ink/handwriting_service.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';

import 'support/mcp_fixture.dart';
import 'support/mcp_test_client.dart';

/// What the person sees while an agent works: the whole app (the shell, the lists, a real editor) over the MCP stack, and an agent that
/// speaks real HTTP to it.
void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the lists show what an agent makes, a note that is open shows what it writes as it writes it, and the person is told', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late McpFixture f;
    late McpTestClient agent;
    late AutomationService automations;
    await tester.runAsync(() async {
      f = await startMcpFixture(editorOf: (id) => automations.openEditor?.call(id)); // (the shell says which notes are open)
      automations = AutomationService(f.repository, f.tasks);
      await automations.load();
      agent = McpTestClient(f.url, f.token);
    });

    /// Real work (the database, the HTTP server) only moves while the real clock runs, and the screens only see it when they are pumped:
    /// so the two take turns (pumpAndSettle would wait for work that cannot move, with a spinner on the screen).
    Future<void> work([int rounds = 5]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// A call of the agent that needs the app to move while it waits (a note that is open is saved first, by the editor): the screens are
    /// pumped until it is answered.
    Future<T> during<T>(Future<T> Function() call) async {
      var done = false;
      Object? failure;
      T? answer;
      final pending = () async {
        try {
          answer = await call();
        } catch (e) {
          failure = e;
        } finally {
          done = true;
        }
      }();
      for (var i = 0; i < 80 && !done; i++) {
        await work(1);
      }
      await pending;
      if (failure != null) throw failure!;
      return answer as T;
    }

    /// Lets a change reach the screens: the stream, the wait, the load again, and the notice (which looks the title up).
    Future<void> reaction() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await work();
    }

    final settings = SettingsRepository(f.db);
    await tester.pumpWidget(MaterialApp(
      home: MainShellNavigation(
        services: AppServices(
          repository: f.repository,
          tasks: f.tasks,
          caldav: CalDavService(settings, f.tasks),
          device: DeviceCalendarService(settings),
          style: StyleService.inMemory(),
          appTheme: AppTheme.inMemory(),
          handwriting: HandwritingService(),
          math: MathService(),
          automations: automations,
          mcp: f.service,
        ),
      ),
    ));
    await work();
    expect(find.text('Project plan'), findsOneWidget);
    expect(find.text('Made by the agent'), findsNothing);

    // a note that is made: it is in the list, and the person is told
    await tester.runAsync(() => agent.made('create_note', {'title': 'Made by the agent', 'text': 'Hello from outside.'}));
    await reaction();
    expect(find.text('Made by the agent'), findsOneWidget, reason: 'the dashboard looked again on its own');
    expect(find.text('An agent changed "Made by the agent".'), findsOneWidget);

    // a note that is open: what the agent writes is in the editor as it is written, and the person is told
    // (what is on the page, as the person reads it: the text fields, and the text drawn as it is written in Markdown)
    String editorText() => [
          for (final e in tester.widgetList<EditableText>(find.byType(EditableText))) e.controller.text,
          for (final r in tester.widgetList<RichText>(find.byType(RichText))) r.text.toPlainText(),
        ].join('\n');
    await tester.tap(find.text('Project plan'));
    for (var i = 0; i < 40 && !editorText().contains('Ship the beta.'); i++) {
      await work(1);
    }
    expect(editorText(), contains('Ship the beta.'));
    expect(editorText(), isNot(contains('Added while open.')));

    final said = await during(() => agent.text('append_to_note', {'note_id': f.ids['plan'], 'text': 'Added while open.'}));
    expect(said, contains('text was added'));
    await reaction();
    expect(editorText(), contains('Added while open.'), reason: 'in the editor that has the note open, not only in the database');
    expect(find.text('An agent changed "Project plan".'), findsOneWidget);

    // and the agent that reads it sees the same
    expect(await during(() => agent.text('read_note', {'note_id': f.ids['plan']})), contains('Added while open.'));

    await tester.pumpWidget(const SizedBox()); // (the shell goes, and what it saves on the way)
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await agent.close();
      await f.close();
    });
  });
}

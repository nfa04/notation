import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/screens/extension_settings.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const manifest = '''{
  "id": "shout", "name": "Shout", "version": "1.0.0",
  "permissions": ["note.read"],
  "tools": [{ "id": "loud", "title": "Make it loud" }, { "id": "words", "title": "Count the words" }, { "id": "title", "title": "Title from text" }],
  "actions": [{ "id": "a", "title": "An action" }]
}''';
const script = '''
  notation.tool('loud', (ctx) => ctx.text.toUpperCase() + '!');
  notation.tool('words', (ctx) => ({ message: ctx.text.split(' ').length + ' words' }));
  notation.tool('title', async (ctx) => { const n = await notation.note.get(); return n.title + ': ' + ctx.text; });
  notation.action('a', () => 'ran');
''';

/// Lets things that wait for the disk or for the script go on: each step needs the real clock and then the test's own.
Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(AppDatabase.initFfi);
  final skip = QuickJsEngine.available ? null : 'the JavaScript engine is not here (LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib)';

  late Directory dir;
  late Map<String, String> store;
  ExtensionService make() => ExtensionService((k) async => store[k], (k, v) async => store[k] = v, directory: () async => Directory('${dir.path}/ext'));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('extui');
    store = {};
  });
  tearDown(() => dir.delete(recursive: true));

  testWidgets('the write dialog opens the documentation, which is the shipped docs/extensions.md', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExtensionSettings(service: make())))));
    await tester.tap(find.byKey(const ValueKey('extension-write')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('extension-docs')));
    // (an asset of more than 50 KB is decoded on an isolate, which takes real time: the file is long)
    for (var i = 0; i < 100 && find.byKey(const ValueKey('extension-docs-text')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('extension-docs-text')), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('extension-docs-text'))).data, contains('notation'));
  });

  testWidgets('the settings: write one, it is off, switch it on and give it a permission, remove it', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = make();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExtensionSettings(service: service)))));
    expect(find.text('No extensions yet.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('extension-write')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('extension-manifest')), manifest);
    await tester.enterText(find.byKey(const ValueKey('extension-script')), script);
    await tester.tap(find.byKey(const ValueKey('extension-save')));
    await settle(tester);
    // what it asks for is shown first; nothing is installed until the person says so
    expect(find.byKey(const ValueKey('extension-review')), findsOneWidget);
    expect(find.byKey(const ValueKey('asks-note.read')), findsOneWidget);
    expect(service.installed, isEmpty);
    await tester.tap(find.byKey(const ValueKey('extension-review-install')));
    await settle(tester);
    expect(find.byKey(const ValueKey('extension-shout')), findsOneWidget);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('extension-on-shout'))).value, isFalse, reason: 'off to begin with');
    expect(service.tools, isEmpty);

    await tester.tap(find.byKey(const ValueKey('extension-on-shout')));
    await settle(tester);
    expect(service.tools, hasLength(3));

    await tester.tap(find.text('Shout  ·  1.0.0'));
    await tester.pumpAndSettle();
    expect(find.text('Read the text and the title of the note it is used on'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('extension-shout-note.read')));
    await settle(tester);
    expect(service.byId('shout')!.granted, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('extension-remove-shout')));
    await settle(tester);
    expect(service.installed, isEmpty);
  });

  testWidgets('a manifest that is wrong says why', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = make();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExtensionSettings(service: service)))));
    await tester.tap(find.byKey(const ValueKey('extension-write')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('extension-manifest')), '{"id": "x"}');
    await tester.tap(find.byKey(const ValueKey('extension-save')));
    await settle(tester);
    expect(find.byKey(const ValueKey('extension-review')), findsNothing); // (nothing to review)
    expect(find.textContaining('Could not install it:'), findsOneWidget);
    expect(service.installed, isEmpty);
  });

  testWidgets('the review shows every permission with what it is about, and Cancel installs nothing', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = make();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExtensionSettings(service: service)))));
    const wide = '''{"id": "wide", "name": "Wide", "version": "2.0.0", "author": "Someone", "description": "Does a lot.",
      "permissions": ["note.read", "network", "events.emit"], "hosts": ["api.example.com"],
      "events": [{"id": "ping", "title": "A ping"}], "tools": [{"id": "t", "title": "Do it"}]}''';
    await tester.tap(find.byKey(const ValueKey('extension-write')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('extension-manifest')), wide);
    await tester.enterText(find.byKey(const ValueKey('extension-script')), "notation.tool('t', () => 1);");
    await tester.tap(find.byKey(const ValueKey('extension-save')));
    await settle(tester);
    expect(find.text('Wide  ·  2.0.0'), findsOneWidget);
    expect(find.textContaining('(api.example.com)'), findsOneWidget);
    expect(find.textContaining('(A ping)'), findsOneWidget);
    for (final id in ['note.read', 'network', 'events.emit']) {
      expect(find.byKey(ValueKey('asks-$id')), findsOneWidget, reason: id);
    }
    expect(find.textContaining('(new)'), findsNothing); // (not an update)
    await tester.tap(find.byKey(const ValueKey('extension-review-cancel')));
    await settle(tester);
    expect(service.installed, isEmpty);
    expect(find.byKey(const ValueKey('extension-wide')), findsNothing);
  });

  testWidgets('an update marks what it asks for beyond the installed version', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = make();
    await tester.runAsync(() => service.installSource(
        '{"id": "upd", "name": "Upd", "version": "1.0.0", "permissions": ["note.read"]}', 'notation.tool("t", () => 1);'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExtensionSettings(service: service)))));
    await tester.tap(find.byKey(const ValueKey('extension-write')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('extension-manifest')), '{"id": "upd", "name": "Upd", "version": "1.1.0", "permissions": ["note.read", "clipboard.write"]}');
    await tester.enterText(find.byKey(const ValueKey('extension-script')), 'notation.tool("t", () => 1);');
    await tester.tap(find.byKey(const ValueKey('extension-save')));
    await settle(tester);
    expect(find.text('This replaces version 1.0.0.'), findsOneWidget);
    expect(find.textContaining('(new)'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('asks-clipboard.write')), matching: find.textContaining('(new)')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('extension-review-cancel')));
    await settle(tester);
    expect(service.byId('upd')!.manifest.version, '1.0.0');
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<RichInlineTextController> open(WidgetTester tester, ExtensionService service) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.title = 'Physics';
        note.documentText = 'the cat sat down';
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, extensions: service)));
      await settle(tester);
      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();
      return tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    }

    Future<void> showMenu(WidgetTester tester, RichInlineTextController c, int from, int to) async {
      c.selection = TextSelection(baseOffset: from, extentOffset: to);
      await tester.pump();
      tester.state<BlockEditorState>(find.byType(BlockEditor)).debugShowMenu();
      await tester.pumpAndSettle();
    }

    testWidgets('a tool is in the menu of selected text and replaces it', (tester) async {
      final service = make();
      await tester.runAsync(() async {
        await service.installSource(manifest, script);
        await service.setEnabled('shout', true);
      });
      final c = await open(tester, service);
      await showMenu(tester, c, 4, 7);
      expect(find.text('Shout: Make it loud'), findsOneWidget);
      await tester.tap(find.text('Shout: Make it loud'));
      await settle(tester);
      expect(c.text, 'the CAT! sat down');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }, skip: skip != null);

    testWidgets('a tool can answer with a message, which changes nothing', (tester) async {
      final service = make();
      await tester.runAsync(() async {
        await service.installSource(manifest, script);
        await service.setEnabled('shout', true);
      });
      final c = await open(tester, service);
      await showMenu(tester, c, 0, 7);
      await tester.tap(find.text('Shout: Count the words'));
      await settle(tester);
      expect(find.text('2 words'), findsOneWidget);
      expect(c.text, 'the cat sat down', reason: 'a message changes nothing');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }, skip: skip != null);

    testWidgets('a tool is named with its extension in the menu, so that it can be found by the name in the settings', (tester) async {
      final service = make();
      await tester.runAsync(() async {
        await service.installSource(manifest, script);
        await service.setEnabled('shout', true);
      });
      final c = await open(tester, service);
      await showMenu(tester, c, 4, 7);
      expect(find.text('Shout: Make it loud'), findsOneWidget);
      expect(find.text('Shout: Count the words'), findsOneWidget);
      expect(find.text('Shout: Title from text'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a tool that is off, or no text selected, is not in the menu', (tester) async {
      final service = make();
      await tester.runAsync(() async => await service.installSource(manifest, script)); // (off)
      final c = await open(tester, service);
      await showMenu(tester, c, 4, 7);
      expect(find.text('Shout: Make it loud'), findsNothing);
      await tester.runAsync(() async => await service.setEnabled('shout', true));
      await showMenu(tester, c, 4, 4);
      expect(find.text('Shout: Make it loud'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });
}

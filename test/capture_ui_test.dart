import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/capture/capture_link.dart';
import 'package:notes/capture/capture_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/capture_dialogs.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _page = '<html><head><title>Plants</title></head><body><article><p>Plants take in carbon dioxide through tiny pores called stomata, and give out oxygen while they do it.</p></article></body></html>';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late Directory dir;
  late NoteRepository repo;
  late CaptureService capture;
  Captured? result;
  var asked = false;

  Future<void> open(WidgetTester tester, Future<Captured?> Function(BuildContext) show) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('capture_ui_');
      db = await AppDatabase.open(path: '${dir.path}/n.db');
      repo = NoteRepository(db);
      capture = CaptureService(
        repository: repo,
        supportDirectory: () async => dir,
        fetch: (url) async {
          if (url.host == 'down.example') throw const SocketException('no route');
          return _page;
        },
      );
    });
    addTearDown(() => tester.runAsync(() async {
          await db.close();
          await dir.delete(recursive: true);
        }));
    result = null;
    asked = false;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async { asked = true; result = await show(context); }, child: const Text('go')))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('text from a link can be changed before it is kept, and lands in the Inbox', (tester) async {
    await open(tester, (c) => showCaptureLink(c, capture, const QuickCaptureLink(text: 'Buy milk', title: 'Shopping')));
    expect(find.text('Keep this in the Inbox?'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('capture-title'))).controller!.text, 'Shopping');
    await tester.enterText(find.byKey(const ValueKey('capture-text')), 'Buy milk and eggs');
    await tester.tap(find.byKey(const ValueKey('capture-save')));
    await settle(tester);
    expect(result!.title, 'Shopping');
    final note = (await tester.runAsync(() => repo.loadNote(result!.noteId)))!;
    expect(note.documentText, 'Buy milk and eggs\n');
  });

  testWidgets('cancelling keeps nothing', (tester) async {
    await open(tester, (c) => showCaptureLink(c, capture, const QuickCaptureLink(text: 'Secret')));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(asked, isTrue);
    expect(result, isNull);
    expect(await tester.runAsync(() => repo.listNotes()), isEmpty);
  });

  testWidgets('a clipped page with a selection keeps the selection; without one the article is fetched', (tester) async {
    await open(tester, (c) => showCaptureLink(c, capture, ClipLink(Uri.parse('https://blog.example/plants'), title: 'Plants', selection: 'a selected sentence')));
    expect(find.text('Keep this page?'), findsOneWidget);
    expect(find.text('https://blog.example/plants'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('capture-save')));
    await settle(tester);
    var doc = (await tester.runAsync(() => repo.loadNote(result!.noteId)))!.documentText;
    expect(doc, contains('> a selected sentence'));
    expect(doc, isNot(contains('carbon dioxide')));

    // the same without the selection: the whole article
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  });

  testWidgets('without a selection the article of the page is kept', (tester) async {
    await open(tester, (c) => showCaptureLink(c, capture, ClipLink(Uri.parse('https://blog.example/plants'), title: 'Ignored title')));
    await tester.tap(find.byKey(const ValueKey('capture-save')));
    await settle(tester);
    final doc = (await tester.runAsync(() => repo.loadNote(result!.noteId)))!.documentText;
    expect(doc, contains('carbon dioxide'));
  });

  testWidgets('a page that cannot be loaded is explained, and the dialog stays', (tester) async {
    await open(tester, (c) => showCaptureLink(c, capture, ClipLink(Uri.parse('https://down.example/x'))));
    await tester.tap(find.byKey(const ValueKey('capture-save')));
    await settle(tester);
    expect(find.byKey(const ValueKey('capture-problem')), findsOneWidget);
    expect(find.textContaining('could not be loaded'), findsOneWidget);
    expect(result, isNull);
    expect(await tester.runAsync(() => repo.listNotes()), isEmpty);
  });

  testWidgets('the quick note dialog makes a note of what is typed', (tester) async {
    await open(tester, (c) => showQuickNote(c, capture));
    await tester.enterText(find.byKey(const ValueKey('capture-text')), 'Call the dentist');
    await tester.tap(find.byKey(const ValueKey('capture-save')));
    await settle(tester);
    expect(result!.title, 'Call the dentist');
  });

  testWidgets('a web address typed without https is accepted; nonsense is refused', (tester) async {
    await open(tester, (c) => showClipPage(c, capture));
    await tester.enterText(find.byKey(const ValueKey('clip-url')), 'http://');
    await tester.tap(find.byKey(const ValueKey('clip-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clip-problem')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('clip-url')), 'blog.example/plants');
    await tester.tap(find.byKey(const ValueKey('clip-save')));
    await settle(tester);
    expect(result!.title, 'Plants');
  });

  testWidgets('the dialog for pages shows the bookmarklet of the web clipper', (tester) async {
    await open(tester, (c) => showClipPage(c, capture));
    await tester.tap(find.text('From your browser'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clip-bookmarklet')), findsOneWidget);
    expect(find.byKey(const ValueKey('clip-copy')), findsOneWidget);
  });
}

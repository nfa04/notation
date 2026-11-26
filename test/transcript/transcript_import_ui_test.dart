import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/transcript_import.dart';
import 'package:notes/transcript/transcript.dart';
import 'package:notes/transcript/transcript_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _srt = '1\n00:00:01,000 --> 00:00:03,000\nHello everyone\n\n2\n00:01:10,000 --> 00:01:12,000\nA minute later\n';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  String? opened;

  Future<void> start(WidgetTester tester, {List<TranscriptSource> sources = const []}) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    opened = null;
    await tester.runAsync(() async => repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath)));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          key: const ValueKey('go'),
          onPressed: () => showTranscriptImport(context, repository: repo, onOpenNote: (id) => opened = id, sources: sources),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pumpAndSettle();
  }

  testWidgets('pasted captions make a note with a time on each paragraph', (tester) async {
    await start(tester);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('transcript-create'))).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('transcript-title')), 'Lecture 3');
    await tester.enterText(find.byKey(const ValueKey('transcript-source')), 'https://youtu.be/dQw4w9WgXcQ');
    await tester.enterText(find.byKey(const ValueKey('transcript-captions')), _srt);
    await tester.pump();
    expect(find.byKey(const ValueKey('transcript-summary')), findsOneWidget);
    expect(find.textContaining('2 lines'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('transcript-create')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    final note = await tester.runAsync(() => repo.loadNote(opened!));
    expect(note!.title, 'Lecture 3');
    expect(note.documentText, contains('[0:01](https://youtu.be/dQw4w9WgXcQ?t=1) Hello everyone'));
    expect(note.documentText, contains('[1:10](https://youtu.be/dQw4w9WgXcQ?t=70) A minute later'));
  });

  testWidgets('text that is not captions says so and cannot make a note', (tester) async {
    await start(tester);
    await tester.enterText(find.byKey(const ValueKey('transcript-captions')), 'just some words');
    await tester.pump();
    expect(find.byKey(const ValueKey('transcript-problem')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('transcript-create'))).onPressed, isNull);
  });

  testWidgets('a source fetches from the address; its error is shown', (tester) async {
    var fail = false;
    await start(tester, sources: [
      TranscriptSource(
        id: 'ext:x/y',
        title: 'Test source',
        fetch: (input) async {
          if (fail) throw const TranscriptSourceError('No captions for this video.');
          return Transcript(title: 'From $input', segments: const [TranscriptSegment(0, 2, 'Fetched words')]);
        },
      ),
    ]);
    final fetch = find.byKey(const ValueKey('transcript-fetch-ext:x/y'));
    expect(tester.widget<OutlinedButton>(fetch).onPressed, isNull, reason: 'nothing to fetch from yet');
    await tester.enterText(find.byKey(const ValueKey('transcript-source')), 'https://example.com/v');
    await tester.pump();
    await tester.tap(fetch);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transcript-summary')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('transcript-title'))).controller!.text, 'From https://example.com/v');

    fail = true;
    await tester.tap(fetch);
    await tester.pumpAndSettle();
    expect(find.text('No captions for this video.'), findsOneWidget);
  });
}

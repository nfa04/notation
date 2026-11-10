import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/shared_notes.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:notes/screens/folder_view.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('which notes are shared', () {
    test('notes shared with the person are remembered, with who from; notes shared by them follow the supplier', () async {
      final store = <String, String>{};
      var mine = <String>{};
      SharedNotes make() => SharedNotes((k) async => store[k], (k, v) async => store[k] = v, byMe: () => mine);
      final shared = make();
      await shared.markWithMe('a', from: 'Anna');
      await shared.markWithMe('b');
      mine = {'b', 'c'};
      expect(shared.kindOf('a'), SharedKind.withMe);
      expect(shared.kindOf('b'), SharedKind.both);
      expect(shared.kindOf('c'), SharedKind.byMe);
      expect(shared.kindOf('d'), SharedKind.none);
      expect(shared.fromWhom('a'), 'Anna');
      expect(shared.fromWhom('b'), isNull);
      expect(SharedKind.none.isShared, isFalse);

      final again = make(); // the next start
      await again.load();
      expect(again.withMe, {'a', 'b'});
      expect(again.fromWhom('a'), 'Anna');
      await again.forget('a');
      final last = make();
      await last.load();
      expect(last.withMe, {'b'});
    });
  });

  group('on the screens', () {
    late Directory dir;
    late NoteRepository repo;
    late CollabService collab;
    late LoopbackHub hub;
    late String mine, theirs, both, plain;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('shared_notes_');
      hub = LoopbackHub();
      repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/a.db'));
      collab = CollabService(repo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/s')..createSync());
      await collab.load();
      await collab.setServer('wss://signal.example');
      mine = await repo.createNote(title: 'Mine, shared');
      theirs = await repo.createNote(title: 'From Anna');
      both = await repo.createNote(title: 'Both ways');
      plain = await repo.createNote(title: 'Plain');
      await collab.shared.markWithMe(theirs, from: 'Anna');
      await collab.shared.markWithMe(both, from: 'Anna');
      for (final id in [mine, both]) {
        final note = NoteData(id: id);
        await collab.startHosting(id, CollabBinding(
          note: () => note,
          change: (f) => f(),
          makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
          saveImage: collab.saveImage,
          onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
        ));
      }
    });
    tearDown(() {
      collab.dispose();
      dir.deleteSync(recursive: true);
    });

    testWidgets('the dashboard marks shared notes with a group symbol, and says which kind', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {}, collab: collab)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(find.byIcon(Icons.group), findsNWidgets(3), reason: 'mine, theirs, both ways: not the plain one');
      Tooltip tip(String id) => tester.widget<Tooltip>(find.descendant(of: find.byKey(ValueKey('shared-badge-$id')), matching: find.byType(Tooltip)));
      expect(tip(mine).message, 'Shared with others');
      expect(tip(theirs).message, 'Shared with you by Anna');
      expect(tip(both).message, 'Shared with you, and by you with others');
      expect(find.descendant(of: find.byKey(ValueKey('shared-badge-$plain')), matching: find.byType(Icon)), findsNothing, reason: 'nothing on a note that is not shared');
    });

    testWidgets('the folders have a "Shared with me" folder with the notes that came from others, marked in the list', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {}, collab: collab)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(find.text('Shared with me'), findsOneWidget);
      expect(find.text('From Anna'), findsOneWidget, reason: 'all notes are shown to begin with');
      expect(find.text('Plain'), findsOneWidget);
      // all notes: the marks
      expect(find.byIcon(Icons.group), findsNWidgets(3));

      await tester.tap(find.text('Shared with me'));
      await tester.pump();
      expect(find.text('From Anna'), findsOneWidget);
      expect(find.text('Both ways'), findsOneWidget);
      expect(find.text('Plain'), findsNothing);
      expect(find.text('Mine, shared'), findsNothing, reason: 'shared by the person, not with them');
      expect(find.byIcon(Icons.group), findsNWidgets(2));
    });

    testWidgets('without sharing set up there is no such folder and no marks', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {})));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.text('Shared with me'), findsNothing);
      expect(find.byIcon(Icons.group), findsNothing);
    });
  });
}

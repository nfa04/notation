import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a session on the open note: the button, the invite, a guest let in, and what the guest writes shows up', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo, guestRepo;
    late CollabService service, guestService;
    late String id;
    final hub = LoopbackHub();
    late Directory dir;
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('editor_live_');
      repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/a.db'));
      guestRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/b.db'));
      service = CollabService(repo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/a')..createSync());
      guestService = CollabService(guestRepo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/b')..createSync());
      await service.load();
      await guestService.load();
      await service.setName('Anna');
      await guestService.setName('Ben');
      id = await repo.createNote(title: 'Shared');
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b1', position: const Offset(100, 200), initialText: 'from Anna')];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.deleteSync(recursive: true));

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, collab: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.text('from Anna'), findsOneWidget);

    // no server yet: the panel asks for one
    await tester.ensureVisible(find.byKey(const ValueKey('live-button')));
    await tester.tap(find.byKey(const ValueKey('live-button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('live-start')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-problem')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('live-server')), 'ws://localhost:8787');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('live-start')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-link')), findsOneWidget);
    final link = tester.widget<SelectableText>(find.byKey(const ValueKey('live-link'))).data!;
    expect(link, startsWith('notation://join?'));

    // a guest joins with that link, and the host lets them in from the panel
    final invite = service.inviteFor(id)!;
    late JoinAttempt attempt;
    await tester.runAsync(() async {
      attempt = guestService.join(invite);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Ben wants to join'), findsOneWidget);
    expect(find.textContaining(attempt.session!.verificationCode!), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Let in'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    expect(attempt.noteId, isNotNull);
    expect(find.text('Ben'), findsOneWidget); // in the list of who is here
    expect(find.byKey(ValueKey('live-signal-${attempt.session!.site}')), findsOneWidget, reason: 'the host sees the link of every guest');

    // the guest's note has the text box; Ben changes it and it shows on Anna's screen
    final benNote = (await tester.runAsync(() => guestRepo.loadNote(attempt.noteId!)))!;
    expect(benNote.textBoxes[0]!.single.controller.text, 'from Anna');
    attempt.session!.attach(CollabBinding(
      note: () => benNote,
      change: (f) => f(),
      makeBox: (i) => TextBoxWidgetModel(id: i, position: Offset.zero),
      saveImage: guestService.saveImage,
      onNoteField: (f, d) => Replica.applyNoteField(benNote, f, d),
    ));
    benNote.textBoxes[0]!.single.controller.text = 'Ben was here';
    await tester.runAsync(() async {
      attempt.session!.localChanged(); // (its timer must be a real one)
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Ben was here'), findsOneWidget);
    expect(find.text('from Anna'), findsNothing);

    // and it was saved on Anna's side too
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(saved.textBoxes[0]!.single.controller.text, 'Ben was here');

    // Ben comes onto page 1 and goes again: it is framed, and the page under the frame is the same one (not built anew, which would
    // lose what is in it)
    final pageBox = tester.renderObject(find.byKey(const ValueKey('page-0')));
    expect(find.byKey(const ValueKey('presence-frame')), findsNothing);
    await tester.runAsync(() async {
      attempt.session!.announcePage(0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('presence-frame')), findsOneWidget);
    expect(identical(tester.renderObject(find.byKey(const ValueKey('page-0'))), pageBox), isTrue);
    await tester.runAsync(() async {
      attempt.session!.announcePage(3);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('presence-frame')), findsNothing);
    expect(identical(tester.renderObject(find.byKey(const ValueKey('page-0'))), pageBox), isTrue);

    // the person goes elsewhere in the app: the session goes on, and what Ben does is kept in the note
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    expect(service.sessionFor(id)!.state, SessionState.live);
    expect(service.sessionFor(id)!.hasScreen, isFalse);
    await tester.runAsync(() async {
      benNote.textBoxes[0]!.single.controller.text = 'Ben, while Anna was away';
      attempt.session!.localChanged();
      await Future<void>.delayed(const Duration(milliseconds: 1800)); // (and the note is written a moment later)
    });
    final away = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(away.textBoxes[0]!.single.controller.text, 'Ben, while Anna was away');

    // back in the note: it shows that, and is in the session again
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey('${id}2'), noteId: id, repository: repo, collab: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
    expect(find.text('Ben, while Anna was away'), findsOneWidget);
    expect(service.sessionFor(id)!.hasScreen, isTrue);

    // ending the session from the panel
    await tester.ensureVisible(find.byKey(const ValueKey('live-button')));
    await tester.tap(find.byKey(const ValueKey('live-button')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('live-end')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(service.sessionFor(id)!.state, SessionState.ended);
    expect(attempt.session!.state, SessionState.ended);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';

import '../ink_prefetch_test.dart' show FakeReader, word;

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('in a session between two editors of one person only the host reads the handwriting', (tester) async {
    tester.view.physicalSize = const Size(1800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository hostRepo, guestRepo;
    late CollabService host, guest;
    late String id;
    late Directory dir;
    final hub = LoopbackHub();
    final hostReader = FakeReader((s) => 'host read');
    final guestReader = FakeReader((s) => 'guest read');
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('own_editors_');
      final hostDb = await AppDatabase.open(path: '${dir.path}/h.db');
      final guestDb = await AppDatabase.open(path: '${dir.path}/g.db');
      hostRepo = NoteRepository(hostDb);
      guestRepo = NoteRepository(guestDb);
      host = CollabService(hostRepo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/hc')..createSync());
      guest = CollabService(guestRepo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/gc')..createSync());
      await host.load();
      await guest.load();
      await host.setName('Anna');
      await guest.setName('Anna');
      id = await hostRepo.createNote(title: 'Plan');
      final seeded = (await hostRepo.loadNote(id))!;
      seeded.strokes[0] = word('w', 300, 300);
      await hostRepo.saveNote(seeded);
      await guestDb.insert('notes', {'id': id, 'title': 'Plan', 'created_at': 1, 'updated_at': 1});
    });
    addTearDown(() => dir.deleteSync(recursive: true));

    await tester.pumpWidget(Column(textDirection: TextDirection.ltr, children: [
      Expanded(child: MaterialApp(home: FixedPageNoteEditor(key: const ValueKey('host-editor'), noteId: id, repository: hostRepo, collab: host, handwriting: hostReader, inkIdle: const Duration(milliseconds: 40)))),
      Expanded(child: MaterialApp(home: FixedPageNoteEditor(key: const ValueKey('guest-editor'), noteId: id, repository: guestRepo, collab: guest, handwriting: guestReader, inkIdle: const Duration(milliseconds: 40)))),
    ]));
    Future<void> settle([int ms = 300]) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump(const Duration(milliseconds: 300)); // (the editor's timers run on the test clock)
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    await settle();
    await settle();

    // the session the way the sync services start it: the first device hosts, the other joins
    final invite = SessionInvite.create('');
    // (started from the test's own zone, as the sync services do from the app's: the editors' futures need the pumps)
    var hosted = false, joined = false;
    host.startOwnHosting(id, invite).then((ok) => hosted = ok);
    for (var i = 0; i < 30 && !hosted; i++) {
      await settle(100);
    }
    expect(hosted, isTrue, reason: 'the host did not start');
    guest.joinOwn(id, invite).then((ok) => joined = ok);
    for (var i = 0; i < 30 && !joined; i++) {
      await settle(100);
    }
    expect(joined, isTrue, reason: 'the guest did not join');
    await settle(600);

    await settle(1500);
    await settle(1500);
    // (the strokes came to the guest through the session: it did not read them)
    expect(hostReader.calls, isNotEmpty, reason: 'the host did not read');
    expect(guestReader.calls, isEmpty, reason: 'the guest read the handwriting');

    // (a live session watches its links with a timer, as it holds a connection: it is ended, as the app does when the note is closed)
    var ended = false;
    Future.wait([guest.endOwn(id), host.endOwn(id)]).then((_) => ended = true);
    for (var i = 0; i < 30 && !ended; i++) {
      await settle(100);
    }
    expect(ended, isTrue, reason: 'the sessions did not end');
  });
}

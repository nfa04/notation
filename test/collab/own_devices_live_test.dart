import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke line(String id, double y) => DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

Future<void> settle([int n = 40]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the same note on two devices of one person: one hosts, the other joins without being asked, both have both drawings and then follow each other', () async {
    final root = await Directory.systemTemp.createTemp('own_live_');
    addTearDown(() => root.delete(recursive: true));
    final hostDb = await AppDatabase.open(path: '${root.path}/h.db');
    final guestDb = await AppDatabase.open(path: '${root.path}/g.db');
    addTearDown(() async {
      await hostDb.close();
      await guestDb.close();
    });
    final hostNotes = NoteRepository(hostDb), guestNotes = NoteRepository(guestDb);
    for (final d in ['hc', 'gc']) {
      Directory('${root.path}/$d').createSync();
    }
    final host = CollabService(hostNotes, builtInServer: '', supportDirectory: () async => Directory('${root.path}/hc'));
    final guest = CollabService(guestNotes, builtInServer: '', supportDirectory: () async => Directory('${root.path}/gc'));
    addTearDown(host.dispose);
    addTearDown(guest.dispose);
    await host.load();
    await guest.load();
    await host.setName('Anna');
    await guest.setName('Anna');

    // the same note on both (synced earlier), each with a drawing the other does not have
    final id = await hostNotes.createNote(title: 'Plan');
    await guestDb.insert('notes', {'id': id, 'title': 'Plan', 'created_at': 1, 'updated_at': 1});
    await hostNotes.saveNote((await hostNotes.loadNote(id))!..strokes = {0: [line('on-host', 10)]});
    await guestNotes.saveNote((await guestNotes.loadNote(id))!..strokes = {0: [line('on-guest', 60)]});

    // what the open editor of the host does: the session is hosted with the note on screen
    final onScreen = (await hostNotes.loadNote(id))!;
    host.registerEditor(
      id,
      EditorHooks(
        start: (_) async {},
        merge: (_) async {},
        startOwn: (invite, transport) async {
          await host.startHosting(
            id,
            CollabBinding(
              note: () => onScreen,
              change: (f) => f(),
              makeBox: (boxId) => TextBoxWidgetModel(id: boxId, position: Offset.zero),
              saveImage: host.saveImage,
              onNoteField: (f, d) => Replica.applyNoteField(onScreen, f, d),
            ),
            invite: invite,
            transport: transport,
            trustAll: true,
          );
        },
      ),
    );
    var bound = 0;
    guest.registerEditor(id, EditorHooks(start: (_) async {}, merge: (_) async {}, bind: () => bound++));

    final hub = LoopbackHub();
    final invite = SessionInvite.create('');
    expect(await host.startOwnHosting(id, invite, hub.host), isTrue);
    expect(host.ownLiveNotes, {id});
    expect(await guest.joinOwn(id, invite, hub.guest), isTrue); // (nobody was asked)
    expect(bound, 1); // the open editor takes part
    await settle();

    // both have both drawings
    expect(onScreen.strokes[0]!.map((s) => s.id).toSet(), {'on-host', 'on-guest'});
    final saved = (await guestNotes.loadNote(id))!;
    expect(saved.strokes[0]!.map((s) => s.id).toSet(), {'on-host', 'on-guest'});

    // and from now on what one draws shows on the other: the guest gets the host's new drawing...
    onScreen.strokes[0]!.add(line('later', 120));
    host.sessionFor(id)!.localChanged();
    await settle();
    final guestSession = guest.sessionFor(id)!;
    expect(guestSession.state, SessionState.live);
    expect(guestSession.participants.length, 2);
    await Future<void>.delayed(const Duration(milliseconds: 1200)); // (a note without a screen is saved a second after it changed)
    expect((await guestNotes.loadNote(id))!.strokes[0]!.map((s) => s.id).toSet(), contains('later'), reason: 'the host\'s new drawing did not reach the guest');

    // ... once the guest has a screen, what it draws reaches the host, and what the host draws shows on that screen
    final guestScreen = (await guestNotes.loadNote(id))!;
    guestSession.attach(CollabBinding(
      note: () => guestScreen,
      change: (f) => f(),
      makeBox: (boxId) => TextBoxWidgetModel(id: boxId, position: Offset.zero),
      saveImage: guest.saveImage,
      onNoteField: (f, d) => Replica.applyNoteField(guestScreen, f, d),
    ));
    guestScreen.strokes[0]!.add(line('from-guest-screen', 150));
    guestSession.localChanged();
    await settle();
    expect(onScreen.strokes[0]!.map((s) => s.id).toSet(), contains('from-guest-screen'), reason: 'the guest\'s drawing did not reach the host');
    onScreen.strokes[0]!.add(line('host-again', 180));
    host.sessionFor(id)!.localChanged();
    await settle();
    expect(guestScreen.strokes[0]!.map((s) => s.id).toSet(), contains('host-again'), reason: 'the host\'s drawing did not show on the guest\'s screen');

    // the note is closed on the host: the session ends, the guest is told
    await host.endOwn(id);
    await settle();
    expect(host.hasSession(id), isFalse);
    expect(guest.hasSession(id), isFalse);
  });
}

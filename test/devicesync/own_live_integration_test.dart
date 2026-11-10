import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/live_notes.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_link.dart';
import 'package:notes/models/canvas_models.dart';

import 'fakes.dart';
import 'harness.dart';

DrawingStroke line(String id, double y, {int points = 6}) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < points; i++) Offset(10.0 + i * 0.5, y + i % 7)]);

Future<void> until(bool Function() ok, {int ms = 8000, String? reason}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail(reason ?? 'timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _Open {
  final Device device;
  late final CollabService collab;
  late DeviceSyncService sync;
  late NoteData onScreen;
  _Open(this.device);
}

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a note open on two paired devices: each sees what the other draws, also when the note is big', () async {
    final root = await Directory.systemTemp.createTemp('ownlive_');
    addTearDown(() => root.delete(recursive: true));
    final server = FakeServer();
    final a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    final b = await Device.create('Tablet', root, profileId: 'bbbbbbbbbbbbbbbb');
    addTearDown(() async {
      await a.db.close();
      await b.db.close();
    });
    final ends = {'a': _Open(a), 'b': _Open(b)};
    for (final e in ends.values) {
      final dir = Directory('${root.path}/c-${e.device.name}')..createSync();
      e.collab = CollabService(e.device.repo, builtInServer: '', supportDirectory: () async => dir);
      addTearDown(e.collab.dispose);
      await e.collab.load();
      await e.collab.setName('Anna');
      e.sync = DeviceSyncService(
        settings: e.device.settings,
        keys: MemorySyncKeys(),
        library: e.device.library,
        profile: e.device.profile,
        serverOf: () => 'wss://signal.example',
        changes: e.device.repo.changes,
        openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
        makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
        heartbeat: const Duration(milliseconds: 300),
        offlineAfter: const Duration(milliseconds: 900),
        resync: const Duration(seconds: 30),
        changeDelay: const Duration(milliseconds: 150),
      );
      addTearDown(e.sync.dispose);
      await e.sync.load();
      e.sync.live = CollabLiveNotes(e.collab);
    }
    final x = ends['a']!, y = ends['b']!;

    // paired, the way the person does it
    final link = await x.sync.offerLink();
    await y.sync.joinWith(SyncLink.parse(link.toLink())!);
    await until(() => x.sync.requests.isNotEmpty && y.sync.joinCodeNeedsAnswer, reason: 'no request');
    y.sync.confirmJoinCode(true);
    x.sync.answer(x.sync.requests.single.id, true);
    await until(() => y.sync.joined && y.sync.isSetUp, reason: 'not joined');
    await x.sync.setAuto(true);
    await y.sync.setAuto(true);

    // the same note on both (a big one: the welcome of the session is large), and an editor each
    final id = await x.device.repo.createNote(title: 'Shared');
    await y.device.db.insert('notes', {'id': id, 'title': 'Shared', 'created_at': 1, 'updated_at': 1});
    for (final e in ends.values) {
      e.onScreen = (await e.device.repo.loadNote(id))!;
      e.onScreen.strokes = {0: [for (var i = 0; i < 400; i++) line('${e.device.name}-$i', 10.0 + i, points: 60)]};
      await e.device.repo.saveNote(e.onScreen);
      CollabBinding bindingOf() => CollabBinding(
            note: () => e.onScreen,
            change: (f) => f(),
            makeBox: (boxId) => TextBoxWidgetModel(id: boxId, position: Offset.zero),
            saveImage: e.collab.saveImage,
            onNoteField: (f, d) => Replica.applyNoteField(e.onScreen, f, d),
          );
      e.collab.registerEditor(
        id,
        EditorHooks(
          start: (_) async {},
          merge: (_) async {},
          save: () async => e.device.repo.saveNote(e.onScreen),
          bind: () => e.collab.sessionFor(id)?.attach(bindingOf()),
          startOwn: (invite, transport) async {
            await e.collab.startHosting(id, bindingOf(), invite: invite, transport: transport, trustAll: true);
          },
        ),
      );
    }
    await until(() => x.sync.peers.single.online && y.sync.peers.single.online, reason: 'not online');

    x.sync.setOpenNotes({id});
    y.sync.setOpenNotes({id});
    await until(() => x.collab.ownLiveNotes.contains(id) && y.collab.ownLiveNotes.contains(id), reason: 'no session on both');
    final hostIsA = x.sync.deviceId!.compareTo(y.sync.deviceId!) < 0;
    final host = hostIsA ? x : y, guest = hostIsA ? y : x;
    await until(() => host.collab.ownStatus(id)?.people == 2 && guest.collab.sessionFor(id)?.isLive == true, reason: 'not both in the session');

    // everything each had is on both
    await until(() => host.onScreen.strokes[0]!.length == 800 && guest.onScreen.strokes[0]!.length == 800, ms: 15000, reason: 'the notes did not come together: ${host.onScreen.strokes[0]!.length} / ${guest.onScreen.strokes[0]!.length}');

    // and what is drawn afterwards shows on the other, in both directions
    host.onScreen.strokes[0]!.add(line('from-host', 900));
    host.collab.sessionFor(id)!.localChanged();
    await until(() => guest.onScreen.strokes[0]!.any((s) => s.id == 'from-host'), reason: 'host -> guest');
    guest.onScreen.strokes[0]!.add(line('from-guest', 950, points: 5000)); // (a long one)
    guest.collab.sessionFor(id)!.localChanged();
    await until(() => host.onScreen.strokes[0]!.any((s) => s.id == 'from-guest'), reason: 'guest -> host');
    expect(host.onScreen.strokes[0]!.firstWhere((s) => s.id == 'from-guest').points.length, 5000);
  });
}

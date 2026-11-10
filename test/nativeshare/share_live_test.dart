import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/devicesync/live_notes.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/nativeshare/share_live.dart';
import 'package:notes/nativeshare/share_model.dart';

import '../devicesync/fakes.dart';
import '../devicesync/harness.dart';
import 'fake_share_provider.dart';

DrawingStroke line(String id, double y, {int points = 6}) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < points; i++) Offset(10.0 + i * 0.5, y + i % 7)]);

Future<void> until(bool Function() ok, {int ms = 10000, String? reason}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail(reason ?? 'timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// The secret of a share for working live, as the room wants it.
SyncSecret secretOf(NativeShare s) => SyncSecret(Uint8List.fromList(base64.decode(s.liveSecret!)));

/// One person's side: a device, the live sessions, the shares, and the note on the screen.
class _Side {
  final Device device;
  late final CollabService collab;
  late final NativeShareService shares;
  late NoteData onScreen;
  _Side(this.device);
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late FakeServer server;
  late FakeShareHub hub;
  late _Side alice, bob;

  Future<_Side> side(String name, String user, {String? ownerOf}) async {
    final s = _Side(await Device.create(name, root));
    final dir = Directory('${root.path}/c-$name')..createSync();
    s.collab = CollabService(s.device.repo, builtInServer: '', supportDirectory: () async => dir);
    await s.collab.load();
    await s.collab.setName(name);
    s.shares = NativeShareService(
      db: s.device.db,
      settings: s.device.settings,
      library: s.device.library,
      providers: [hub.as(user)],
      deviceId: () => s.device.identity.id,
      deviceName: () => name,
      identity: () => s.device.identity,
      serverOf: () => 'wss://signal.example',
      openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
      makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
      every: const Duration(hours: 1),
      afterChange: const Duration(hours: 1),
      retryDelays: const [],
      liveHeartbeat: const Duration(milliseconds: 300),
      liveOfflineAfter: const Duration(milliseconds: 900),
    );
    s.shares.live = CollabLiveNotes(s.collab);
    await s.shares.load();
    return s;
  }

  /// An editor for the note, as the note screen has one, over the note [s.onScreen].
  void openEditor(_Side s, String id) {
    s.onScreen = NoteData(id: id, title: 'Optics');
    CollabBinding bindingOf() => CollabBinding(
          note: () => s.onScreen,
          change: (f) => f(),
          makeBox: (boxId) => TextBoxWidgetModel(id: boxId, position: Offset.zero),
          saveImage: s.collab.saveImage,
          onNoteField: (f, d) => Replica.applyNoteField(s.onScreen, f, d),
        );
    s.collab.registerEditor(
      id,
      EditorHooks(
        start: (_) async {},
        merge: (_) async {},
        save: () async => s.device.repo.saveNote(s.onScreen),
        bind: () => s.collab.sessionFor(id)?.attach(bindingOf()),
        startOwn: (invite, transport) async {
          await s.collab.startHosting(id, bindingOf(), invite: invite, transport: transport, trustAll: true);
        },
      ),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sharelive_');
    server = FakeServer();
    hub = FakeShareHub();
    alice = await side('Alice', 'alice');
    bob = await side('Bob', 'bob');
  });
  tearDown(() async {
    for (final s in [alice, bob]) {
      s.shares.dispose();
      await s.shares.disposed;
      s.collab.dispose();
      await s.device.db.close();
    }
    await root.delete(recursive: true);
  });

  const bobP = SharePerson('bob', 'Bob');

  /// Alice shares a note with Bob; both have it, and have said they take part.
  Future<String> sharedNote(ShareRole role) async {
    final id = await alice.device.repo.createNote(title: 'Optics');
    await alice.shares.shareNote(id, alice.shares.usable.single, bobP, role);
    await bob.shares.refreshIncoming();
    final inn = await bob.shares.accept(bob.shares.pending.single);
    await bob.shares.syncShare(inn.id);
    expect(bob.shares.statusOf(inn.id).problem, isNull);
    await alice.shares.syncNow();
    return id;
  }

  test('a note of a share that is open on both people\'s devices is worked on live: each sees what the other draws', () async {
    final id = await sharedNote(ShareRole.editor);
    expect(alice.shares.given.single.liveSecret, isNotNull);
    expect(bob.shares.received.single.liveSecret, alice.shares.given.single.liveSecret, reason: 'it comes with the share');
    openEditor(alice, id);
    openEditor(bob, id);
    alice.onScreen.strokes = {0: [line('a-1', 10), line('a-2', 30)]};
    bob.onScreen.strokes = {0: [line('b-1', 50)]};

    alice.shares.setOpenNotes({id});
    bob.shares.setOpenNotes({id});
    await until(() => alice.collab.ownLiveNotes.contains(id) && bob.collab.ownLiveNotes.contains(id), reason: 'no session on both');
    final aliceHosts = alice.device.identity.id.compareTo(bob.device.identity.id) < 0;
    final host = aliceHosts ? alice : bob, guest = aliceHosts ? bob : alice;
    await until(() => host.collab.ownStatus(id)?.people == 2 && guest.collab.sessionFor(id)?.isLive == true, reason: 'not both in the session');
    await until(() => host.onScreen.strokes[0]!.length == 3 && guest.onScreen.strokes[0]!.length == 3, reason: 'the notes did not come together');

    host.onScreen.strokes[0]!.add(line('from-host', 90));
    host.collab.sessionFor(id)!.localChanged();
    await until(() => guest.onScreen.strokes[0]!.any((s) => s.id == 'from-host'), reason: 'host -> guest');
    guest.onScreen.strokes[0]!.add(line('from-guest', 120, points: 3000));
    guest.collab.sessionFor(id)!.localChanged();
    await until(() => host.onScreen.strokes[0]!.any((s) => s.id == 'from-guest'), reason: 'guest -> host');
  });

  test('when the session is over the note is saved and shared, and what both had is not taken for a change made on both sides', () async {
    final id = await sharedNote(ShareRole.editor);
    openEditor(alice, id);
    openEditor(bob, id);
    alice.onScreen.strokes = {0: [line('a-1', 10)]};
    bob.onScreen.strokes = {0: [line('b-1', 50)]};
    alice.shares.setOpenNotes({id});
    bob.shares.setOpenNotes({id});
    await until(() => alice.collab.ownLiveNotes.contains(id) && bob.collab.ownLiveNotes.contains(id), reason: 'no session on both');
    await until(() => alice.onScreen.strokes[0]!.length == 2 && bob.onScreen.strokes[0]!.length == 2, reason: 'the notes did not come together');

    // both close the note
    alice.shares.setOpenNotes({});
    bob.shares.setOpenNotes({});
    await until(() => alice.collab.ownLiveNotes.isEmpty && bob.collab.ownLiveNotes.isEmpty, reason: 'the sessions did not end');
    await alice.shares.idle;
    await bob.shares.idle;

    await alice.shares.syncNow();
    await bob.shares.syncNow();
    await alice.shares.syncNow();
    expect(await alice.device.repo.listNotes(), hasLength(1), reason: 'no copy "from before the sync"');
    expect(await bob.device.repo.listNotes(), hasLength(1));
    for (final s in [alice, bob]) {
      final saved = (await s.device.repo.loadNote(id))!;
      expect({for (final x in saved.strokes[0] ?? <DrawingStroke>[]) x.id}, {'a-1', 'b-1'}, reason: 'what both drew is in the note on both');
    }
  });

  test('a person who may only view is not in the room, and one who is but is not on the list of those who write is turned away', () async {
    final id = await sharedNote(ShareRole.viewer);
    openEditor(alice, id);
    openEditor(bob, id);
    alice.shares.setOpenNotes({id});
    bob.shares.setOpenNotes({id});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(server.rooms.values.expand((r) => r), hasLength(1), reason: 'only the one who writes comes into the room');
    expect(bob.collab.ownLiveNotes, isEmpty);

    // a viewer can read the secret in the folder: the room is open to him, but his device is not on the list of those who write
    final secret = alice.shares.given.single.liveSecret!;
    // (his id is higher than hers, so that he is the one who has to join her session: the case that has to be refused)
    var viewerIdentity = await DeviceIdentity.create();
    while (viewerIdentity.id.compareTo(alice.device.identity.id) <= 0) {
      viewerIdentity = await DeviceIdentity.create();
    }
    final viewerLive = FakeLive();
    final viewerLiveShare = ShareLive(
      shareId: 'x',
      secret: secretOf(alice.shares.given.single),
      serverOf: () => 'wss://signal.example',
      identity: viewerIdentity,
      deviceName: 'Viewer',
      live: viewerLive,
      library: bob.device.library,
      // (he lies about who may write: the host does not)
      participants: () async => [PairedDevice(id: alice.device.identity.id, name: 'Alice', publicKey: alice.device.identity.publicKey, addedAt: 0)],
      openRoom: (srv, s) async => FakeRoom(server, (await s.roomKeys()).room),
      makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
      heartbeat: const Duration(milliseconds: 300),
    );
    expect(secret, isNotEmpty);
    viewerLiveShare.setOpen({id});
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(viewerLive.joined, isEmpty, reason: 'he could not prove he may write');
    expect(viewerLive.log, isEmpty, reason: 'he did not get a session, and did not start one of his own');
    expect(alice.collab.ownLiveNotes, isEmpty, reason: 'she did not take him in');
    await viewerLiveShare.dispose();
  });

  test('a note that has a live session of another kind on this device is left to that one', () async {
    final id = await sharedNote(ShareRole.editor);
    final fake = FakeLive()..sessions.add(id); // (a session with the person\'s own devices, say)
    final lives = ShareLive(
      shareId: 'x',
      secret: secretOf(alice.shares.given.single),
      serverOf: () => 'wss://signal.example',
      identity: alice.device.identity,
      deviceName: 'Alice',
      live: fake,
      library: alice.device.library,
      participants: () async => const [],
      openRoom: (srv, s) async => FakeRoom(server, (await s.roomKeys()).room),
      makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
    );
    lives.setOpen({id});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(lives.announced, isEmpty, reason: 'the others are not told it is open here');
    expect(fake.log, isEmpty);
    await lives.dispose();
  });

  test('the room of a share is left when the last note of it is closed, and the share ending ends it', () async {
    final id = await sharedNote(ShareRole.editor);
    openEditor(alice, id);
    alice.shares.setOpenNotes({id});
    await until(() => server.rooms.values.expand((r) => r).isNotEmpty, reason: 'not in the room');
    alice.shares.setOpenNotes({});
    await until(() => server.rooms.values.expand((r) => r).isEmpty, reason: 'still in the room');
    alice.shares.setOpenNotes({id});
    await until(() => server.rooms.values.expand((r) => r).isNotEmpty);
    await alice.shares.stopSharing(alice.shares.given.single);
    await until(() => server.rooms.values.expand((r) => r).isEmpty, reason: 'in the room of a share that is over');
  });
}

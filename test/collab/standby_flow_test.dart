import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/cloud_share.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/live_marker.dart';
import 'package:notes/collab/note_delta.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/share_storage.dart';
import 'package:notes/collab/signaling.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/sync/caldav_service.dart';

DrawingStroke line(double y) => DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

Future<void> settle([int n = 40]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

class _Storage extends ShareStorage {
  final stored = <String, Uint8List>{};
  @override
  String get label => 'Mem';
  @override
  bool get available => true;
  @override
  Duration get keeps => const Duration(days: 7);
  @override
  Future<StoredFile> store(Uint8List sealed) async {
    final url = Uri.parse('https://storage.example/Mem/${stored.length}');
    stored[url.path] = sealed;
    return StoredFile(url, url.path);
  }

  @override
  Future<void> replace(String ref, Uint8List sealed) async => stored[ref] = sealed;
  @override
  bool handles(Uri url) => url.host == 'storage.example';
  @override
  Future<Uint8List> fetch(Uri url) async => stored[url.path]!;
}

/// A room on the signalling server that the test can knock at.
class _Room extends SignalingClient {
  _Room(super.invite);
  final knocks = StreamController<Map<String, Object?>>.broadcast();
  bool closed = false;
  @override
  Stream<Map<String, Object?>> get messages => knocks.stream;
  @override
  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {}
  @override
  Future<void> close() async => closed = true;
  @override
  void wake() {}
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late LoopbackHub hub;
  late NoteRepository hostRepo, guestRepo;
  late CollabService host, guest;
  late _Storage storage;
  late CloudShare share;
  final rooms = <_Room>[];
  final notices = <ShareNotice>[];
  late String noteId;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('standby_');
    hub = LoopbackHub();
    hostRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/host.db'));
    guestRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/guest.db'));
    host = CollabService(hostRepo,
        builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/h')..createSync());
    guest = CollabService(guestRepo,
        builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/g')..createSync());
    await host.load();
    await guest.load();
    await host.setServer('wss://signal.example');
    await host.setName('Anna');
    await guest.setName('Ben');

    storage = _Storage();
    Directory('${dir.path}/hf').createSync();
    final files = NoteFileService(hostRepo, supportDirectory: () async => Directory('${dir.path}/hf'));
    share = CloudShare(files, [storage], markers: LiveMarkers([storage], _Secret()));
    rooms.clear();
    notices.clear();
    host.attachShare(share, standbyClient: (invite) => _Room(invite)..also(rooms.add), startInbox: false);
    host.notices.listen(notices.add);

    noteId = await hostRepo.createNote(title: 'Plan');
    final n = (await hostRepo.loadNote(noteId))!..strokes = {0: [line(10)]};
    await hostRepo.saveNote(n);
  });
  tearDown(() async {
    host.dispose();
    dir.deleteSync(recursive: true);
  });

  test('sharing a copy makes the app wait in a room; someone who knocks gets a session, and comes in unasked', () async {
    final copy = await share.shareCopy(noteId, from: 'Anna');
    await settle();
    expect(host.standbyNotes, {noteId});
    expect(rooms, hasLength(1));
    expect(host.sessionFor(noteId), isNull, reason: 'no session until someone comes');

    // the guest reads the marker with the key of the link
    final offer = await share.liveSession(CopyInvite.parse(copy.toLink())!);
    expect(offer, isNotNull);
    expect(offer!.secret, rooms.single.invite.secret);

    // a knock in the room: a session is built in that very room
    rooms.single.knocks.add({'t': 'hello', 'from': 'abc'});
    await settle(60);
    final session = host.sessionFor(noteId)!;
    expect(session.state, SessionState.live);
    expect(host.inviteFor(noteId)!.secret, offer.secret);
    expect(notices.map((n) => n.kind), [ShareNoticeKind.opened]);
    expect(notices.single.title, 'Plan');
    expect(rooms.single.closed, isTrue, reason: 'the room belongs to the session now');

    // the guest, with the copy's key, is let in without the host being asked
    final attempt = guest.join(offer, proofKey: copy.key);
    await settle(80);
    expect(host.requests, isEmpty);
    expect(attempt.noteId, isNotNull);
    expect(notices.map((n) => n.kind), [ShareNoticeKind.opened, ShareNoticeKind.joined]);
    expect(notices.last.who, 'Ben');
    expect(session.participants.map((p) => p.name), containsAll(['Anna', 'Ben']));
    final made = (await guestRepo.loadNote(attempt.noteId!))!;
    expect(made.strokes[0]!.single.id, (await hostRepo.loadNote(noteId))!.strokes[0]!.single.id);
    expect(guest.shared.withMe, {attempt.noteId}, reason: 'a note that came from a session is shared with the guest');
    expect(guest.shared.fromWhom(attempt.noteId!), 'Anna');

    // the marker now has the invite of the session (which is the room's)
    expect(host.hostedLink(noteId), host.inviteFor(noteId)!.toLink());
  });

  test('without the key of a copy the host is asked, as ever; a wrong proof counts for nothing', () async {
    final copy = await share.shareCopy(noteId);
    await settle();
    rooms.single.knocks.add({'t': 'hello', 'from': 'abc'});
    await settle(60);
    final invite = host.inviteFor(noteId)!;

    final strangers = guest.join(invite); // knows the room, not the copy
    await settle(60);
    expect(host.requests.single.request.name, 'Ben');
    expect(strangers.noteId, isNull);

    final wrong = guest.join(invite, proofKey: Uint8List.fromList(List.filled(32, 9)));
    await settle(60);
    expect(host.requests, hasLength(2), reason: 'asked again: the proof did not fit');
    expect(wrong.noteId, isNull);
    expect(copy.key.length, 32);
  });

  test('knocks while a session runs or is being made do not make another', () async {
    await share.shareCopy(noteId);
    await settle();
    final room = rooms.single;
    room.knocks.add({'t': 'hello', 'from': 'a'});
    room.knocks.add({'t': 'hello', 'from': 'b'});
    await settle(60);
    expect(notices.where((n) => n.kind == ShareNoticeKind.opened), hasLength(1));
    final first = host.sessionFor(noteId);
    await host.end(noteId);
    await settle();
    expect(host.standbyNotes, {noteId}, reason: 'waiting in the room again');
    expect(rooms, hasLength(2));
    expect(first!.state, SessionState.ended);
  });

  test('a note that is open in an editor starts its session there, and the person is not asked for anything', () async {
    await share.shareCopy(noteId);
    await settle();
    SessionInvite? started;
    host.registerEditor(noteId, EditorHooks(start: (invite) async => started = invite, merge: (ops) async {}));
    rooms.single.knocks.add({'t': 'hello', 'from': 'a'});
    await settle(40);
    expect(started?.secret, rooms.single.invite.secret);
    expect(host.sessionFor(noteId), isNull, reason: 'the editor makes the session');
  });

  test('a guest who has the note already comes in with it: the host\'s changes arrive, and what the guest did meanwhile stays and goes to the host', () async {
    final copy = await share.shareCopy(noteId);
    await settle();

    // the guest was given a copy earlier and edited it while the host was away
    final bytes = await NoteFileService(hostRepo, supportDirectory: () async => Directory('${dir.path}/hf')).exportBytes(noteId);
    final imported = await NoteFileService(guestRepo, supportDirectory: () async => Directory('${dir.path}/gf')..createSync()).importBytes(bytes!);
    final base = NoteDelta.digests((await guestRepo.loadNote(imported.noteId))!);
    final mine = (await guestRepo.loadNote(imported.noteId))!
      ..title = 'Plan (Ben)'
      ..strokes[1] = [line(200)];
    await guestRepo.saveNote(mine);
    final offline = NoteDelta.changesSince((await guestRepo.loadNote(imported.noteId))!, base);
    expect(offline, isNotEmpty);

    // meanwhile the host drew something
    final hn = (await hostRepo.loadNote(noteId))!..strokes[0]!.add(line(60));
    await hostRepo.saveNote(hn);

    rooms.single.knocks.add({'t': 'hello', 'from': 'abc'});
    await settle(60);
    final invite = host.inviteFor(noteId)!;
    final attempt = guest.join(invite, intoNoteId: imported.noteId, offline: offline, proofKey: copy.key);
    await settle(100);
    expect(attempt.noteId, imported.noteId, reason: 'the same note, not a new one');
    expect(host.requests, isEmpty);

    final onGuest = (await guestRepo.loadNote(imported.noteId))!;
    expect(onGuest.title, 'Plan (Ben)', reason: 'what the guest changed stays');
    expect(onGuest.strokes[0]!.length, 2, reason: 'what the host drew has come');
    expect(onGuest.strokes[1]!.single.points.first.dy, 200);

    final session = host.sessionFor(noteId)!;
    await settle(300); // (a session without a screen writes the note a second after it changed)
    final onHost = (await hostRepo.loadNote(noteId))!;
    expect(onHost.title, 'Plan (Ben)', reason: 'and went to the host');
    expect(onHost.strokes[1]!.single.points.first.dy, 200);
    expect(session.participants.length, 2);
  });

  test('changes a guest made on a copy while the host was away go into the session that runs, and reach the others at once', () async {
    final copy = await share.shareCopy(noteId);
    await settle();
    rooms.single.knocks.add({'t': 'hello', 'from': 'abc'});
    await settle(60);
    final attempt = guest.join(host.inviteFor(noteId)!, proofKey: copy.key);
    await settle(80);
    final onGuest = (await guestRepo.loadNote(attempt.noteId!))!;
    final liveGuest = guest.sessionFor(attempt.noteId!)!;
    var redraws = 0;
    liveGuest.attach(CollabBinding(
      note: () => onGuest,
      change: (f) {
        f();
        redraws++;
      },
      makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
      saveImage: guest.saveImage,
      onNoteField: (f, d) => Replica.applyNoteField(onGuest, f, d),
    ));

    // a third person's changes, made earlier on their copy, arrive through the inbox
    final base = NoteDelta.digests(onGuest);
    final theirs = (await hostRepo.loadNote(noteId))!..strokes[1] = [line(333)];
    final ops = NoteDelta.changesSince(theirs, base);
    expect(ops, isNotEmpty);
    await host.applyOffline(noteId, 'Cleo', ops);
    await settle(80);

    expect(onGuest.strokes[1]!.single.points.first.dy, 333, reason: 'the guest in the session sees it at once');
    expect(redraws, greaterThan(0));
    expect(notices.where((n) => n.kind == ShareNoticeKind.merged).single.who, 'Cleo');
    await settle(300);
    expect((await hostRepo.loadNote(noteId))!.strokes[1]!.single.points.first.dy, 333, reason: 'and the saved note has it');
  });
}

extension<T> on T {
  void also(void Function(T) f) => f(this);
}
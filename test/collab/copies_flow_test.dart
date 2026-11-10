import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/cloud_share.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/live_marker.dart';
import 'package:notes/collab/nextcloud_storage.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/share_storage.dart';
import 'package:notes/collab/signaling.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/brush_library.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/models/authorship.dart';
import 'package:notes/models/brush_desc.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_nextcloud.dart';

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

class _Room extends SignalingClient {
  _Room(super.invite);
  final knocks = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get messages => knocks.stream;
  @override
  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {}
  @override
  Future<void> close() async {}
  @override
  void wake() {}
}

DrawingStroke line(String id, double y) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

Future<void> settle([int n = 40]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late FakeNextcloud nextcloud;
  late LoopbackHub hub;
  late NoteRepository hostNotes, guestNotes;
  late CollabService host, guest;
  late CloudShare hostShare, guestShare;
  late _Room room;
  late Database hostDb;
  late String noteId;
  final guestNotices = <ShareNotice>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('copies_');
    nextcloud = FakeNextcloud();
    await nextcloud.start();
    hub = LoopbackHub();
    hostDb = await AppDatabase.open(path: '${root.path}/h.db');
    final guestDb = await AppDatabase.open(path: '${root.path}/g.db');
    hostNotes = NoteRepository(hostDb);
    guestNotes = NoteRepository(guestDb);
    for (final d in ['hs', 'gs', 'hc', 'gc']) {
      Directory('${root.path}/$d').createSync();
    }
    final caldav = CalDavService(SettingsRepository(hostDb), TaskRepository(hostDb), secret: _Secret());
    await caldav.save('${nextcloud.address}/remote.php/dav', 'alice', 'app-pw', taskCalendar: null, eventCalendars: {});
    final hostStorage = NextcloudStorage(caldav);
    download(Uri u) => downloadShared(u, allowInsecure: true);
    final hostFiles = NoteFileService(hostNotes, supportDirectory: () async => Directory('${root.path}/hs'));
    hostShare = CloudShare(hostFiles, [hostStorage], markers: LiveMarkers([hostStorage], _Secret()), download: download);
    hostShare.markers
      ..editedOf = ((id) async => (await hostNotes.noteTimes(id))?.edited)
      ..exportOf = hostFiles.exportBytes;
    final guestStorage = NextcloudStorage(CalDavService(SettingsRepository(guestDb), TaskRepository(guestDb), secret: _Secret()));
    guestShare = CloudShare(NoteFileService(guestNotes, supportDirectory: () async => Directory('${root.path}/gs')), [guestStorage], download: download);

    host = CollabService(hostNotes,
        builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${root.path}/hc'));
    guest = CollabService(guestNotes,
        builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${root.path}/gc'));
    await host.load();
    await guest.load();
    await host.setServer('wss://signal.example');
    await host.setName('Anna');
    await guest.setName('Ben');
    host.attachShare(hostShare, standbyClient: (i) => room = _Room(i), startInbox: false);
    guest.attachShare(guestShare, startInbox: false, copiesStore: _Secret());
    guestNotices.clear();
    guest.notices.listen(guestNotices.add);

    noteId = await hostNotes.createNote(title: 'Plan');
    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!..strokes = {0: [line('s1', 10)]});
  });
  tearDown(() async {
    host.dispose();
    guest.dispose();
    await nextcloud.stop();
    await root.delete(recursive: true);
  });

  Future<(CopyInvite, String)> guestGetsCopy() async {
    final invite = await hostShare.shareCopy(noteId, from: 'Anna');
    final parsed = CopyInvite.parse(invite.toLink())!;
    final result = await guestShare.openCopy(parsed);
    await guest.openedCopies!.add(result.noteId, parsed); // (not rememberCopy: that looks at once, and in this test nobody knocks yet)
    return (invite, result.noteId);
  }

  test('before the changes of a guest are taken in, the note is kept as a version, so the merge can be undone', () async {
    final history = NoteHistory(hostDb, hostNotes, supportDirectory: () async => Directory('${root.path}/hs'));
    host.history = history;
    final (_, copyId) = await guestGetsCopy();
    await hostShare.markers.retire();
    await guestNotes.saveNote((await guestNotes.loadNote(copyId))!..strokes[1] = [line('s7', 90)]);
    await guest.checkCopies();
    await host.checkInboxes();

    final versions = await history.list(noteId);
    expect(versions.single.reason, VersionReason.merge);
    expect(versions.single.who, 'Ben');
    final before = await history.read(versions.single);
    expect(before.note.strokes[1], isNull, reason: 'the note as it was before the guest\'s change');
    expect((await hostNotes.loadNote(noteId))!.strokes[1]!.single.id, 's7');
    history.dispose();
  });

  test('the name in the live settings is the name on what is added, and it goes with offline changes to the owner and with the owner\'s changes to the guest', () async {
    expect(Authorship.name, 'Ben', reason: 'the last name set (the guest\'s)');
    await host.setName('Anna');
    expect(Authorship.name, 'Anna');
    await host.setName('');
    expect(Authorship.name, isNull, reason: 'no name: no author');
    await host.setName('Anna');

    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!..strokes[0]![0].author = 'Anna');
    final (_, copyId) = await guestGetsCopy();
    expect((await guestNotes.loadNote(copyId))!.strokes[0]!.single.author, 'Anna', reason: 'in the copy');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await hostShare.markers.retire();

    // Ben adds a stroke on his copy while Anna is away; Anna adds one meanwhile
    final mine = (await guestNotes.loadNote(copyId))!;
    mine.strokes[1] = [DrawingStroke(id: 'b1', color: Colors.black, width: 3, author: 'Ben', points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, 90.0 + i)])];
    await guestNotes.saveNote(mine);
    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!
      ..strokes[0]!.add(DrawingStroke(id: 'a2', color: Colors.black, width: 3, author: 'Anna', points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, 40.0 + i)])));
    await hostShare.markers.retire();
    await guest.checkCopies();
    await settle();
    await host.checkInboxes();

    Map<String, String?> who(NoteData n) => {for (final l in n.strokes.values) for (final x in l) x.id: x.author};
    expect(who((await hostNotes.loadNote(noteId))!)['b1'], 'Ben', reason: 'Ben\'s stroke reached Anna with his name');
    expect(who((await guestNotes.loadNote(copyId))!), containsPair('a2', 'Anna'), reason: 'and Anna\'s reached Ben with hers');
    expect(who((await guestNotes.loadNote(copyId))!)['b1'], 'Ben');
  });

  test('what the owner changed while the guest was away reaches the guest through the copy, and what the guest changed stays', () async {
    final (_, copyId) = await guestGetsCopy();
    await Future<void>.delayed(const Duration(milliseconds: 5)); // (edits are told apart by the millisecond)
    // the guest changes the copy (offline)
    await guestNotes.saveNote((await guestNotes.loadNote(copyId))!..strokes[1] = [line('s7', 90)]);
    // the owner changes the note, then leaves: the copy up there is put up again on the way out
    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!
      ..title = 'Plan B'
      ..strokes[0]!.add(line('s8', 40)));
    await hostShare.markers.retire();

    await guest.checkCopies();
    await settle();
    final copy = (await guestNotes.loadNote(copyId))!;
    expect(copy.title, 'Plan B');
    expect(copy.strokes[0]!.map((s) => s.id).toSet(), {'s1', 's8'}, reason: 'what the owner drew');
    expect(copy.strokes[1]!.single.id, 's7', reason: 'what the guest drew stays');
    expect(guestNotices.where((n) => n.kind == ShareNoticeKind.merged), hasLength(1));

    // the guest's change still goes to the owner, and the owner's own changes are not undone by it
    expect(nextcloud.dropped, hasLength(1));
    await host.checkInboxes();
    final owner = (await hostNotes.loadNote(noteId))!;
    expect(owner.strokes[1]!.single.id, 's7');
    expect(owner.strokes[0]!.map((s) => s.id).toSet(), {'s1', 's8'});
    expect(owner.title, 'Plan B');

    // nothing new up there: nothing is taken in again
    await guest.checkCopies();
    await settle();
    expect(guestNotices.where((n) => n.kind == ShareNoticeKind.merged), hasLength(1));
  });

  test('a designed brush the owner drew with while the guest was away reaches the guest with the lines, out of the menu, and is kept', () async {
    final brush = BrushDesc(BrushKind.charcoal, 'Dusty', const {'dust': 2.5, 'dryness': 0.5});
    CustomBrushes.sync([(desc: brush, listed: true)]);
    addTearDown(() => CustomBrushes.sync(const []));
    final (_, copyId) = await guestGetsCopy();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!
      ..strokes[0]!.add(DrawingStroke(id: 's9', color: Colors.black, width: 4, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, 70.0 + i)], brush: brush.id)));
    await hostShare.markers.retire();
    CustomBrushes.sync(const []); // (the guest's device has never heard of the brush)

    await guest.checkCopies();
    await settle();
    final copy = (await guestNotes.loadNote(copyId))!;
    expect(copy.strokes[0]!.firstWhere((s) => s.id == 's9').brush, brush.id);
    expect(CustomBrushes.of(brush.id), brush);
    expect(Brushes.isListed(brush.id), isFalse);
    CustomBrushes.sync(const []); // (and after a restart)
    expect((await BrushLibrary(guestNotes.settings).load()).map((b) => b.desc), [brush]);
  });

  test('a copy that could not be put up (no network) goes up at the next try, and nothing is stuck meanwhile', () async {
    final (_, copyId) = await guestGetsCopy();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!..strokes[0]!.add(line('s8', 40)));

    nextcloud.down = true;
    await hostShare.markers.retire(); // the owner leaves without a network
    await hostShare.markers.publish(noteId, force: true); // a beat, still without one
    await hostShare.markers.settled;
    nextcloud.down = false;
    await guest.checkCopies();
    await settle();
    expect((await guestNotes.loadNote(copyId))!.strokes[0]!.map((s) => s.id), ['s1'], reason: 'nothing went up yet');

    await hostShare.markers.publish(noteId, force: true); // the next beat, with a network
    await hostShare.markers.settled;
    await guest.checkCopies();
    await settle();
    expect((await guestNotes.loadNote(copyId))!.strokes[0]!.map((s) => s.id).toSet(), {'s1', 's8'});
  });

  test('the owner deleting something reaches the guest; something the guest changed meanwhile is kept', () async {
    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!..strokes[0]!.add(line('s2', 50)));
    final (_, copyId) = await guestGetsCopy();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // the guest moves s2; the owner deletes both s1 and s2
    final g = (await guestNotes.loadNote(copyId))!;
    g.strokes[0] = [g.strokes[0]!.firstWhere((s) => s.id == 's1'), line('s2', 70)];
    await guestNotes.saveNote(g);
    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!..strokes[0] = []);
    await hostShare.markers.retire();

    await guest.checkCopies();
    await settle();
    final copy = (await guestNotes.loadNote(copyId))!;
    expect(copy.strokes[0]!.map((s) => s.id), ['s2'], reason: 's1 is gone as on the owner\'s note; s2 was changed here and stays');
  });

  test('what the guest changes on the copy goes to the owner\'s inbox, once, and the owner takes it in when the app looks', () async {
    final (_, copyId) = await guestGetsCopy();
    await hostShare.markers.retire(); // the owner's app is not there
    await guest.checkCopies();
    expect(nextcloud.dropped, isEmpty, reason: 'nothing changed yet');

    await guestNotes.saveNote((await guestNotes.loadNote(copyId))!..strokes[1] = [line('s7', 90)]);
    await guest.checkCopies();
    expect(nextcloud.dropped, hasLength(1));
    await guest.checkCopies();
    expect(nextcloud.dropped, hasLength(1), reason: 'the same changes are not sent again');

    await hostNotes.saveNote((await hostNotes.loadNote(noteId))!..strokes[0]!.add(line('s8', 40)));
    await host.checkInboxes();
    final merged = (await hostNotes.loadNote(noteId))!;
    expect(merged.strokes[1]!.single.id, 's7');
    expect(merged.strokes[0]!.map((s) => s.id).toSet(), {'s1', 's8'});

    // more edits: sent again
    await guestNotes.saveNote((await guestNotes.loadNote(copyId))!..title = 'Plan (Ben)');
    await guest.checkCopies();
    expect(nextcloud.dropped, hasLength(2));
  });

  test('when the owner is there the copy joins their session by itself, with what the guest changed meanwhile, and says so', () async {
    final (_, copyId) = await guestGetsCopy();
    await guestNotes.saveNote((await guestNotes.loadNote(copyId))!..strokes[1] = [line('s7', 90)]);

    // the owner's app is running: a knock builds the session
    await settle();
    room.knocks.add({'t': 'hello', 'from': 'x'});
    await settle(60);
    expect(host.sessionFor(noteId)!.state, SessionState.live);

    await guest.checkCopies();
    await settle(100);
    expect(guest.sessionFor(copyId)!.state, SessionState.live, reason: 'the same note, now in the session');
    expect(guestNotices.map((n) => n.kind), contains(ShareNoticeKind.joinedOwner));
    expect(guestNotices.firstWhere((n) => n.kind == ShareNoticeKind.joinedOwner).who, 'Anna');
    await settle(300);
    expect((await hostNotes.loadNote(noteId))!.strokes[1]!.single.id, 's7', reason: 'what the guest did while away reached the owner');
    expect(nextcloud.dropped, isEmpty, reason: 'no need for the inbox');

    // not tried again for the same marker
    final attempts = guest.openedCopies!.of(copyId)!.triedAt;
    await guest.checkCopies();
    expect(guest.openedCopies!.of(copyId)!.triedAt, attempts);
  });

  test('when the note is on screen the person is asked instead, and a session that ended moves the baseline on', () async {
    final (_, copyId) = await guestGetsCopy();
    guest.registerEditor(copyId, EditorHooks(start: (_) async {}, merge: (_) async {}));
    await settle();
    room.knocks.add({'t': 'hello', 'from': 'x'});
    await settle(60);
    await guest.checkCopies();
    await settle(20);
    expect(guestNotices.map((n) => n.kind), [ShareNoticeKind.ownerOnline]);
    expect(guest.sessionFor(copyId), isNull, reason: 'not joined: the person decides');
  });

  test('a note made from a copy is "shared with me", with who it is from; one made by joining a session too', () async {
    final invite = await hostShare.shareCopy(noteId, from: 'Anna');
    final parsed = CopyInvite.parse(invite.toLink())!;
    final result = await guestShare.openCopy(parsed);
    expect(guest.shared.withMe, isEmpty);
    await guest.rememberCopy(result.noteId, parsed);
    expect(guest.shared.withMe, {result.noteId});
    expect(guest.shared.fromWhom(result.noteId), 'Anna');
    expect(host.shared.kindOf(noteId).isShared, isTrue, reason: 'and for the owner it is shared with others');
  });

  test('a copy that is forgotten is no longer followed', () async {
    final (_, copyId) = await guestGetsCopy();
    expect(guest.openedCopies!.copies.single.noteId, copyId);
    await guest.openedCopies!.forget(copyId);
    expect(guest.openedCopies!.copies, isEmpty);
  });
}

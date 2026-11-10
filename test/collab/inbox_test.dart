import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/cloud_share.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/inbox.dart';
import 'package:notes/collab/live_marker.dart';
import 'package:notes/collab/nextcloud_storage.dart';
import 'package:notes/collab/share_storage.dart';
import 'package:notes/collab/note_delta.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/sync/caldav_service.dart';

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

DrawingStroke line(String id, double y) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late FakeNextcloud nextcloud;
  late NoteRepository hostNotes, guestNotes;
  late NoteFileService hostFiles, guestFiles;
  late CloudShare hostShare, guestShare;
  late CollabService host;
  late CalDavService caldav;
  late String noteId;
  final notices = <ShareNotice>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('inbox_');
    nextcloud = FakeNextcloud();
    await nextcloud.start();
    final hostDb = await AppDatabase.open(path: '${root.path}/h.db');
    final guestDb = await AppDatabase.open(path: '${root.path}/g.db');
    hostNotes = NoteRepository(hostDb);
    guestNotes = NoteRepository(guestDb);
    Directory('${root.path}/hs').createSync();
    Directory('${root.path}/gs').createSync();
    hostFiles = NoteFileService(hostNotes, supportDirectory: () async => Directory('${root.path}/hs'));
    guestFiles = NoteFileService(guestNotes, supportDirectory: () async => Directory('${root.path}/gs'));
    caldav = CalDavService(SettingsRepository(hostDb), TaskRepository(hostDb), secret: _Secret());
    await caldav.save('${nextcloud.address}/remote.php/dav', 'alice', 'app-pw', taskCalendar: null, eventCalendars: {});

    final storage = NextcloudStorage(caldav);
    hostShare = CloudShare(hostFiles, [storage], markers: LiveMarkers([storage], _Secret()), download: (u) => downloadShared(u, allowInsecure: true));
    // a guest has no Nextcloud account: the storage only knows how to leave and fetch files
    guestShare = CloudShare(guestFiles, [NextcloudStorage(CalDavService(SettingsRepository(guestDb), TaskRepository(guestDb), secret: _Secret()))],
        download: (u) => downloadShared(u, allowInsecure: true));

    host = CollabService(hostNotes, builtInServer: '', supportDirectory: () async => Directory('${root.path}/hc')..createSync());
    await host.load();
    host.attachShare(hostShare, startInbox: false);
    notices.clear();
    host.notices.listen(notices.add);

    noteId = await hostNotes.createNote(title: 'Plan');
    final n = (await hostNotes.loadNote(noteId))!
      ..documentText = 'chapter one'
      ..strokes = {0: [line('s1', 10), line('s2', 50)]};
    await hostNotes.saveNote(n);
  });
  tearDown(() async {
    host.dispose();
    await nextcloud.stop();
    await root.delete(recursive: true);
  });

  /// What a guest does: opens the link (a note of their own), edits it, and sends what changed.
  Future<({String noteId, Map<String, String> baseline})> guestOpens(CopyInvite invite) async {
    final result = await guestShare.openCopy(CopyInvite.parse(invite.toLink())!);
    return (noteId: result.noteId, baseline: NoteDelta.digests((await guestNotes.loadNote(result.noteId))!));
  }

  Future<void> guestSends(CopyInvite invite, String noteId, Map<String, String> baseline, {String site = 'g1', String name = 'Ben', DateTime? at}) async {
    final note = (await guestNotes.loadNote(noteId))!;
    final message = InboxMessage(site: site, name: name, at: at ?? DateTime.now(), ops: NoteDelta.changesSince(note, baseline));
    await guestShare.dropChanges(CopyInvite.parse(invite.toLink())!, message.fileName, await message.seal(invite.key));
  }

  test('a copy has an inbox in its link, where a guest without an account can leave files and nothing more', () async {
    final invite = await hostShare.shareCopy(noteId);
    expect(invite.inbox, isNotNull);
    expect(CopyInvite.parse(invite.toLink())!.inbox, invite.inbox);
    expect(invite.inbox!.queryParameters['drop'], '1');

    final guest = await guestOpens(invite);
    final edited = (await guestNotes.loadNote(guest.noteId))!..strokes[1] = [line('s3', 99)];
    await guestNotes.saveNote(edited);
    await guestSends(invite, guest.noteId, guest.baseline);
    expect(nextcloud.dropped.single, startsWith('changes-g1-'));

    // the file is in the folder of the inbox, sealed
    final inbox = nextcloud.files.keys.where((k) => k.contains('/inbox-')).single;
    expect(String.fromCharCodes(nextcloud.files[inbox]!), isNot(contains('s3')));
  });

  test('the owner takes in what a guest changed, once, into the saved note, and is told', () async {
    final invite = await hostShare.shareCopy(noteId);
    final guest = await guestOpens(invite);
    final edited = (await guestNotes.loadNote(guest.noteId))!
      ..title = 'Plan (Ben)'
      ..strokes[0]!.removeWhere((s) => s.id == 's2')
      ..strokes[1] = [line('s3', 99)];
    await guestNotes.saveNote(edited);
    await guestSends(invite, guest.noteId, guest.baseline);

    // meanwhile the owner drew something else
    final hn = (await hostNotes.loadNote(noteId))!..strokes[0]!.add(line('s9', 200));
    await hostNotes.saveNote(hn);

    await host.checkInboxes();
    final merged = (await hostNotes.loadNote(noteId))!;
    expect(merged.title, 'Plan (Ben)');
    expect(merged.strokes[0]!.map((s) => s.id).toSet(), {'s1', 's9'}, reason: 's2 was deleted by the guest, s9 is the owner\'s');
    expect(merged.strokes[1]!.single.id, 's3');
    expect(notices.single.kind, ShareNoticeKind.merged);
    expect(notices.single.who, 'Ben');
    expect(notices.single.title, 'Plan (Ben)'.isEmpty ? '' : notices.single.title);

    // the file was taken from the inbox
    expect(nextcloud.files.keys.where((k) => k.contains('/inbox-')), isEmpty);

    // looking again takes in nothing twice
    final again = (await hostNotes.loadNote(noteId))!..title = 'Plan (Anna)';
    await hostNotes.saveNote(again);
    await host.checkInboxes();
    expect((await hostNotes.loadNote(noteId))!.title, 'Plan (Anna)');
    expect(notices, hasLength(1));
  });

  test('a guest who sends again, after more edits, only changes what is new since the last time', () async {
    final invite = await hostShare.shareCopy(noteId);
    final guest = await guestOpens(invite);
    var g = (await guestNotes.loadNote(guest.noteId))!..strokes[1] = [line('s3', 99)];
    await guestNotes.saveNote(g);
    await guestSends(invite, guest.noteId, guest.baseline, at: DateTime(2026, 5, 1, 12));
    await host.checkInboxes();

    // the owner moves the guest's stroke afterwards
    final hn = (await hostNotes.loadNote(noteId))!;
    hn.strokes[1]!.single.points
      ..clear()
      ..addAll(line('s3', 300).points);
    await hostNotes.saveNote(hn);

    // the guest edits something else and sends everything since the start again
    g = (await guestNotes.loadNote(guest.noteId))!..title = 'Renamed by Ben';
    await guestNotes.saveNote(g);
    await guestSends(invite, guest.noteId, guest.baseline, at: DateTime(2026, 5, 1, 13));
    await host.checkInboxes();

    final merged = (await hostNotes.loadNote(noteId))!;
    expect(merged.title, 'Renamed by Ben');
    expect(merged.strokes[1]!.single.points.first.dy, 300, reason: 'the owner\'s later move of s3 is not undone by the guest\'s second message');
  });

  test('of several messages from one guest the newest counts and all are removed; files nobody can open are removed too', () async {
    final invite = await hostShare.shareCopy(noteId);
    final guest = await guestOpens(invite);
    var g = (await guestNotes.loadNote(guest.noteId))!..title = 'First';
    await guestNotes.saveNote(g);
    await guestSends(invite, guest.noteId, guest.baseline, at: DateTime(2026, 5, 1, 12));
    g = (await guestNotes.loadNote(guest.noteId))!..title = 'Second';
    await guestNotes.saveNote(g);
    await guestSends(invite, guest.noteId, guest.baseline, at: DateTime(2026, 5, 1, 13));

    // a stranger with the address but not the key
    final stranger = InboxMessage(site: 'x1', name: 'Eve', at: DateTime(2026, 5, 1, 14), ops: const []);
    await guestShare.dropChanges(invite, stranger.fileName, await stranger.seal(Uint8List(32)));
    await guestShare.dropChanges(invite, 'notes.txt', Uint8List.fromList([1, 2, 3]));

    await host.checkInboxes();
    expect((await hostNotes.loadNote(noteId))!.title, 'Second');
    expect(nextcloud.files.keys.where((k) => k.contains('/inbox-')), isEmpty);
    expect(notices, hasLength(1));
  });

  test('a changes message for a copy, only opens with the key of that copy', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final message = InboxMessage(site: 'abc', name: 'Ben', at: DateTime(2026, 5, 1), ops: const []);
    final sealed = await message.seal(key);
    expect((await InboxMessage.open(key, sealed))!.name, 'Ben');
    expect(await InboxMessage.open(Uint8List(32), sealed), isNull);
    expect(String.fromCharCodes(sealed), isNot(contains('Ben')));
    expect(InboxMessage.siteOf(message.fileName), 'abc');
    expect(InboxMessage.siteOf('other.txt'), isNull);
  });
}

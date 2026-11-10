import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_nextcloud.dart';
import 'package:notes/collab/cloud_share.dart';
import 'package:notes/collab/live_marker.dart';
import 'package:notes/collab/nextcloud_storage.dart';
import 'package:notes/collab/share_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/sync/caldav_service.dart';

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the link to a copy', () {
    test('survives being written and read, with the key after the #', () {
      final invite = CopyInvite(Uri.parse('https://cloud.example.org/s/abc/download'), Uint8List.fromList(List.generate(32, (i) => i)), from: 'Anna Müller');
      final link = invite.toLink();
      expect(link, startsWith('notation://copy?'));
      expect(link.split('#').first, isNot(contains('AAECAw')), reason: 'the key is not in the part that servers see');
      final back = CopyInvite.parse('Look: $link thanks!')!;
      expect(back.url, invite.url);
      expect(back.key, invite.key);
      expect(back.from, 'Anna Müller');
    });

    test('things that are no link to a copy are refused', () {
      expect(CopyInvite.parse('hello'), isNull);
      expect(CopyInvite.parse('notation://copy?u=https%3A%2F%2Fx.org%2Fs%2Fa'), isNull, reason: 'no key');
      expect(CopyInvite.parse('notation://copy?u=https%3A%2F%2Fx.org%2Fs%2Fa#AAAA'), isNull, reason: 'a key of the wrong size');
      expect(CopyInvite.parse('notation://copy?u=file%3A%2F%2F%2Fetc%2Fpasswd#${base64Url.encode(List.filled(32, 1)).replaceAll('=', '')}'), isNull);
      expect(CopyInvite.parse('notation://join?s=wss%3A%2F%2Fx#${base64Url.encode(List.filled(32, 1)).replaceAll('=', '')}'), isNull);
    });
  });

  group('sharing through a Nextcloud', () {
    late Directory root;
    late FakeNextcloud nextcloud;
    late NoteRepository mine, theirs;
    late NoteFileService myFiles, theirFiles;
    late CalDavService caldav;
    late CloudShare mineShare, theirShare;
    late _Secret secret;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cloudshare_');
      nextcloud = FakeNextcloud();
      await nextcloud.start();
      final db1 = await AppDatabase.open(path: '${root.path}/a.db');
      final db2 = await AppDatabase.open(path: '${root.path}/b.db');
      mine = NoteRepository(db1);
      theirs = NoteRepository(db2);
      Directory('${root.path}/s1').createSync();
      Directory('${root.path}/s2').createSync();
      myFiles = NoteFileService(mine, supportDirectory: () async => Directory('${root.path}/s1'));
      theirFiles = NoteFileService(theirs, supportDirectory: () async => Directory('${root.path}/s2'));
      secret = _Secret();
      caldav = CalDavService(SettingsRepository(db1), TaskRepository(db1), secret: secret);
      Future<Uint8List> download(Uri u) => downloadShared(u, allowInsecure: true);
      mineShare = CloudShare(myFiles, [NextcloudStorage(caldav)], download: download);
      theirShare = CloudShare(theirFiles, const [], download: download);
    });
    tearDown(() async {
      await nextcloud.stop();
      await root.delete(recursive: true);
    });

    Future<void> connect({String? url}) =>
        caldav.save(url ?? '${nextcloud.address}/remote.php/dav', 'alice', 'app-pw', taskCalendar: null, eventCalendars: {});

    Future<String> note() async {
      final id = await mine.createNote(title: 'Secret thesis plan');
      final n = (await mine.loadNote(id))!
        ..documentText = 'chapter one is about turnips'
        ..strokes = {0: [DrawingStroke(color: Colors.red, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i, 20.0 + i)])]};
      await mine.saveNote(n);
      return id;
    }

    test('a copy goes up sealed, and whoever has the link opens it, with the host offline', () async {
      await connect();
      expect(mineShare.canShare, isTrue);
      final id = await note();
      final invite = await mineShare.shareCopy(id, from: 'Anna');

      // what the Nextcloud holds says nothing
      expect(nextcloud.files, hasLength(2), reason: 'the copy, and the marker next to it');
      expect(invite.marker, isNotNull);
      expect(nextcloud.pathOf(invite.url), startsWith('/Notation shared/'));
      for (final f in nextcloud.files.entries) {
        expect(utf8.decode(f.value, allowMalformed: true), isNot(contains('turnips')));
        expect(utf8.decode(f.value, allowMalformed: true), isNot(contains('thesis')));
        expect(f.key, isNot(contains('thesis')));
      }
      final days = DateTime.parse(nextcloud.lastExpire!).difference(DateTime.now()).inDays;
      expect(days, allOf(greaterThanOrEqualTo(28), lessThanOrEqualTo(30)));

      final marker = await LiveMarker.open(invite.key, nextcloud.files[nextcloud.pathOf(invite.marker!)]!);
      expect(marker!.live, isFalse);
      expect(mineShare.markers.lastError, isNull);

      // another device, with only the link
      final received = CopyInvite.parse(invite.toLink())!;
      expect(received.from, 'Anna');
      final result = await theirShare.openCopy(received);
      final copy = (await theirs.loadNote(result.noteId))!;
      expect(copy.title, 'Secret thesis plan');
      expect(copy.documentText, 'chapter one is about turnips');
      expect(copy.strokes[0]!.single.points.length, 6);
    });

    test('copies and markers left on the Nextcloud are removed again after their time', () async {
      var clock = DateTime(2026, 5, 1);
      final db = await AppDatabase.open(path: '${root.path}/c.db');
      final storage = NextcloudStorage(caldav, settings: SettingsRepository(db), now: () => clock);
      final share = CloudShare(myFiles, [storage], markers: LiveMarkers([storage], _Secret(), now: () => clock));
      await connect();
      final id = await note();
      await share.shareCopy(id);
      expect(nextcloud.files, hasLength(2));
      clock = clock.add(const Duration(days: 20));
      await share.shareCopy(id);
      expect(nextcloud.deletes, isEmpty, reason: 'not yet');
      clock = clock.add(const Duration(days: 12)); // the first pair is 32 days old
      await share.shareCopy(id);
      expect(nextcloud.deletes, hasLength(3), reason: 'the copy, its marker and its inbox');
      expect(nextcloud.files.keys.toList(), hasLength(4), reason: 'the second and the third pair: ${nextcloud.files.keys} deleted ${nextcloud.deletes}');
      share.markers.dispose();
    });

    test('a second share reuses the folder, and every copy has its own link and key', () async {
      await connect();
      final id = await note();
      final a = await mineShare.shareCopy(id);
      final b = await mineShare.shareCopy(id);
      expect(a.url, isNot(b.url));
      expect(a.key, isNot(b.key));
      expect(nextcloud.files, hasLength(4), reason: 'a copy and a marker for each');
    });

    test('the wrong key, a changed file and an expired link are told apart', () async {
      await connect();
      final invite = await mineShare.shareCopy(await note());

      final wrongKey = CopyInvite(invite.url, Uint8List.fromList(List.filled(32, 7)));
      await expectLater(theirShare.openCopy(wrongKey), throwsA(predicate((e) => '$e'.contains('cannot be opened'))));

      final path = nextcloud.pathOf(invite.url)!;
      final changed = Uint8List.fromList(nextcloud.files[path]!)..[40] ^= 1;
      nextcloud.files[path] = changed;
      await expectLater(theirShare.openCopy(invite), throwsA(predicate((e) => '$e'.contains('cannot be opened'))));

      nextcloud.files.clear();
      await expectLater(theirShare.openCopy(invite), throwsA(predicate((e) => '$e'.contains('gone'))));
    });

    test('a link to an insecure address is not followed', () async {
      final strict = CloudShare(myFiles, [NextcloudStorage(caldav)]); // as in the app
      final invite = CopyInvite(Uri.parse('http://127.0.0.1:${nextcloud.server.port}/s/x/download'), Uint8List(32));
      await expectLater(strict.openCopy(invite), throwsA(predicate((e) => '$e'.contains('secure'))));
    });

    test('without a Nextcloud, with the wrong login, or with link sharing off, the person is told', () async {
      final id = await note();
      expect(mineShare.canShare, isFalse);
      await expectLater(mineShare.shareCopy(id), throwsA(predicate((e) => '$e'.contains('Connect a Nextcloud'))));

      await connect(url: 'https://calendar.example.org/dav/');
      expect(mineShare.canShare, isFalse, reason: 'a CalDAV server that is no Nextcloud');
      await expectLater(mineShare.shareCopy(id), throwsA(predicate((e) => '$e'.contains('Connect a Nextcloud'))));

      await connect();
      nextcloud.password = 'changed';
      await expectLater(mineShare.shareCopy(id), throwsA(predicate((e) => '$e'.contains('did not accept the login'))));

      nextcloud.password = 'app-pw';
      nextcloud.linkSharing = false;
      await expectLater(mineShare.shareCopy(id), throwsA(predicate((e) => '$e'.contains('link sharing'))));
    });
  });

  group('other storage services', () {
    test('any service that stores a sealed file can be offered next to Nextcloud, and may fetch its own links', () async {
      final root = await Directory.systemTemp.createTemp('cloudshare2_');
      addTearDown(() => root.delete(recursive: true));
      final db = await AppDatabase.open(path: '${root.path}/a.db');
      Directory('${root.path}/s').createSync();
      final notes = NoteRepository(db);
      final files = NoteFileService(notes, supportDirectory: () async => Directory('${root.path}/s'));
      final drive = _MemoryStorage('Drive');
      final off = _MemoryStorage('Box', connected: false);
      final share = CloudShare(files, [off, drive]);

      expect(share.available, [drive]);
      final id = await notes.createNote(title: 'Plan');
      final invite = await share.shareCopy(id);
      expect(invite.url.host, 'storage.example');
      expect(drive.stored, hasLength(2), reason: 'the copy and its marker');

      // a link to such a service is fetched by it, not as a plain download
      final back = await share.openCopy(CopyInvite.parse(invite.toLink())!);
      expect((await notes.loadNote(back.noteId))!.title, 'Plan');

      // an unconnected one says why
      await expectLater(share.shareCopy(id, storage: off), throwsA(predicate((e) => '$e'.contains('Connect Box first'))));
    });
  });
}

class _MemoryStorage extends ShareStorage {
  _MemoryStorage(this.label, {this.connected = true});
  @override
  final String label;
  final bool connected;
  final stored = <String, Uint8List>{};
  @override
  bool get available => connected;
  @override
  Duration get keeps => const Duration(days: 7);
  @override
  Future<StoredFile> store(Uint8List sealed) async {
    final url = Uri.parse('https://storage.example/$label/${stored.length}');
    stored[url.path] = sealed;
    return StoredFile(url, url.path);
  }

  @override
  Future<void> replace(String ref, Uint8List sealed) async => stored[ref] = sealed;

  @override
  bool handles(Uri url) => url.host == 'storage.example' && url.path.startsWith('/$label/');
  @override
  Future<Uint8List> fetch(Uri url) async => stored[url.path]!;
}

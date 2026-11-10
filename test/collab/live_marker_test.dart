import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/cloud_share.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/live_marker.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/collab/share_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
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

class _Storage extends ShareStorage {
  final stored = <String, Uint8List>{};
  int replaced = 0;
  bool failing = false;
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
  Future<void> replace(String ref, Uint8List sealed) async {
    if (failing) throw StateError('offline');
    stored[ref] = sealed;
    replaced++;
  }

  @override
  bool handles(Uri url) => url.host == 'storage.example';
  @override
  Future<Uint8List> fetch(Uri url) async => stored[url.path]!;
}

class _Source extends ChangeNotifier implements LiveSource {
  final links = <String, String>{};
  @override
  String? hostedLink(String noteId) => links[noteId];
  void host(String noteId, String? link) {
    link == null ? links.remove(noteId) : links[noteId] = link;
    notifyListeners();
  }
}

bool markerKeyIsNotTheLinkKey(Uint8List key) => !listEquals(LiveMarker.markerKey(key), key);

void main() {
  setUpAll(AppDatabase.initFfi);

  final key = Uint8List.fromList(List.generate(32, (i) => i + 1));

  group('the marker', () {
    test('is sealed with the key of the copy, and says whether the owner is live and for how long that holds', () async {
      final at = DateTime(2026, 5, 1, 12);
      final sealed = await LiveMarker(live: true, at: at, link: 'notation://join?s=wss%3A%2F%2Fx#abc').seal(key);
      final back = (await LiveMarker.open(key, sealed))!;
      expect(back.live, isTrue);
      expect(back.link, 'notation://join?s=wss%3A%2F%2Fx#abc');
      expect(back.at, at);
      expect(back.isFresh(at.add(const Duration(minutes: 5))), isTrue);
      expect(back.isFresh(at.add(const Duration(minutes: 15))), isFalse, reason: 'not renewed: the owner is gone');
      expect(LiveMarker(live: false, at: at).isFresh(at), isFalse);

      expect(await LiveMarker.open(Uint8List(32), sealed), isNull, reason: 'another key');
      expect(await LiveMarker.open(key, Uint8List.fromList(List.filled(60, 3))), isNull);
      expect(String.fromCharCodes(sealed), isNot(contains('notation')));
    });

    test('is public but unreadable: nothing in it without the key of the link, and it opens with no other key or purpose', () async {
      final at = DateTime(2026, 5, 1, 12);
      const link = 'notation://join?s=wss%3A%2F%2Fsignal.example.org&n=Anna#SECRETSECRETSECRETSECRETSECRETSECRETSEC';
      final sealed = await LiveMarker(live: true, at: at, link: link).seal(key);
      final text = String.fromCharCodes(sealed);
      for (final secret in ['signal.example.org', 'Anna', 'SECRET', 'true', 'live', 'join', '2026']) {
        expect(text, isNot(contains(secret)));
      }
      // two markers with the same content are not the same bytes (a fresh nonce each time)
      expect(await LiveMarker(live: true, at: at, link: link).seal(key), isNot(sealed));
      // a changed byte does not open
      final bent = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
      expect(await LiveMarker.open(key, bent), isNull);
      // the copy's own key is not the marker's: a marker does not open as a copy, nor a copy as a marker
      expect(markerKeyIsNotTheLinkKey(key), isTrue);
      final copy = await SecureBox(key).seal(Uint8List.fromList(utf8.encode('{"live":true,"at":1,"link":"x"}')));
      expect(await LiveMarker.open(key, copy), isNull);
      expect(await SecureBox(key).open(sealed).then((_) => 'opened', onError: (_) => 'refused'), 'refused');
    });

    test('runs out by itself at the time its writer gave it, so one left behind by a crashed app stops counting', () async {
      final at = DateTime(2026, 5, 1, 12);
      final short = (await LiveMarker.open(key, await LiveMarker(live: true, at: at, link: 'notation://join?s=wss%3A%2F%2Fx#K', until: at.add(const Duration(minutes: 1))).seal(key)))!;
      expect(short.isFresh(at.add(const Duration(seconds: 30))), isTrue);
      expect(short.isFresh(at.add(const Duration(minutes: 2))), isFalse, reason: 'it said one minute');

      final plain = (await LiveMarker.open(key, await LiveMarker(live: true, at: at, link: 'notation://join?s=wss%3A%2F%2Fx#K').seal(key)))!;
      expect(plain.expires, at.add(LiveMarker.freshFor), reason: 'written with an end time of its own');
      expect(plain.isFresh(at.add(LiveMarker.freshFor + const Duration(seconds: 1))), isFalse);

      // a reader whose clock is far behind does not make it last: it is also only good for three renewals' time from when it was written
      expect(plain.isFresh(at.add(const Duration(minutes: 31))), isFalse);
    });

    test('is a part of the link, and a link without one is as before', () {
      final with_ = CopyInvite(Uri.parse('https://a.example/1'), key, marker: Uri.parse('https://a.example/2?x=1&y=2'));
      final back = CopyInvite.parse(with_.toLink())!;
      expect(back.url, with_.url);
      expect(back.marker, with_.marker);
      expect(CopyInvite.parse(CopyInvite(Uri.parse('https://a.example/1'), key).toLink())!.marker, isNull);
      expect(CopyInvite.parse('notation://copy?u=https%3A%2F%2Fa.example%2F1&m=file%3A%2F%2F%2Fx#${CopyInvite(Uri.parse('https://a.example/1'), key).toLink().split('#').last}')!.marker, isNull);
    });
  });

  group('following the sessions', () {
    late Directory root;
    late _Storage storage;
    late _Source source;
    late _Secret secret;
    late NoteRepository notes;
    late NoteFileService files;
    late CloudShare share;
    late String noteId;
    final clock = DateTime(2026, 5, 1, 12);
    var now = clock;
    const server = 'wss://signal.example';

    LiveMarkers markers({Duration beat = const Duration(minutes: 5), String? signalling = server}) => LiveMarkers([storage], secret, now: () => now, heartbeat: beat)
      ..serverOf = (() => signalling)
      ..nameOf = (() => 'Anna')
      ..watch(source);

    Future<LiveMarker> read(CopyInvite invite) async => (await LiveMarker.open(invite.key, storage.stored[invite.marker!.path]!))!;

    setUp(() async {
      now = clock;
      root = await Directory.systemTemp.createTemp('marker_');
      storage = _Storage();
      source = _Source();
      secret = _Secret();
      final db = await AppDatabase.open(path: '${root.path}/a.db');
      notes = NoteRepository(db);
      Directory('${root.path}/s').createSync();
      files = NoteFileService(notes, supportDirectory: () async => Directory('${root.path}/s'));
      share = CloudShare(files, [storage], markers: markers());
      noteId = await notes.createNote(title: 'Plan');
    });
    tearDown(() async {
      share.markers.dispose();
      await root.delete(recursive: true);
    });

    test('the marker always carries the invite to a room to meet in, so that a session can be built when someone knocks', () async {
      final invite = await share.shareCopy(noteId);
      final m = await read(invite);
      expect(m.live, isTrue, reason: 'the app is running');
      final room = SessionInvite.parse(m.link!)!;
      expect(room.server, server);
      expect(room.from, 'Anna');
      expect(share.markers.standbyFor(noteId)!.secret, room.secret);
      expect(share.markers.standbyInvites.keys, [noteId]);
      expect(share.markers.keysFor(noteId).single, invite.key);
    });

    test('all copies of a note meet in the same room, other notes in another', () async {
      final a = await share.shareCopy(noteId);
      final b = await share.shareCopy(noteId);
      expect(a.key, isNot(b.key));
      expect((await read(a)).link, (await read(b)).link);
      expect(share.markers.keysFor(noteId), hasLength(2));
      final other = await notes.createNote(title: 'Other');
      final c = await share.shareCopy(other);
      expect((await read(c)).link, isNot((await read(a)).link));
    });

    test('while a session runs the marker has its invite, and afterwards the room again', () async {
      final invite = await share.shareCopy(noteId);
      final room = (await read(invite)).link;

      source.host(noteId, 'notation://join?s=wss%3A%2F%2Fsignal.example#SESSION');
      await share.markers.settled;
      expect((await read(invite)).link, 'notation://join?s=wss%3A%2F%2Fsignal.example#SESSION');

      source.host(noteId, null);
      await share.markers.settled;
      expect((await read(invite)).link, room);
    });

    test('without a signalling server there is no room, and the marker says nobody is there', () async {
      share.markers.dispose();
      share = CloudShare(files, [storage], markers: markers(signalling: null));
      final invite = await share.shareCopy(noteId);
      expect((await read(invite)).live, isFalse);
      expect(share.markers.standbyInvites, isEmpty);
    });

    test('nothing is written again while nothing changed, and other notes are left alone', () async {
      await share.shareCopy(noteId);
      await share.markers.settled;
      final before = storage.replaced;
      source.host('some-other-note', 'notation://join?s=wss%3A%2F%2Fx#K');
      await share.markers.settled;
      expect(storage.replaced, before);
    });

    test('the marker is renewed all the time the app is there, so that one that is not renewed goes stale', () async {
      share.markers.dispose();
      share = CloudShare(files, [storage], markers: markers(beat: const Duration(milliseconds: 40)));
      final invite = await share.shareCopy(noteId);
      await share.markers.settled;
      final first = (await read(invite)).at;
      now = now.add(const Duration(minutes: 3));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await share.markers.settled;
      expect((await read(invite)).at.isAfter(first), isTrue);
    });

    test('going to the background says "not here" at once, a running session carries on, and coming back says so again', () async {
      final invite = await share.shareCopy(noteId);
      final other = await notes.createNote(title: 'Other');
      final second = await share.shareCopy(other);
      source.host(other, 'notation://join?s=wss%3A%2F%2Fsignal.example#RUNNING');
      await share.markers.settled;

      await share.markers.retire();
      expect((await read(invite)).live, isFalse);
      expect((await read(invite)).isFresh(now), isFalse);
      expect((await read(second)).link, 'notation://join?s=wss%3A%2F%2Fsignal.example#RUNNING', reason: 'its session goes on');

      // while away, changes are not written
      final writes = storage.replaced;
      source.host(noteId, null);
      await share.markers.settled;
      expect(storage.replaced, writes);

      await share.markers.resume();
      expect((await read(invite)).live, isTrue);
      expect((await read(invite)).isFresh(now), isTrue);
    });

    test('a write that failed is tried again at the next change', () async {
      final invite = await share.shareCopy(noteId);
      storage.failing = true;
      source.host(noteId, 'notation://join?s=wss%3A%2F%2Fx#K');
      await share.markers.settled;
      expect(share.markers.lastError, contains('offline'));
      storage.failing = false;
      source.host(noteId, 'notation://join?s=wss%3A%2F%2Fx#K');
      await share.markers.settled;
      expect((await read(invite)).link, 'notation://join?s=wss%3A%2F%2Fx#K');
    });

    test('the rooms and keys are remembered across starts, and forgotten when the copy has expired', () async {
      final invite = await share.shareCopy(noteId);
      final room = share.markers.standbyFor(noteId)!.toLink();
      share.markers.dispose();
      final next = markers();
      await next.load();
      expect(next.standbyFor(noteId)!.toLink(), room);
      expect(next.keysFor(noteId).single, invite.key);

      next.dispose();
      now = now.add(const Duration(days: 8));
      final later = markers();
      await later.load();
      source.host(noteId, null);
      later.publish(noteId);
      await later.settled;
      expect(later.standbyInvites, isEmpty);
      expect(later.keysFor(noteId), isEmpty);
      later.dispose();
    });

    test('whoever opens the link learns of the room, but only while the marker is fresh', () async {
      final invite = await share.shareCopy(noteId);
      final guest = CopyInvite.parse(invite.toLink())!;
      final offer = await share.liveSession(guest, now: now);
      expect(offer, isNotNull);
      expect(offer!.server, server);
      expect(offer.secret, share.markers.standbyFor(noteId)!.secret);

      final host = SessionInvite.create('wss://signal.example');
      source.host(noteId, host.toLink());
      await share.markers.settled;
      expect((await share.liveSession(guest, now: now))!.secret, host.secret, reason: 'a session that runs: its invite');

      expect(await share.liveSession(guest, now: now.add(const Duration(minutes: 20))), isNull, reason: 'stale: the app is not there');
      expect(await share.liveSession(CopyInvite(guest.url, Uint8List(32), marker: guest.marker)), isNull, reason: 'wrong key');
      expect(await share.liveSession(CopyInvite(guest.url, guest.key)), isNull, reason: 'a link without a marker');
    });
  });
}

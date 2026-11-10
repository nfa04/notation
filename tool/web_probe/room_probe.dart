// A probe of the meeting room in the browser: two devices of one profile, neither ever linked (one made the profile, the other signed
// in with its secret, as through a cloud folder), against the signalling server in $SERVER. POSTs what happened to /result.
// Build: flutter build web -t tool/web_probe/room_probe.dart --output build/probe --no-pub --no-wasm-dry-run --no-web-resources-cdn
import 'dart:io';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/live_notes.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/web/web_files.dart';

const server = String.fromEnvironment('SERVER', defaultValue: 'wss://uninotes-signaling.noel-aeby.workers.dev');

class _Profile implements SyncProfile {
  @override
  String id = 'aaaaaaaaaaaaaaaa';
  @override
  String name = 'Probe';
  @override
  Future<void> adopt(String id, String name) async {
    this.id = id;
    this.name = name;
  }
}

class _Live extends ChangeNotifier implements LiveNotes {
  final String who;
  final List<String> log;
  final sessions = <String>{};
  _Live(this.who, this.log);
  @override
  bool hasSession(String noteId) => sessions.contains(noteId);
  @override
  Set<String> get ownNotes => sessions;
  @override
  Future<bool> host(String noteId, SessionInvite invite, HostTransport transport) async {
    log.add('$who hosts $noteId');
    sessions.add(noteId);
    return true;
  }
  @override
  Future<bool> join(String noteId, SessionInvite invite, JoinTransport transport) async {
    log.add('$who JOINED $noteId');
    sessions.add(noteId);
    return true;
  }
  @override
  Future<void> end(String noteId) async => sessions.remove(noteId);
  @override
  SessionInvite? hostedInvite(String noteId) => null;
  @override
  ({bool host, int people, bool ended})? status(String noteId) => null;
  @override
  Future<void> saveNote(String noteId) async {}
  @override
  Listenable get changes => this;
  @override
  void wake() {}
  @override
  Stream<String> get editorsReady => const Stream.empty();
}

Future<DeviceSyncService> _device(String id) async {
  final db = await AppDatabase.open(path: '$id-${DateTime.now().millisecondsSinceEpoch}.db');
  final repo = NoteRepository(db);
  final settings = SettingsRepository(db);
  final files = NoteFileService(repo, supportDirectory: () async => Directory('/support/$id')..createSync(recursive: true));
  final s = DeviceSyncService(
    settings: settings,
    keys: MemorySyncKeys(),
    library: SyncLibrary(db, repo, files, settings),
    profile: _Profile(),
    serverOf: () => server,
    changes: repo.changes,
    heartbeat: const Duration(seconds: 3),
  );
  await s.load();
  return s;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  installWebFiles();
  AppDatabase.initFfi();
  try {
    final a = await _device('aaa'), b = await _device('bbb');
    await a.ensureProfile();
    await b.joinWithSecret(a.profileSecret!, 'aaaaaaaaaaaaaaaa', 'Probe');
    await a.book.merge([b.book.find(b.deviceId!)!]);
    await b.book.merge([a.book.find(a.deviceId!)!]);
    log.add('a.server=${a.server} b.server=${b.server} b.signalServer=${b.signalServer}');
    await a.setAuto(true);
    await b.setAuto(true);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (a.connected && b.connected && a.peers.any((p) => p.online) && b.peers.any((p) => p.online)) break;
    }
    log.add('a.connected=${a.connected} problem=${a.problem}; b.connected=${b.connected} problem=${b.problem}');
    log.add('a sees ${[for (final p in a.peers) '${p.name}:${p.online}']}; b sees ${[for (final p in b.peers) '${p.name}:${p.online}']}');
    // and a note that is open on both, with the automatic sync off
    final c = await _device('ccc'), d = await _device('ddd');
    await c.ensureProfile();
    await d.joinWithSecret(c.profileSecret!, 'aaaaaaaaaaaaaaaa', 'Probe');
    await c.book.merge([d.book.find(d.deviceId!)!]);
    await d.book.merge([c.book.find(c.deviceId!)!]);
    final lc = _Live('c', log), ld = _Live('d', log);
    c.live = lc;
    d.live = ld;
    c.setOpenNotes({'note1'});
    d.setOpenNotes({'note1'});
    for (var i = 0; i < 40 && !(lc.sessions.isNotEmpty && ld.sessions.isNotEmpty); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    log.add('live: c connected=${c.connected} problem=${c.problem}; d connected=${d.connected} problem=${d.problem}; sessions c=${lc.sessions} d=${ld.sessions}');
  } catch (e, s) {
    log.add('FAIL $e\n$s');
  }
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'result'.toJS, {'method': 'POST', 'body': log.join('\n')}.jsify()).toDart;
}

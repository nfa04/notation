import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_accounts.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/devicesync/sync_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestProfile implements SyncProfile {
  @override
  String id;
  @override
  String name;
  TestProfile(this.id, this.name);

  @override
  Future<void> adopt(String id, String name) async {
    this.id = id;
    this.name = name;
  }
}

/// One device with its own database, files, device list and keys.
class Device {
  final String name;
  late final Database db;
  late final NoteRepository repo;
  late final SettingsRepository settings;
  late final NoteFileService files;
  late final SyncLibrary library;
  late final DeviceIdentity identity;
  final Map<String, String> store = {};
  late final DeviceBook book = DeviceBook((k) async => store[k], (k, v) async => store[k] = v);
  final Directory dir;
  Set<String> busy = {};
  late final TestProfile profile;

  Device._(this.name, this.dir);

  static Future<Device> create(String name, Directory root, {String profileId = '0000000000000000'}) async {
    final d = Device._(name, await Directory('${root.path}/$name').create());
    d.db = await AppDatabase.open(path: '${d.dir.path}/n.db');
    d.repo = NoteRepository(d.db);
    d.settings = SettingsRepository(d.db);
    d.files = NoteFileService(d.repo, supportDirectory: () async => d.dir);
    d.library = SyncLibrary(d.db, d.repo, d.files, d.settings, busy: () => d.busy);
    d.identity = await DeviceIdentity.create(random: Random(name.hashCode));
    d.profile = TestProfile(profileId, name);
    return d;
  }

  Future<String> note(String title, String text) async {
    final id = await repo.createNote(title: title);
    final n = (await repo.loadNote(id))!;
    n.documentText = text;
    await repo.saveNote(n);
    return id;
  }

  Future<void> edit(String id, String text) async {
    final n = (await repo.loadNote(id))!;
    n.documentText = text;
    await repo.saveNote(n);
  }

  Future<String> text(String id) async => (await repo.loadNote(id))!.documentText;

  SyncSession session(PeerChannel channel, SyncSecret secret, String room, {PairingOffer? offer, PairingJoin? join, Duration step = const Duration(seconds: 5), String? liveNote, Future<Uint8List?> Function(String, String)? liveSecretFor, SyncedAccounts? accounts, bool lazyNotes = false}) => SyncSession(
        channel: channel,
        secret: secret,
        roomName: room,
        identity: identity,
        deviceName: name,
        book: book,
        profile: profile,
        library: library,
        offer: offer,
        join: join,
        step: step,
        liveNote: liveNote,
        liveSecretFor: liveSecretFor,
        accounts: accounts,
        lazyNotes: lazyNotes,
      );
}

Future<(PeerChannel, PeerChannel)> pipe() async {
  final hub = LoopbackHub();
  final host = hub.host;
  final incoming = host.incoming.first;
  final a = await hub.guest.connect();
  return (a, await incoming);
}


/// A link whose two ends can be told to see another connection than they are on (what a device in the middle causes).
class BoundChannel implements PeerChannel {
  final PeerChannel inner;
  final String seen;
  BoundChannel(this.inner, this.seen);

  @override
  Future<String> binding() async => seen;

  @override
  Stream<Uint8List> get messages => inner.messages;

  @override
  Future<void> send(Uint8List message) => inner.send(message);

  @override
  Future<void> get closed => inner.closed;

  @override
  Future<void> close() => inner.close();
}

/// A link that is cut after [after] messages were sent over it (the network drops).
class CuttingChannel implements PeerChannel {
  final PeerChannel inner;
  int after;
  CuttingChannel(this.inner, this.after);

  @override
  Future<String> binding() => inner.binding();

  @override
  Stream<Uint8List> get messages => inner.messages;

  @override
  Future<void> send(Uint8List message) async {
    if (after-- <= 0) {
      await inner.close();
      throw StateError('the link is closed');
    }
    return inner.send(message);
  }

  @override
  Future<void> get closed => inner.closed;

  @override
  Future<void> close() => inner.close();
}

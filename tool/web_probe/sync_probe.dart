// A probe of a whole sync through a cloud folder, in the browser: two devices (two databases) with ink, a PDF and a conflict. POSTs
// what happened to /result.
// Build: flutter build web -t tool/web_probe/sync_probe.dart --output build/probe --no-pub --no-wasm-dry-run --no-web-resources-cdn
import 'dart:io';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:notes/cloudsync/cloud_folder.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/pdf_note.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/web/web_files.dart';
import 'package:pdfrx/pdfrx.dart';

class _Mem implements CloudFolder {
  @override
  Future<Map<String, String>?> stamps(String dir) async => null;

  final files = <String, Uint8List>{};
  @override
  String get label => 'memory';
  @override
  Future<List<String>> list(String dir) async => [for (final k in files.keys) if (k.startsWith('$dir/') && !k.substring(dir.length + 1).contains('/')) k.substring(dir.length + 1)];
  @override
  Future<Uint8List?> read(String path) async => files[path];
  @override
  Future<void> write(String path, Uint8List bytes) async => files[path] = bytes;
  @override
  Future<void> delete(String path) async => files.remove(path);
}

class _Dev {
  final String id;
  late final NoteRepository repo;
  late final SettingsRepository settings;
  late final SyncLibrary lib;
  _Dev(this.id);

  static Future<_Dev> open(String id) async {
    final d = _Dev(id);
    final db = await AppDatabase.open(path: '$id-${DateTime.now().millisecondsSinceEpoch}.db');
    d.repo = NoteRepository(db);
    d.settings = SettingsRepository(db);
    final files = NoteFileService(d.repo, supportDirectory: () async => Directory('/support/$id')..createSync(recursive: true));
    d.lib = SyncLibrary(db, d.repo, files, d.settings);
    return d;
  }

  FolderSync sync(_Mem folder, Uint8List key, String other) =>
      FolderSync(folder: folder, library: lib, peers: [SyncPeer(other, other)], settings: settings, deviceId: id, deviceName: id, key: key, encrypted: true);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  Future<T?> step<T>(String name, Future<T> Function() f) async {
    try {
      final v = await f();
      log.add('ok   $name: $v');
      return v;
    } catch (e, s) {
      log.add('FAIL $name: $e\n${s.toString().split('\n').take(10).join('\n')}');
      return null;
    }
  }

  installWebFiles();
  await pdfrxFlutterInitialize();
  AppDatabase.initFfi();
  final cloud = _Mem();
  final rnd = Random(3);
  final key = Uint8List.fromList([for (var i = 0; i < 32; i++) rnd.nextInt(256)]);
  final a = await _Dev.open('aaa'), b = await _Dev.open('bbb');

  Future<void> run(String name, _Dev d, _Dev other) async {
    await step(name, () async {
      final r = await d.sync(cloud, key, other.id).run();
      return 'took ${r.taken} put ${r.put} problems ${r.problems}';
    });
  }

  final text = await step('a: make notes', () async {
    final ids = <String>[];
    final n1 = await a.repo.createNote(title: 'Ink');
    final note = (await a.repo.loadNote(n1))!;
    note.documentText = 'hello';
    note.strokes[0] = [for (var i = 0; i < 3; i++) DrawingStroke(color: const Color(0xFF112233), width: 2.5, points: [Offset(1.0 + i, 1), const Offset(5, 5), const Offset(9, 3)])];
    await a.repo.saveNote(note);
    ids.add(n1);
    final response = await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'probe.pdf'.toJS).toDart;
    final data = (await response.callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS).toDart).toDart.asUint8List();
    Directory('/support/in').createSync(recursive: true);
    File('/support/in/probe.pdf').writeAsBytesSync(data);
    ids.add(await createNoteFromPdf(a.repo, '/support/in/probe.pdf', directory: Directory('/support/aaa/pdfs')));
    return ids;
  });
  await run('a publishes', a, b);
  await run('b pulls and publishes', b, a);
  await step('b edits both notes', () async {
    for (final id in text!) {
      final n = (await b.repo.loadNote(id))!;
      n.documentText = '${n.documentText} from b';
      await b.repo.saveNote(n);
    }
    return 'edited';
  });
  await run('b publishes', b, a);
  await step('a edits both notes (conflict)', () async {
    for (final id in text!) {
      final n = (await a.repo.loadNote(id))!;
      n.documentText = '${n.documentText} from a';
      await a.repo.saveNote(n);
    }
    return 'edited';
  });
  await run('a pulls and publishes', a, b);
  await run('b pulls', b, a);
  log.add('OK');
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'result'.toJS, {'method': 'POST', 'body': log.join('\n')}.jsify()).toDart;
}

// A probe of the library a cloud-folder sync works on, in the browser: makes a note with ink, writes it out like a publish and takes it
// in like a pull. POSTs what happened to /result.
// Build: flutter build web -t tool/web_probe/db_probe.dart --output build/probe --no-pub --no-wasm-dry-run --no-web-resources-cdn
import 'dart:io';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/automations/note_sorter.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/pdf_note.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/web/web_files.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  Future<T?> step<T>(String name, Future<T> Function() f) async {
    try {
      final v = await f();
      log.add('ok   $name: $v');
      return v;
    } catch (e, s) {
      log.add('FAIL $name: $e\n${s.toString().split('\n').take(8).join('\n')}');
      return null;
    }
  }

  installWebFiles();
  await pdfrxFlutterInitialize();
  AppDatabase.initFfi();
  final db = await AppDatabase.open(path: 'probe-${DateTime.now().millisecondsSinceEpoch}.db');
  final repo = NoteRepository(db), settings = SettingsRepository(db);
  final files = NoteFileService(repo, supportDirectory: () async => Directory('/support')..createSync(recursive: true));
  final lib = SyncLibrary(db, repo, files, settings);
  final id = await step('create', () async {
    final id = await repo.createNote(title: 'Probe');
    final n = (await repo.loadNote(id))!;
    n.documentText = 'hello';
    await repo.saveNote(n);
    return id;
  });
  await step('save with ink', () async {
    final n = (await repo.loadNote(id!))!;
    n.strokes[0] = [for (var i = 0; i < 3; i++) DrawingStroke(color: const Color(0xFF112233), width: 2.5, points: [Offset(1.0 + i, 1), const Offset(5, 5), const Offset(9, 3)])];
    await repo.saveNote(n);
    final m = (await repo.loadNote(id))!;
    m.strokes[0]!.first.width = 4;
    await repo.saveNote(m);
    return (await repo.loadNote(id))!.strokes[0]!.length;
  });
  final bytes = await step('noteBytes', () async => (await lib.noteBytes(id!))?.length);
  final manifest = await step('manifest', () async => (await lib.manifest()).notes.length);
  final raw = await lib.noteBytes(id!);
  final info = (await lib.manifest()).notes.first;
  await step('applyNote same id', () async {
    await lib.applyNote('peer', SyncNote(info.id, info.version + 5, info.created, null, false, null), raw, data: true, meta: true);
    return 'applied';
  });
  await step('applyNote new id', () async {
    await lib.applyNote('peer', SyncNote('zzznew-1', 1700000000000, 1700000000000, null, false, null), raw, data: true, meta: true);
    return (await lib.manifest()).notes.length;
  });
  String? pid;
  await step('pdf note: import', () async {
    final response = await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'probe.pdf'.toJS).toDart;
    final data = (await response.callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS).toDart).toDart.asUint8List();
    Directory('/support/in').createSync(recursive: true);
    File('/support/in/probe.pdf').writeAsBytesSync(data);
    pid = await createNoteFromPdf(repo, '/support/in/probe.pdf', directory: Directory('/support/pdfs'));
    return pid;
  });
  Uint8List? pbytes;
  await step('pdf note: noteBytes', () async {
    pbytes = await lib.noteBytes(pid!);
    return pbytes?.length;
  });
  await step('pdf note: manifest', () async => (await lib.manifest()).notes.length);
  await step('pdf note: apply as new', () async {
    await lib.applyNote('peer', SyncNote('pdfnew-1', 1700000000000, 1700000000000, null, false, null), pbytes, data: true, meta: true);
    return (await lib.manifest()).notes.length;
  });
  for (final name in ['ink', 'pdf']) {
    Uint8List? native;
    await step('native $name: fetch', () async {
      final response = await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, '$name.uninote'.toJS).toDart;
      native = (await response.callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS).toDart).toDart.asUint8List();
      return native!.length;
    });
    await step('native $name: decode', () async => decodeNoteFile(native!).note.title);
    await step('native $name: digest', () async => noteContentDigest(native!));
    await step('native $name: apply as new', () async {
      await lib.applyNote('peer', SyncNote('native-$name', 1700000000000, 1700000000000, null, false, null), native, data: true, meta: true);
      return 'applied';
    });
    await step('native $name: noteBytes after', () async => (await lib.noteBytes('native-$name'))?.length);
    await step('native $name: apply again newer', () async {
      await lib.applyNote('peer', SyncNote('native-$name', 1700000009999, 1700000000000, null, false, null), native, data: true, meta: true);
      return 'applied';
    });
  }
  await step('ai row with a 63-bit hash: raw cast', () async {
    final hash = NoteSorter.hashOf('some text of a note, long enough to be filed');
    await repo.ai.put(NoteAiRow(noteId: id, kind: 'summary', content: 'x', sourceHash: hash, model: 'm', createdAt: DateTime.now()));
    final raw = (await db.query('note_ai', where: 'note_id = ?', whereArgs: [id])).single['source_hash'];
    return 'hash $hash, read back as ${raw.runtimeType} ${raw is int}';
  });
  await step('ai row: repository read', () async => (await repo.ai.of(id)).map((r) => r.sourceHash).toList());
  await step('ai row: noteBytes with it', () async => (await lib.noteBytes(id))?.length);
  log.add('OK ($bytes, $manifest)');
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'result'.toJS, {'method': 'POST', 'body': log.join('\n')}.jsify()).toDart;
}

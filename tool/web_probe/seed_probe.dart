// Seeds the browser's storage like the app does: a PDF note and a plain note in the app's own database and files, so that the real
// app opened afterwards (same origin) has something on its dashboard. POSTs what happened to /result.
// Build: flutter build web -t tool/web_probe/seed_probe.dart --output build/seed --base-href /seed/ --no-pub --no-wasm-dry-run --no-web-resources-cdn
import 'dart:io';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/pdf_note.dart';
import 'package:notes/web/web_files.dart';
import 'package:pdfrx/pdfrx.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  try {
    installWebFiles();
    await pdfrxFlutterInitialize();
    AppDatabase.initFfi();
    final db = await AppDatabase.open();
    await keepWebFiles(db);
    final repo = NoteRepository(db);
    final response = await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, '/probe.pdf'.toJS).toDart;
    final data = (await response.callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS).toDart).toDart.asUint8List();
    Directory('/support/in').createSync(recursive: true);
    File('/support/in/probe.pdf').writeAsBytesSync(data);
    final id = await createNoteFromPdf(repo, '/support/in/probe.pdf', directory: Directory('/support/pdfs'));
    log.add('pdf note $id');
    await repo.createNote(title: 'Plain');
    await Future<void>.delayed(const Duration(seconds: 6)); // (the files are kept in the browser every 2 s)
    log.add('OK');
  } catch (e, s) {
    log.add('FAILED: $e\n$s');
  }
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, '/result'.toJS, {'method': 'POST', 'body': log.join('\n')}.jsify()).toDart;
}

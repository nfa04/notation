// A probe of the dashboard previews in the browser: imports /probe.pdf as a note, asks NotePreviews for its picture and POSTs
// what happened (and the picture, base64) to /result.
// Build: flutter build web -t tool/web_probe/preview_probe.dart --output build/probe --no-pub --no-wasm-dry-run --no-web-resources-cdn
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/pdf_note.dart';
import 'package:notes/previews/note_preview.dart';
import 'package:notes/web/web_files.dart';
import 'package:pdfrx/pdfrx.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  String? png;
  try {
    installWebFiles();
    await pdfrxFlutterInitialize();
    AppDatabase.initFfi();
    final db = await AppDatabase.open(path: 'probe-${DateTime.now().millisecondsSinceEpoch}.db');
    final repo = NoteRepository(db);
    final response = await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'probe.pdf'.toJS).toDart;
    final data = (await response.callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS).toDart).toDart.asUint8List();
    Directory('/support/in').createSync(recursive: true);
    File('/support/in/probe.pdf').writeAsBytesSync(data);
    final id = await createNoteFromPdf(repo, '/support/in/probe.pdf', directory: Directory('/support/pdfs'));
    final note = (await repo.loadNote(id))!;
    log.add('note pdfPath=${note.pdfPath} exists=${note.pdfPath == null ? null : File(note.pdfPath!).existsSync()}');
    final previews = NotePreviews(repo);
    final file = await previews.of(id, DateTime.now()).timeout(const Duration(seconds: 30));
    log.add('preview: ${file?.path} ${file?.lengthSync()}');
    if (file != null) png = base64Encode(file.readAsBytesSync());
    log.add('OK');
  } catch (e, s) {
    log.add('FAILED: $e\n$s');
  }
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'result'.toJS, {'method': 'POST', 'body': '${log.join('\n')}\nPNG:${png ?? ''}'}.jsify()).toDart;
}

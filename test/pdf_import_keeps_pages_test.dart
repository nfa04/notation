import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_file_picker.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

DrawingStroke _stroke() => DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 20; i++) Offset(100.0 + i * 5, 300.0 + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('importing a PDF into a note with written pages adds its pages after them', skip: !pdfium.existsSync(), timeout: const Timeout(Duration(minutes: 3)), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    late String pdf;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pk_');
      final doc = pw.Document();
      for (final t in ['p1', 'p2']) {
        doc.addPage(pw.Page(build: (_) => pw.Text(t)));
      }
      pdf = (File('${dir.path}/in.pdf')..writeAsBytesSync(await doc.save())).path;
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [_stroke()];
      note.strokes[1] = [_stroke(), _stroke()];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = _Paths(dir.path);
    FilePickerPlatform.instance = FakeFilePicker(pick: [pdf]);

    Future<void> settle([int rounds = 30]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await settle();
    await tester.tap(find.byTooltip('Import PDF'));
    await settle(50);
    await tester.pump(const Duration(seconds: 1));
    final saved = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return (await repo.loadNote(id))!;
    }))!;
    expect({for (final e in saved.strokes.entries) if (e.value.isNotEmpty) e.key: e.value.length}, {0: 1, 1: 2});
    expect(saved.pdfs!.layout.join(' '), 'blank blank 0:0 0:1');
  });
}

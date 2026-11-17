import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:crypto/crypto.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_file_picker.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

DrawingStroke _stroke() => DrawingStroke(
  color: Colors.black,
  width: 3,
  points: [for (var i = 0; i < 20; i++) Offset(100.0 + i * 5, 300.0 + i)],
);

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('a note can hold several PDFs as files of their own, with their pages in any order', skip: !pdfium.existsSync(), timeout: const Timeout(Duration(minutes: 4)), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    late List<String> extra;
    late String shaOfA;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pa_');
      Future<String> make(String name, List<String> words) async {
        final doc = pw.Document();
        for (final text in words) {
          doc.addPage(pw.Page(build: (_) => pw.Text(text)));
        }
        return (File('${dir.path}/$name.pdf')..writeAsBytesSync(await doc.save())).path;
      }

      final main = await make('a', ['one', 'two']);
      shaOfA = sha256.convert(File(main).readAsBytesSync()).toString();
      extra = [await make('b', ['b1', 'b2']), await make('c', ['c1'])];
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = main;
      note.pdfSha256 = shaOfA;
      note.pdfPageCount = 2;
      note.strokes[1] = [_stroke(), _stroke()];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = _Paths(dir.path);
    FilePickerPlatform.instance = FakeFilePicker(pick: extra);

    Future<void> settle([int rounds = 25]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // (what the note holds: its files, the page each page is, the strokes by page)
    Future<String> saved() async {
      await tester.pump(const Duration(seconds: 1));
      return (await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final n = (await repo.loadNote(id))!;
        final strokes = {for (final e in n.strokes.entries) if (e.value.isNotEmpty) e.key: e.value.length};
        final t = n.pdfs;
        if (t == null) return 'one file ${n.pdfName}, ${n.pdfPageCount} pages, strokes $strokes';
        return '${[for (final f in t.files) f.name]} ${t.layout.join(' ')}, strokes $strokes';
      }))!;
    }

    Future<void> choose(String item) async {
      await tester.tap(find.byKey(const ValueKey('pages-menu')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text(item));
      await settle();
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await settle(40);
    expect(await saved(), 'one file a.pdf, 2 pages, strokes {1: 2}');

    // after the first page: b and c come in as files of their own, the drawings of the second page stay with it
    await tester.tap(find.byKey(const ValueKey('pages-menu')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('insert-pdf-after')));
    await settle(40);
    expect(await saved(), '[a.pdf, b.pdf, c.pdf] 0:0 1:0 1:1 2:0 0:1, strokes {4: 2}');
    expect(find.byKey(const ValueKey('pdf-files-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-file-label-1')), findsOneWidget, reason: 'b starts on page 2');

    // the files themselves are as they were
    final files = (await tester.runAsync(() async => (await repo.loadNote(id))!.pdfs!.files))!;
    expect(sha256.convert(File(files[0].path).readAsBytesSync()).toString(), shaOfA);
    expect(files[1].pages, 2);

    // a page moves past the pages of another file (the view is on the first page, a's)
    await choose('Move page down');
    await choose('Move page down');
    expect(await saved(), '[a.pdf, b.pdf, c.pdf] 1:0 1:1 0:0 2:0 0:1, strokes {4: 2}');

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle();
    expect(await saved(), '[a.pdf, b.pdf, c.pdf] 1:0 0:0 1:1 2:0 0:1, strokes {4: 2}');
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle();
    expect(await saved(), '[a.pdf, b.pdf, c.pdf] 0:0 1:0 1:1 2:0 0:1, strokes {4: 2}');

    // the page in view is deleted: it is only hidden, its file is not changed
    await choose('Delete page');
    expect(await saved(), '[a.pdf, b.pdf, c.pdf] 0:0 1:0 2:0 0:1, strokes {3: 2}');
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle();

    // taking a file out takes its pages and what is on them
    await tester.tap(find.byKey(const ValueKey('pdf-files-menu')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('remove-pdf-1')));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('remove-pdf-confirm')));
    await settle();
    expect(await saved(), '[a.pdf, c.pdf] 0:0 1:0 0:1, strokes {2: 2}');

    // everything back, to the one file it was
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle();
    expect(await saved(), 'one file a.pdf, 2 pages, strokes {1: 2}');
  });
}

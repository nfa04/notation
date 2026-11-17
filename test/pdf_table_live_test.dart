import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_pdfs.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import 'pdf_words.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('a note with several PDFs in a live session: the order of pages and the files go both ways', skip: !pdfium.existsSync(), timeout: const Timeout(Duration(minutes: 3)), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo, guestRepo;
    late CollabService service, guestService;
    late String id;
    late Directory dir;
    late NotePdfs table;
    final hub = LoopbackHub();
    Future<Uint8List> make(List<String> words) async {
      final doc = pw.Document();
      for (final w in words) {
        doc.addPage(pw.Page(build: (_) => pw.Text(w)));
      }
      return await doc.save();
    }

    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('ptl_');
      NotePdf file(String name, List<int> bytes, int pages) {
        final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
        return NotePdf(name: name, path: f.path, sha256: sha256.convert(bytes).toString(), pages: pages);
      }

      table = NotePdfs([file('a.pdf', await make(['a1', 'a2']), 2), file('b.pdf', await make(['b1']), 1)], const [PdfPageRef(0, 0), PdfPageRef(1, 0), PdfPageRef(0, 1)]);
      repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/a.db'));
      guestRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/b.db'));
      service = CollabService(repo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/a')..createSync());
      guestService = CollabService(guestRepo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/b')..createSync());
      await service.load();
      await guestService.load();
      await service.setServer('ws://localhost:8787');
      await service.setName('Anna');
      await guestService.setName('Ben');
      id = await repo.createNote(title: 'Readings');
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = table.files.first.path;
      note.pdfSha256 = table.files.first.sha256;
      note.pdfPageCount = 3;
      note.pdfs = table;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));

    Future<void> settle([int rounds = 20]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<String> layoutOf(NoteRepository r, String noteId) async {
      await tester.pump(const Duration(seconds: 1));
      return (await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final n = (await r.loadNote(noteId))!;
        final t = n.pdfs;
        return t == null ? 'one file ${n.pdfName}' : '${[for (final f in t.files) f.name]} ${t.layout.join(' ')}';
      }))!;
    }

    // the host session is there, a guest is let in: it has the same files and pages
    late JoinAttempt attempt;
    await tester.runAsync(() async {
      final session = (await service.hostWithoutScreen(id))!;
      attempt = guestService.join(service.inviteFor(id)!);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await session.approve(service.requests.single.request.id);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    expect(await layoutOf(guestRepo, attempt.noteId!), '[a.pdf, b.pdf] 0:0 1:0 0:1');

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, collab: service)));
    await settle(30);

    // the guest orders the pages another way: the editor shows them so and keeps them so
    attempt.session!.announceLayout(const PdfLayoutChange([PdfPageRef(1, 0), PdfPageRef(0, 1), PdfPageRef(0, 0)], [2, 1]));
    await settle();
    expect(await layoutOf(repo, id), '[a.pdf, b.pdf] 1:0 0:1 0:0');

    // the editor moves a page: the guest's copy has the order
    await tester.tap(find.byKey(const ValueKey('pages-menu')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Move page down'));
    await settle();
    expect(await layoutOf(repo, id), '[a.pdf, b.pdf] 0:1 1:0 0:0');
    expect(await layoutOf(guestRepo, attempt.noteId!), '[a.pdf, b.pdf] 0:1 1:0 0:0');

    // the guest sends one PDF in place of them: the editor has that one file
    attempt.session!.announcePdf(SharedPdf('c.pdf', '', 2, Uint8List.fromList(await tester.runAsync(() => make(['c1', 'c2'])) as List<int>)));
    await settle(30);
    expect(await layoutOf(repo, id), startsWith('one file'));
    expect(find.byKey(const ValueKey('pdf-files-menu')), findsNothing);

    // and several again, from the guest
    attempt.session!.announcePdf(SharedPdf('a.pdf', '', 2, await tester.runAsync(() => File(table.files[0].path).readAsBytes()) as Uint8List,
        more: [SharedPdf('b.pdf', '', 1, await tester.runAsync(() => File(table.files[1].path).readAsBytes()) as Uint8List)], layout: const [PdfPageRef(1, 0), PdfPageRef(0, 0), PdfPageRef(0, 1)]));
    await settle(30);
    expect(await layoutOf(repo, id), '[a.pdf, b.pdf] 1:0 0:0 0:1');
    expect(find.byKey(const ValueKey('pdf-files-menu')), findsOneWidget);

    // the editor changes a line of the text of the first page (b1): the guest's copy has the file with the new text
    CustomPaint? layer() {
      for (final p in find.byType(CustomPaint).evaluate()) {
        final w = p.widget as CustomPaint;
        if (w.painter.runtimeType.toString() == '_PdfEditPainter') return w;
      }
      return null;
    }

    List<PdfEditObject> objects() => ((layer()?.painter as dynamic)?.objects as List<PdfEditObject>?) ?? const [];
    await tester.tap(find.text('Document'));
    for (var i = 0; i < 80 && objects().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(objects().single.text, 'b1');
    await tester.ensureVisible(find.byKey(const ValueKey('page-0')));
    await tester.pump(const Duration(milliseconds: 500));
    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(page.topLeft + objects().single.rect.center * (page.width / 595.28));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Edit text'));
    await settle(10);
    await tester.enterText(find.widgetWithText(TextField, 'b1'), 'charlie');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(40);
    final guestNote = (await tester.runAsync(() async => (await guestRepo.loadNote(attempt.noteId!))!))!;
    final guestB = (await tester.runAsync(() => File(guestNote.pdfs!.files[1].path).readAsBytes()))!;
    final reader = await tester.runAsync(() => PdfContentEditor.open(guestB, modulePath: pdfium.absolute.path));
    addTearDown(reader!.close);
    expect((await tester.runAsync(() => reader.objects(0)))!.map((o) => o.text), ['charlie']);
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_pdfs.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

  for (final importHere in [true, false]) {
    testWidgets(importHere ? 'a PDF imported into a note with written pages reaches the others in the session' : 'a PDF sent into a note with written pages comes after them', skip: !pdfium.existsSync(), timeout: const Timeout(Duration(minutes: 3)), (tester) async {
      Pdfrx.pdfiumModulePath = pdfium.absolute.path;
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late NoteRepository repo, guestRepo;
      late CollabService service, guestService;
      late String id, pdf;
      late Uint8List bytes;
      late Directory dir;
      final hub = LoopbackHub();
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('pil_');
        final doc = pw.Document();
        for (final t in ['p1', 'p2']) {
          doc.addPage(pw.Page(build: (_) => pw.Text(t)));
        }
        bytes = await doc.save();
        pdf = (File('${dir.path}/in.pdf')..writeAsBytesSync(bytes)).path;
        repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/a.db'));
        guestRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/b.db'));
        service = CollabService(repo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/a')..createSync());
        guestService = CollabService(guestRepo, builtInServer: '', hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/b')..createSync());
        await service.load();
        await guestService.load();
        await service.setServer('ws://localhost:8787');
        await service.setName('Anna');
        await guestService.setName('Ben');
        id = await repo.createNote(title: 'Notes');
        final note = (await repo.loadNote(id))!;
        note.strokes[0] = [_stroke()];
        note.strokes[1] = [_stroke()];
        await repo.saveNote(note);
      });
      addTearDown(() => dir.delete(recursive: true));
      PathProviderPlatform.instance = _Paths(dir.path);
      FilePickerPlatform.instance = FakeFilePicker(pick: [pdf]);

      Future<void> settle([int rounds = 20]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      late JoinAttempt attempt;
      await tester.runAsync(() async {
        final session = (await service.hostWithoutScreen(id))!;
        attempt = guestService.join(service.inviteFor(id)!);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await session.approve(service.requests.single.request.id);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, collab: service)));
      await settle(30);

      if (importHere) {
        await tester.tap(find.text('Import PDF'));
        await settle(50);
      } else {
        final sha = sha256.convert(bytes).toString();
        attempt.session!.announcePdf(SharedPdf('in.pdf', sha, 2, bytes, layout: const [PdfPageRef.blank(), PdfPageRef.blank(), PdfPageRef(0, 0), PdfPageRef(0, 1)]));
        await settle(40);
      }
      await tester.pump(const Duration(seconds: 1));
      Future<String> shown(NoteRepository r, String noteId) async => (await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            final n = (await r.loadNote(noteId))!;
            return '${n.pdfs?.layout.join(' ')} ${n.strokes.entries.where((e) => e.value.isNotEmpty).map((e) => e.key).toList()}';
          }))!;
      expect(await shown(repo, id), 'blank blank 0:0 0:1 [0, 1]');
      if (importHere) expect(await shown(guestRepo, attempt.noteId!), startsWith('blank blank 0:0 0:1'));
    });
  }
}

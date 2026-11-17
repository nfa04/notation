import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_pdfs.dart';
import 'package:notes/collab/shared_pdf_files.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke line(double y) => DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

Future<void> settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late LoopbackHub hub;
  late NoteRepository hostRepo, guestRepo;
  late CollabService hostService, guestService;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('collab_service_');
    hub = LoopbackHub();
    hostRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/host.db'));
    guestRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/guest.db'));
    hostService = CollabService(hostRepo, builtInServer: '',
        hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/h')..createSync());
    guestService = CollabService(guestRepo, builtInServer: '',
        hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/g')..createSync());
    await hostService.load();
    await guestService.load();
    await hostService.setServer('ws://localhost:8787');
    await hostService.setName('Anna');
    await guestService.setName('Ben');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CollabBinding bindingFor(NoteData note, void Function() onChange) => CollabBinding(
        note: () => note,
        change: (f) {
          f();
          onChange();
        },
        makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
        saveImage: hostService.saveImage,
        onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
      );

  test('a picture of a peer is saved inside the images folder whatever extension it names', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final images = p.join(dir.path, 'h', 'images');
    for (final ext in ['png', '/../../escape', '..\\..\\escape', 'png/../x', '', 'toolongextension']) {
      final path = hostService.saveImage('pic/../1', bytes, ext);
      expect(p.dirname(path), images, reason: ext);
      expect(File(path).readAsBytesSync(), bytes);
    }
    expect(hostService.saveImage('a', bytes, 'JPG'), endsWith('live_a.jpg'));
    expect(File(p.join(dir.path, 'escape')).existsSync(), isFalse);
  });

  test('the settings are kept, and a server given without a scheme is made secure', () async {
    expect(hostService.server, 'ws://localhost:8787');
    await hostService.setServer('signal.example.org/live');
    expect(hostService.server, 'wss://signal.example.org/live');
    await hostService.setServer('');
    expect(hostService.server, isNull);
    final again = CollabService(hostRepo, builtInServer: '', supportDirectory: () async => Directory('${dir.path}/h'));
    await again.load();
    expect((again.server, again.nameSetting), (null, 'Anna'));
    await hostService.setServer('ws://a:1');
    await again.load();
    expect(again.server, 'ws://a:1');
  });

  test('hosting without a server says what is missing', () async {
    await hostService.setServer(null);
    final note = NoteData(id: 'x');
    await expectLater(hostService.startHosting('x', bindingFor(note, () {})), throwsA(predicate((e) => '$e'.contains('signalling server'))));
  });

  test('from an invite to a note on the other device, and live changes both ways', () async {
    final hostNote = NoteData(id: 'h', title: 'Study group')..strokes[0] = [line(10)];
    final hostId = await hostRepo.createNote(title: 'Study group');
    final session = await hostService.startHosting(hostId, bindingFor(hostNote, () {}), title: 'Study group');
    final invite = hostService.inviteFor(hostId)!;
    expect(SessionInvite.parse(invite.toLink())!.from, 'Anna');

    final attempt = guestService.join(invite);
    await settle();
    expect(hostService.requests.single.request.name, 'Ben');
    expect(hostService.requests.single.noteTitle, 'Study group');
    expect(attempt.session!.verificationCode, hostService.requests.single.request.code);
    await session.approve(hostService.requests.single.request.id);
    await settle();

    expect(attempt.noteId, isNotNull);
    final made = (await guestRepo.loadNote(attempt.noteId!))!; // a note of its own on the other device
    expect(made.title, 'Study group');
    expect(made.strokes[0]!.single.id, hostNote.strokes[0]!.single.id);
    expect(guestService.sessionFor(attempt.noteId!), same(attempt.session));

    // the editor opens it and takes the session over
    var redraws = 0;
    attempt.session!.attach(bindingFor(made, () => redraws++));
    hostNote.strokes[0]!.add(line(60));
    session.localChanged();
    await settle();
    expect(made.strokes[0]!.length, 2);
    expect(redraws, greaterThan(0));
    made.title = 'Renamed by Ben';
    attempt.session!.localChanged();
    await settle();
    expect(hostNote.title, 'Renamed by Ben');

    await hostService.end(hostId);
    await settle();
    expect(attempt.session!.state, SessionState.ended);
  });

  test('a note with several PDFs is made on the other device with the same files and order of pages, and follows what the host does to them', () async {
    final hostId = await hostRepo.createNote(title: 'Readings');
    final files = <NotePdf>[];
    for (final (name, text) in [('a.pdf', 'a one'), ('b.pdf', 'b two')]) {
      final path = p.join(dir.path, name);
      File(path).writeAsBytesSync(Uint8List.fromList('%PDF-1.4 $text'.codeUnits));
      files.add(NotePdf(name: name, path: path, sha256: '', pages: 2));
    }
    final table = NotePdfs(files, const [PdfPageRef(1, 0), PdfPageRef(0, 0), PdfPageRef(0, 1), PdfPageRef(1, 1)]);
    final hostNote = NoteData(id: 'h', title: 'Readings');
    final binding = CollabBinding(
      note: () => hostNote,
      change: (f) => f(),
      makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
      saveImage: hostService.saveImage,
      onNoteField: (f, d) => Replica.applyNoteField(hostNote, f, d),
      pdf: () => sharedPdfOfTable(table),
    );
    final session = await hostService.startHosting(hostId, binding, title: 'Readings');
    final attempt = guestService.join(hostService.inviteFor(hostId)!);
    await settle();
    await session.approve(hostService.requests.single.request.id);
    await settle();

    final made = (await guestRepo.loadNote(attempt.noteId!))!;
    final got = made.pdfs!;
    expect(got.layout.join(' '), '1:0 0:0 0:1 1:1');
    expect(got.files.map((f) => f.name), ['a.pdf', 'b.pdf']);
    expect(got.files.map((f) => File(f.path).readAsStringSync()), ['%PDF-1.4 a one', '%PDF-1.4 b two']);
    expect(got.files.every((f) => f.path.startsWith(p.join(dir.path, 'g'))), isTrue);
    expect((made.pdfName, made.pdfPageCount, made.pdfPath), ('a.pdf', 4, got.files.first.path));

    // the host puts the pages in another order: the other device has the same files in that order
    session.announceLayout(PdfLayoutChange(const [PdfPageRef(0, 0), PdfPageRef(0, 1), PdfPageRef(1, 0)], const [2, 2]));
    await settle();
    final moved = (await guestRepo.loadNote(attempt.noteId!))!;
    expect(moved.pdfs!.layout.join(' '), '0:0 0:1 1:0');
    expect(moved.pdfs!.files.map((f) => f.path), got.files.map((f) => f.path));
    expect(moved.pdfPageCount, 3);

    // then it is one PDF again: the files of the other device are one, the others are gone
    session.announcePdf(SharedPdf('c.pdf', '', 2, Uint8List.fromList('%PDF-1.4 c three'.codeUnits)));
    await settle();
    final one = (await guestRepo.loadNote(attempt.noteId!))!;
    expect(one.pdfs, isNull);
    expect(File(one.pdfPath!).readAsStringSync(), '%PDF-1.4 c three');
    expect(File(got.files[1].path).existsSync(), isFalse);

    // and several again
    session.announcePdf(await sharedPdfOfTable(table));
    await settle();
    final again = (await guestRepo.loadNote(attempt.noteId!))!;
    expect(again.pdfs!.layout.join(' '), '1:0 0:0 0:1 1:1');
    expect(again.pdfs!.files.map((f) => File(f.path).readAsStringSync()), ['%PDF-1.4 a one', '%PDF-1.4 b two']);
  });

  test('a refused join says so, and no note is made', () async {
    final hostNote = NoteData(id: 'h');
    final hostId = await hostRepo.createNote(title: 'Private');
    final session = await hostService.startHosting(hostId, bindingFor(hostNote, () {}));
    final attempt = guestService.join(hostService.inviteFor(hostId)!);
    await settle();
    await session.deny(hostService.requests.single.request.id);
    await settle();
    expect(attempt.error, contains('did not accept'));
    expect(attempt.noteId, isNull);
    expect(await guestRepo.listNotes(), isEmpty);
  });

  test('joining where nobody hosts reports it', () async {
    final attempt = guestService.join(SessionInvite.create('ws://localhost:8787'));
    await settle();
    expect(attempt.error, contains('nobody is hosting'));
  });
}

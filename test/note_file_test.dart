import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/audio_repository.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/models/rich_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke line(double y, {Color color = Colors.black, int points = 5}) =>
    DrawingStroke(color: color, width: 2.5, points: [for (var i = 0; i < points; i++) Offset(10.0 + i * 5, y + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the file format', () {
    NoteData sample() {
      final box = TextBoxWidgetModel(
        id: 'b1',
        position: const Offset(40, 80),
        size: const Size(300, 120),
        initialText: 'Hello **world**',
        fontSize: 18,
        style: const TextBoxStyle(background: Color(0xFFFFF8E1), borderWidth: 0, radius: 4),
      );
      box.controller.attributes.add(TextSpanAttribute(start: 0, end: 5, type: AttributeType.bold));
      final n = NoteData(
        id: 'n1',
        title: 'Lecture: Analysis',
        background: PageBackground.grid,
        landscape: true,
        marginLeft: 70,
        documentText: '# Title\n\nSome text',
        documentSpans: [TextSpanAttribute(start: 2, end: 7, type: AttributeType.italic)],
      );
      n.strokes = {
        0: [line(10), line(50, color: Colors.red)],
        2: [line(99, points: 40)],
      };
      n.textBoxes[1] = [box];
      n.highlights[0] = [PdfHighlight(rect: const Rect.fromLTRB(1, 2, 30, 40), color: const Color(0x66FFEB3B), commentBox: 'b1')];
      n.images[0] = [ImageItem(id: 'i1', path: '/x/a.png', position: const Offset(5, 6), size: const Size(70, 80))];
      return n;
    }

    test('everything of a note survives being written and read', () {
      final bytes = encodeNoteFile(NoteFileParts(sample(),
          createdAt: DateTime(2026, 1, 2), updatedAt: DateTime(2026, 3, 4), images: {'i1': Uint8List.fromList([1, 2, 3])}, imageExtensions: {'i1': 'jpg'}));
      final back = decodeNoteFile(bytes);
      final n = back.note;
      expect(n.title, 'Lecture: Analysis');
      expect(n.background, PageBackground.grid);
      expect(n.landscape, isTrue);
      expect(n.marginLeft, 70);
      expect(n.documentText, '# Title\n\nSome text');
      expect(n.documentSpans.single.type, AttributeType.italic);
      expect(back.createdAt, DateTime(2026, 1, 2));
      expect(back.updatedAt, DateTime(2026, 3, 4));

      expect(n.strokes.keys, [0, 2]);
      expect(n.strokes[0]!.length, 2);
      expect(n.strokes[0]![1].color.toARGB32(), Colors.red.toARGB32());
      expect(n.strokes[0]![1].width, 2.5);
      expect(n.strokes[2]![0].points.length, 40);
      expect(n.strokes[2]![0].points[39], const Offset(10 + 39 * 5, 99 + 39));

      final box = n.textBoxes[1]!.single;
      expect((box.id, box.position, box.size, box.fontSize), ('b1', const Offset(40, 80), const Size(300, 120), 18.0));
      expect(box.controller.text, 'Hello **world**');
      expect(box.controller.attributes.single.type, AttributeType.bold);
      expect(box.style.background, const Color(0xFFFFF8E1));
      expect(box.style.borderWidth, 0);

      final h = n.highlights[0]!.single;
      expect((h.rect, h.color, h.commentBox), (const Rect.fromLTRB(1, 2, 30, 40), const Color(0x66FFEB3B), 'b1'));

      expect(n.images[0]!.single.position, const Offset(5, 6));
      expect(back.images['i1']!.bytes, [1, 2, 3]);
      expect(back.images['i1']!.extension, 'jpg');
      expect(back.warnings, isEmpty);
    });

    test('files that are apart already read as the same note as the zipped file (a version in the history)', () {
      final parts = NoteFileParts(sample(), images: {'i1': Uint8List.fromList([1, 2, 3])}, imageExtensions: {'i1': 'jpg'});
      final zipped = decodeNoteFile(encodeNoteFile(parts)), apart = decodeNoteFileEntries(noteFileEntries(parts));
      expect(apart.note.title, zipped.note.title);
      expect(apart.note.documentText, zipped.note.documentText);
      expect([for (final l in apart.note.strokes.values) for (final s in l) s.id], [for (final l in zipped.note.strokes.values) for (final s in l) s.id]);
      expect(apart.images.keys, zipped.images.keys);
      expect(apart.warnings, zipped.warnings);
      expect(() => decodeNoteFileEntries(const []), throwsA(isA<NoteFileException>()));
    });

    test('it is a plain ZIP with a readable manifest first', () {
      final bytes = encodeNoteFile(NoteFileParts(sample()));
      final zip = ZipDecoder().decodeBytes(bytes);
      expect(zip.first.name, 'manifest.json');
      final m = jsonDecode(utf8.decode(zip.first.content)) as Map;
      expect(m['format'], 'uninote');
      expect(m['version'], 1);
      expect((m['note'] as Map)['title'], 'Lecture: Analysis');
      expect((m['strokes'] as Map)['count'], 3);
      expect(zip.find('strokes.bin'), isNotNull);
    });

    List<DrawingStroke> back0(Uint8List b) => decodeStrokes(b)[0]!;

    test('strokes pack to a small block and come back exactly', () {
      final strokes = {0: [line(1, points: 100)]};
      final packed = encodeStrokes(strokes);
      expect(packed.length, 12 + 26 + strokes[0]!.single.id.length + 100 * 8); // (a byte of the stroke's layer, from version 6, is in the 26)
      expect(back0(packed).single.id, strokes[0]!.single.id); // the id travels with the stroke
      final back = decodeStrokes(packed);
      expect(back[0]!.single.points, strokes[0]!.single.points);
      expect(() => decodeStrokes(packed.sublist(0, 40)), throwsA(isA<NoteFileException>()));
    });

    test('the brush of a stroke comes back, and the pen (no brush) is the default', () {
      final roller = line(2, points: 5)..brush = rollerBrushId;
      final other = line(3, points: 5)..brush = 'ext:inks/felt';
      final back = decodeStrokes(encodeStrokes({0: [line(1, points: 5), roller, other]}))[0]!;
      expect([for (final s in back) s.brush], [penBrushId, rollerBrushId, 'ext:inks/felt']);
    });

    test('what is not a note file is refused with a reason', () {
      expect(() => decodeNoteFile(Uint8List.fromList([1, 2, 3, 4])), throwsA(predicate((e) => '$e'.contains('not a ZIP'))));
      final empty = ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.string('x.txt', 'hi')));
      expect(() => decodeNoteFile(empty), throwsA(predicate((e) => '$e'.contains('manifest'))));
      Uint8List withManifest(Map<String, Object?> m) => ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.string('manifest.json', jsonEncode(m))));
      expect(() => decodeNoteFile(withManifest({'format': 'other', 'version': 1})), throwsA(isA<NoteFileException>()));
      expect(() => decodeNoteFile(withManifest({'format': 'uninote', 'version': 99})), throwsA(predicate((e) => '$e'.contains('newer version'))));
    });

    test('a file from the future with extra fields is still read, and what is missing is named', () {
      final good = ZipDecoder().decodeBytes(encodeNoteFile(NoteFileParts(sample(), images: {})));
      final m = jsonDecode(utf8.decode(good.first.content)) as Map<String, Object?>;
      m['somethingNew'] = {'a': 1};
      (m['note'] as Map)['alsoNew'] = true;
      final out = Archive()..add(ArchiveFile.string('manifest.json', jsonEncode(m)));
      for (final f in good) {
        if (f.name != 'manifest.json' && f.name != 'strokes.bin') out.add(f);
      }
      final back = decodeNoteFile(ZipEncoder().encodeBytes(out));
      expect(back.note.title, 'Lecture: Analysis');
      expect(back.note.strokes, isEmpty);
      expect(back.warnings, containsAll([contains('pen strokes'), contains('picture')]));
    });
  });

  group('the service', () {
    late Directory root, support, kept;
    late Database db;
    late NoteRepository repo;
    late NoteFileService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('notefiles_');
      support = await Directory('${root.path}/support').create();
      kept = Directory('${root.path}/kept');
      db = await AppDatabase.open(path: '${root.path}/n.db');
      repo = NoteRepository(db);
      service = NoteFileService(repo, supportDirectory: () async => support);
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    Future<String> richNote() async {
      final pdf = File('${root.path}/doc.pdf')..writeAsBytesSync(utf8.encode('%PDF-1.4 fake'));
      final pic = File('${root.path}/pic.png')..writeAsBytesSync([9, 8, 7, 6]);
      final id = await repo.createNote(title: 'Physics / Week 1');
      final n = (await repo.loadNote(id))!
        ..pdfName = 'doc.pdf'
        ..pdfPath = pdf.path
        ..pdfSha256 = sha256.convert(pdf.readAsBytesSync()).toString()
        ..pdfPageCount = 3
        ..documentText = 'words';
      n.strokes[0] = [line(10), line(60)];
      n.images[1] = [ImageItem(id: 'p', path: pic.path, position: const Offset(1, 2), size: const Size(30, 40))];
      n.highlights[0] = [PdfHighlight(rect: const Rect.fromLTWH(5, 5, 50, 10), color: Colors.yellow)];
      await repo.saveNote(n);
      return id;
    }

    test('the sounds of a note go into its file and come out again, also when the note is opened as a copy on the same device', () async {
      final audio = AudioRepository(db, root: () async => Directory('${support.path}/audio'));
      service.audio = audio;
      final id = await repo.createNote(title: 'Lecture');
      final wav = wavFromMuLaw(Uint8List.fromList(List.generate(8000, (i) => 0x80 + i % 40)), 8000);
      await audio.add(id, wav, title: 'Whole lecture', createdAt: DateTime(2026, 3, 1, 9));
      await audio.add(id, wav, title: 'Reading', kind: AudioKind.speech);
      final bytes = (await service.exportBytes(id))!;
      expect(decodeNoteFile(bytes).audio.map((a) => a.title), ['Whole lecture', 'Reading']);
      expect(decodeNoteFile(bytes).audio.first.durationMs, 1000);

      final copy = (await service.importBytes(bytes)).noteId;
      final copied = await audio.list(copy);
      expect(copied.map((a) => (a.title, a.kind)), [('Whole lecture', AudioKind.recording), ('Reading', AudioKind.speech)]);
      expect(await audio.bytesOf(copied.first), wav);
      expect(copied.first.createdAt, DateTime(2026, 3, 1, 9));
      // the original keeps its own
      expect((await audio.list(id)).length, 2);
      expect(await audio.bytesOf((await audio.list(id)).first), wav);
      expect(await audio.counts(), {id: 2, copy: 2});
    });

    test('a file with a sound missing from it opens with a warning', () async {
      final audio = AudioRepository(db, root: () async => Directory('${support.path}/audio'));
      service.audio = audio;
      final id = await repo.createNote(title: 'Lecture');
      await audio.add(id, wavFromMuLaw(Uint8List.fromList([1, 2, 3]), 8000), title: 'x');
      final archive = ZipDecoder().decodeBytes((await service.exportBytes(id))!);
      final without = Archive();
      for (final f in archive.files) {
        if (!f.name.startsWith('media/audio/')) without.add(f);
      }
      final result = await service.importBytes(Uint8List.fromList(ZipEncoder().encodeBytes(without)));
      expect(result.warnings, ['A sound is not in the file and was left out']);
      expect(await audio.list(result.noteId), isEmpty);
    });

    test('a note, with its PDF and pictures, can be saved to a file and opened again as a new note', () async {
      final id = await richNote();
      final out = '${root.path}/week1.uninote';
      expect(await service.exportTo(id, out), isTrue);
      expect(File('$out.part').existsSync(), isFalse); // written whole, then put in place
      expect(File(out).lengthSync(), greaterThan(100));

      final folder = await repo.createFolder('Imported');
      final result = await service.importFile(out, folderId: folder);
      expect(result.noteId, isNot(id)); // a note of its own
      expect(result.warnings, isEmpty);
      final back = (await repo.loadNote(result.noteId))!;
      expect(back.title, 'Physics / Week 1');
      expect(back.documentText, 'words');
      expect(back.strokes[0]!.length, 2);
      expect(back.pdfName, 'doc.pdf');
      expect(File(back.pdfPath!).readAsStringSync(), '%PDF-1.4 fake');
      expect(back.pdfPath, isNot((await repo.loadNote(id))!.pdfPath)); // its own copy
      expect(back.pdfPageCount, 3);
      expect(File(back.images[1]!.single.path).readAsBytesSync(), [9, 8, 7, 6]);
      expect(back.highlights[0]!.single.rect, const Rect.fromLTWH(5, 5, 50, 10));
      expect((await repo.noteInfo(result.noteId))!.folderId, folder);
      expect((await repo.loadNote(id))!.strokes[0]!.length, 2); // the original is as it was
    });

    test('a PDF that does not match its checksum is left out, with a warning', () async {
      final id = await richNote();
      final bytes = (await service.exportBytes(id))!;
      final zip = ZipDecoder().decodeBytes(bytes);
      final out = Archive();
      for (final f in zip) {
        out.add(f.name == 'source.pdf' ? ArchiveFile.bytes('source.pdf', utf8.encode('tampered')) : f);
      }
      final result = await service.importBytes(ZipEncoder().encodeBytes(out));
      expect(result.warnings.single, contains('checksum'));
      expect((await repo.loadNote(result.noteId))!.pdfPath, isNull);
    });

    test('file names are safe and tell notes with one title apart', () {
      expect(NoteFileService.fileNameFor('Physics / Week 1', 'abc-12345678'), 'Physics _ Week 1 (12345678).uninote');
      expect(NoteFileService.fileNameFor('', 'xyz'), 'Untitled (xyz).uninote');
      expect(NoteFileService.fileNameFor('..hidden', 'id12345678'), 'hidden (12345678).uninote');
      expect(NoteFileService.fileNameFor('a' * 200, 'k').length, lessThan(100));
    });

    test('a file is written into a folder under the title, and follows a change of title', () async {
      final id = await richNote();
      final path = await service.exportInto(id, kept.path);
      final name = NoteFileService.fileNameFor('Physics / Week 1', id);
      expect(path, '${kept.path}/$name');
      expect(decodeNoteFile(File(path!).readAsBytesSync()).note.title, 'Physics / Week 1');

      final n = (await repo.loadNote(id))!..title = 'Physics week one';
      await repo.saveNote(n);
      await service.exportInto(id, kept.path);
      final names = [for (final f in kept.listSync().whereType<File>()) f.path.split('/').last];
      expect(names, [NoteFileService.fileNameFor('Physics week one', id)]); // the old name is gone
      expect(await service.exportInto('nothing', kept.path), isNull);
    });

    test('another note with the same title keeps its own file', () async {
      final a = await repo.createNote(title: 'Same');
      final b = await repo.createNote(title: 'Same');
      await service.exportInto(a, kept.path);
      await service.exportInto(b, kept.path);
      expect(kept.listSync().whereType<File>().length, 2);
    });

    group('as an automation', () {
      late AutomationService automations;
      setUp(() async {
        await db.delete('settings', where: "key LIKE 'automations%'");
        automations = AutomationService(repo, TaskRepository(db), noteFiles: service);
        await automations.load();
      });
      tearDown(() => automations.dispose());

      test('closing a note saves its file in the folder, in the background, and only when it changed', () async {
        await automations.add(Automation(id: 'f', event: AutomationEvent.noteClosed, action: AutomationAction.saveNoteFile, params: {'dir': kept.path}));
        final id = await richNote();
        expect(await automations.run(AutomationEvent.noteClosed, noteId: id, title: 'x'), ['Saving the note as a file in the background...']);
        await automations.filesDone;
        final file = File('${kept.path}/${NoteFileService.fileNameFor('Physics / Week 1', id)}');
        expect(file.existsSync(), isTrue);
        expect(automations.all.single.lastResult, startsWith('Saved as '));
        expect(decodeNoteFile(file.readAsBytesSync()).note.strokes[0]!.length, 2);

        file.deleteSync();
        expect(await automations.run(AutomationEvent.noteClosed, noteId: id, title: 'x'), isEmpty); // not changed: no new file
        expect(file.existsSync(), isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 5));
        final n = (await repo.loadNote(id))!..documentText = 'more words';
        await repo.saveNote(n);
        expect(await automations.run(AutomationEvent.noteClosed, noteId: id, title: 'x'), hasLength(1));
        await automations.filesDone;
        expect(decodeNoteFile(file.readAsBytesSync()).note.documentText, 'more words');
      });

      test('without a folder it says so', () async {
        await automations.add(const Automation(id: 'f', event: AutomationEvent.noteClosed, action: AutomationAction.saveNoteFile));
        final id = await richNote();
        expect(await automations.run(AutomationEvent.noteClosed, noteId: id, title: 'x'), ['No folder chosen for the file']);
      });

      test('it is offered after any event that has a note, and survives being saved', () {
        expect(AutomationAction.saveNoteFile.worksAfter(AutomationEvent.noteClosed), isTrue);
        expect(AutomationAction.saveNoteFile.worksAfter(AutomationEvent.noteStale), isTrue);
        expect(AutomationAction.saveNoteFile.worksAfter(AutomationEvent.appStarted), isFalse);
        final a = Automation(id: 'x', event: AutomationEvent.noteClosed, action: AutomationAction.saveNoteFile, params: {'dir': '/tmp/x'});
        expect(Automation.decodeAll(Automation.encodeAll([a])).single.action, AutomationAction.saveNoteFile);
      });
    });
  });
}

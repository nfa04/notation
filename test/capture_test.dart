import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/capture/capture_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _page = '<html><head><title>Plants | Blog</title><meta property="og:site_name" content="Blog"></head><body><article><h1>Plants</h1>'
    '<p>Plants take in carbon dioxide through tiny pores called stomata, and give out oxygen while they do it, every day.</p></article></body></html>';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late Directory dir;
  late CaptureService capture;
  final fetched = <Uri>[];

  late Database db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('capture_');
    db = await AppDatabase.open(path: '${dir.path}/notes.db');
    repo = NoteRepository(db);
    fetched.clear();
    capture = CaptureService(
      repository: repo,
      supportDirectory: () async => dir,
      clock: () => DateTime(2026, 3, 4, 9, 5),
      fetch: (url) async {
        fetched.add(url);
        if (url.host == 'down.example') throw const SocketException('no route');
        if (url.host == 'empty.example') return '<html><body><p>hi</p></body></html>';
        return _page;
      },
    );
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<String> docOf(String id) async => (await repo.loadNote(id))!.documentText;
  Future<String?> folderNameOf(String id) async {
    final folder = (await repo.noteInfo(id))!.folderId;
    return folder == null ? null : (await repo.listFolders()).firstWhere((f) => f.id == folder).name;
  }

  test('titles come from the first line with words in it', () {
    expect(CaptureService.titleOf('\n\n## Buy milk and eggs\nsoon'), 'Buy milk and eggs');
    expect(CaptureService.titleOf('- **Call** Anna'), 'Call Anna');
    expect(CaptureService.titleOf('   \n --- \n'), isNull);
    expect(CaptureService.titleOf('x' * 100)!.length, 60);
    expect(CaptureService.titleOf('x' * 100)!.endsWith('...'), isTrue);
  });

  test('a quick note lands in the Inbox, which is made once', () async {
    final a = await capture.quickNote('Buy milk\nand eggs');
    final b = await capture.quickNote('   ');
    expect(a.title, 'Buy milk');
    expect(await docOf(a.noteId), 'Buy milk\nand eggs\n');
    expect(await folderNameOf(a.noteId), 'Inbox');
    expect(b.title, 'Quick note 2026-03-04 09:05');
    expect((await repo.listFolders()).where((f) => f.name == 'Inbox').length, 1);
    expect((await repo.noteInfo(a.noteId))!.folderId, (await repo.noteInfo(b.noteId))!.folderId);
  });

  test('a subject given by the sender is the title', () async {
    final c = await capture.quickNote('The body of the message', title: ' From Anna ');
    expect(c.title, 'From Anna');
  });

  test('a selection from a page is quoted with where it comes from', () async {
    final c = await capture.clipSelection(url: Uri.parse('https://example.org/a'), title: 'An article', text: 'First line\n\nSecond line');
    final doc = await docOf(c.noteId);
    expect(doc, startsWith('# An article\n\nSource: <https://example.org/a>'));
    expect(doc, contains('> First line\n>\n> Second line'));
    expect(fetched, isEmpty); // nothing fetched when the person selected the text
  });

  test('a page is fetched and kept as its article', () async {
    final c = await capture.clipPage(Uri.parse('https://blog.example/plants'));
    expect(c.title, 'Plants');
    final doc = await docOf(c.noteId);
    expect(doc, startsWith('# Plants\n\nSource: <https://blog.example/plants>'));
    expect(doc, contains('Saved 2026-03-04 09:05'));
    expect(doc, contains('Blog'));
    expect(doc, contains('Plants take in carbon dioxide'));
    expect(doc.split('# Plants').length, 2); // the title once
  });

  test('a page that cannot be fetched, has no text, or is no web address is refused and leaves no note', () async {
    await expectLater(capture.clipPage(Uri.parse('https://down.example/x')), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('could not be loaded'))));
    await expectLater(capture.clipPage(Uri.parse('https://empty.example/x')), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('no text'))));
    await expectLater(capture.clipPage(Uri.parse('file:///etc/passwd')), throwsA(isA<StateError>()));
    await expectLater(capture.clipPage(Uri.parse('ftp://example.org/x')), throwsA(isA<StateError>()));
    expect(await repo.listNotes(), isEmpty);
    expect(fetched.where((u) => u.scheme == 'file' || u.scheme == 'ftp'), isEmpty);
  });

  test('shared text: an address alone is a page to clip, anything else is a note', () async {
    final page = await capture.sharedText('  https://blog.example/plants \n', subject: 'Plants');
    expect(page.title, 'Plants');
    expect(fetched.single, Uri.parse('https://blog.example/plants'));
    final text = await capture.sharedText('Look at https://blog.example/plants today', subject: 'Tip');
    expect(text.title, 'Tip');
    expect(fetched.length, 1);
    expect(await docOf(text.noteId), 'Look at https://blog.example/plants today\n');
  });

  test('a shared text file becomes a note; an unknown kind of file is refused', () async {
    final txt = File('${dir.path}/groceries.txt')..writeAsStringSync('milk\neggs');
    final c = await capture.sharedFile(txt.path);
    expect(c.title, 'groceries');
    expect(await docOf(c.noteId), 'milk\neggs\n');
    final zip = File('${dir.path}/x.zip')..writeAsBytesSync([1, 2, 3]);
    await expectLater(capture.sharedFile(zip.path), throwsA(isA<StateError>()));
  });

  testWidgets('a shared picture becomes a note with the picture on its first page, scaled to fit', (tester) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1376, 688), Paint()..color = Colors.red);
      final image = await recorder.endRecording().toImage(1376, 688);
      final png = File('${dir.path}/photo.png')..writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      final c = await capture.sharedFile(png.path);
      final note = (await repo.loadNote(c.noteId))!;
      final item = note.images[0]!.single;
      expect(item.size, const Size(688, 344));
      expect(File(item.path).existsSync(), isTrue);
      expect(item.path, startsWith(dir.path));
      expect(c.title, 'photo');
      expect(await folderNameOf(c.noteId), 'Inbox');
    });
  });

  test('the bookmarklet sends the address, the title and the selection', () {
    expect(webClipperBookmarklet, startsWith('javascript:'));
    expect(webClipperBookmarklet, contains('notation://clip?u='));
    expect(webClipperBookmarklet, contains('getSelection'));
    expect(webClipperBookmarklet.contains('\n'), isFalse);
  });
}

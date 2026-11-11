import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/import/goodnotes_import.dart';
import 'package:notes/import/import_source.dart';
import 'package:notes/import/importer.dart';
import 'package:notes/import/markdown_convert.dart';
import 'package:notes/import/notion_import.dart';
import 'package:notes/import/obsidian_import.dart';
import 'package:notes/import/path_index.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:notes/markdown/document_images.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List zipOf(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, data) => a.addFile(ArchiveFile(name, data.length, data)));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

List<int> text(String s) => utf8.encode(s);

final png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

ConvertEnv envFor(Map<String, PageRef> pages, {List<String> files = const [], String from = 'a.md'}) {
  final p = PathIndex<PageRef>();
  pages.forEach(p.add);
  final f = PathIndex<String>();
  for (final x in files) {
    f.add(x, x);
  }
  return ConvertEnv(pages: p, files: f, from: from, pictures: []);
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('finding what a link means', () {
    final index = PathIndex<String>();
    for (final path in ['Maths/Algebra.md', 'Physics/Algebra.md', 'Maths/Sets/Union.md', 'Inbox.md', 'Notes/x 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b.md']) {
      index.add(path, path);
    }

    test('a bare name finds the nearest note of that name', () {
      expect(index.find('Algebra', 'Physics/Waves.md'), 'Physics/Algebra.md');
      expect(index.find('algebra', 'Maths/Intro.md'), 'Maths/Algebra.md');
      expect(index.find('Inbox', 'Maths/Sets/Union.md'), 'Inbox.md');
    });

    test('paths: relative, from the root, and the end of a path', () {
      expect(index.find('../Inbox.md', 'Maths/Algebra.md'), 'Inbox.md');
      expect(index.find('Sets/Union', 'Maths/Algebra.md'), 'Maths/Sets/Union.md');
      expect(index.find('Maths/Sets/Union', 'Inbox.md'), 'Maths/Sets/Union.md');
      expect(index.find('Sets/Union', 'Inbox.md'), 'Maths/Sets/Union.md');
      expect(index.find('Nothing', 'Inbox.md'), isNull);
      expect(index.find('../../../x', 'Inbox.md'), isNull);
    });

    test('a Notion address is found by the 32 digits at its end', () {
      expect(index.find('https://www.notion.so/workspace/X-3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b?pvs=4', 'Inbox.md'), 'Notes/x 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b.md');
    });
  });

  group('Obsidian text', () {
    final graphs = const PageRef('id-g', 'Graphs');
    final slides = const PageRef('id-s', 'slides');

    String convert(String t, {Map<String, PageRef>? pages, List<String> files = const []}) {
      final env = envFor(pages ?? {'Graphs.md': graphs, 'Uni/slides.pdf': slides}, files: files);
      return convertMarkdown(t, env, wiki: true);
    }

    test('wiki links become note links, with text, heading and unknown targets', () {
      expect(convert('See [[Graphs]] and [[graphs|the graphs]] or [[Graphs#Trees]].'),
          'See [Graphs](note:id-g) and [the graphs](note:id-g) or [Graphs > Trees](note:id-g).');
      expect(convert('Missing [[Nowhere]] and [[Nowhere|text]] and [[#Heading]].'), 'Missing Nowhere and text and Heading.');
      expect(convert('The slides: [[slides.pdf]]'), 'The slides: [slides](note:id-s)');
      expect(convert('Embedded: ![[Graphs]]'), 'Embedded: ![Graphs](note:id-g)'.replaceFirst('![', '['));
    });

    test('links inside code are left alone, a note named with a dot is still a note', () {
      expect(convert('`[[Graphs]]` and [[Graphs]]\n```\n[[Graphs]] #tag\n```'), '`[[Graphs]]` and [Graphs](note:id-g)\n```\n[[Graphs]] #tag\n```');
      final dotted = convert('[[Lecture 3.2 Graphs]]', pages: {'Lecture 3.2 Graphs.md': const PageRef('id-l', 'Lecture 3.2 Graphs')});
      expect(dotted, '[Lecture 3.2 Graphs](note:id-l)');
    });

    test('pictures are asked for, with their size dropped from the text', () {
      final env = envFor({}, files: ['img/a.png']);
      final out = convertMarkdown('![[a.png|300]] ![[a.png|my caption]] ![x](img/a.png) ![gone](nope.png)', env, wiki: true);
      expect(env.pictures, ['img/a.png']);
      expect(out, '![](${pictureMark(0)}) ![my caption](${pictureMark(0)}) ![x](${pictureMark(0)}) gone');
      expect(env.missing, contains('nope.png'));
    });

    test('callouts, comments, block ids, tabs and formulas over several lines', () {
      final out = convert('> [!warning] Careful\n> text\n\n> [!note]-\n> more\n%%secret%% shown ^abc\ntext %%multi\nline%% end\n- a\n\t- b\n\$\$\na + b\n\$\$');
      expect(out, '> **Careful**\n> text\n\n> **Note**\n> more\n shown\ntext  end\n- a\n  - b\n\$\$a + b\$\$');
    });

    test('tags in the text are collected, a heading is not a tag', () {
      final env = envFor({});
      convertMarkdown('# Heading\nthis is #uni/maths and #2024 and a#b and #exam-prep', env, wiki: true);
      expect(env.tags, {'uni/maths', 'exam-prep'});
    });

    test('properties: tags become tags, the rest a list under the title', () {
      final env = envFor({'Graphs.md': graphs});
      final page = convertObsidianPage('---\ntags:\n  - uni\n  - "#maths/discrete"\naliases: [G]\ncourse: Discrete maths\nrelated: "[[Graphs]]"\n---\nBody [[Graphs]]', env, title: 'Week 1');
      expect(page.tags, {'uni', 'maths/discrete'});
      expect(page.text, '# Week 1\n\n- **course:** Discrete maths\n- **related:** [Graphs](note:id-g)\n\nBody [Graphs](note:id-g)\n');
    });

    test('a note with its own heading keeps it first', () {
      final page = convertObsidianPage('---\ncourse: X\n---\n# Week 1\ntext', envFor({}), title: 'Week 1');
      expect(page.text, '# Week 1\ntext\n\n---\n\n- **course:** X\n');
    });
  });

  group('Notion text', () {
    test('names lose their digits', () {
      expect(notionName('Week 3 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b.md'), 'Week 3');
      expect(notionName('dir/Tasks 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b_all.csv'), 'Tasks');
      expect(notionName('Plain.md'), 'Plain');
    });

    test('links are paths with %20, pictures too, callouts and toggles are HTML', () {
      final env = envFor({'Course 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b/Week 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md': const PageRef('w1', 'Week 1')},
          files: ['Course 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b/fig.png'], from: 'Course 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b.md');
      final out = convertNotionPage(
        '# Course\n\n[Week 1](Course%203f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b/Week%201%20aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md)\n\n'
        '![fig](Course%203f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b/fig.png)\n\n<aside>\n💡 Remember this\n</aside>\n\n<details><summary>More</summary>\n\nhidden\n\n</details>\n\n[web](https://example.com)\n',
        env,
        title: 'Course',
        databaseRow: false,
      );
      expect(out.text, contains('[Week 1](note:w1)'));
      expect(out.text, contains('![fig](${pictureMark(0)})'));
      expect(out.text, contains('> 💡 Remember this'));
      expect(out.text, contains('**More**'));
      expect(out.text, isNot(contains('<details')));
      expect(out.text, contains('[web](https://example.com)'));
    });

    test('the properties of a database row become a list', () {
      final out = convertNotionPage('# Task\n\nStatus: Done\nDue: May 3, 2026\n\nText', envFor({}), title: 'Task', databaseRow: true);
      expect(out.text, '# Task\n\n- **Status:** Done\n- **Due:** May 3, 2026\n\nText\n');
    });

    test('a title is added when the page has none', () {
      expect(convertNotionPage('just text', envFor({}), title: 'T', databaseRow: false).text, '# T\n\njust text\n');
    });

    test('CSV: quotes, commas and line breaks; the first column links to a row page', () {
      final rows = parseCsv('Name,Notes\r\n"A, b","line\none ""q"""\nC,\n');
      expect(rows, [
        ['Name', 'Notes'],
        ['A, b', 'line\none "q"'],
        ['C', ''],
      ]);
      final table = notionTable('Name,Notes\nA,x|y\nB,\n', title: 'DB', rows: {'a': const PageRef('ida', 'A')});
      expect(table, '# DB\n\n| Name | Notes |\n| --- | --- |\n| [A](note:ida) | x\\|y |\n| B |  |\n');
    });
  });

  group('sources', () {
    test('a zip with one folder uses it as root, hidden files are left out, nested zips are opened', () {
      final s = sourceFromZip(zipOf({'Vault/a.md': text('a'), 'Vault/.obsidian/app.json': text('{}'), '__MACOSX/Vault/a.md': text('x'), 'Vault/b/c.md': text('c')}), name: 'x');
      expect(s.name, 'Vault');
      expect({for (final f in s.files) f.path}, {'a.md', 'b/c.md'});
    });

    test('a zip inside a zip is opened (Notion splits big exports)', () {
      final s = sourceFromZip(zipOf({'part1.zip': zipOf({'A/one.md': text('1')}), 'part2.zip': zipOf({'B/two.md': text('2')})}), name: 'export');
      expect({for (final f in s.files) f.path}, {'A/one.md', 'B/two.md'});
      expect(s.name, 'export');
    });

    test('something that is no zip says so', () {
      expect(() => sourceFromZip(Uint8List.fromList([1, 2, 3]), name: 'x'), throwsFormatException);
    });
  });

  group('GoodNotes', () {
    test('the PDFs inside are found by what they are, the biggest first', () async {
      final big = text('%PDF-1.7\n${'x' * 500}');
      final small = text('%PDF-1.4\nyy');
      final pdfs = await goodnotesPdfs(zipOf({'index.notes.pb': text('binary'), 'attachments/AAA': small, 'attachments/BBB.pdf': big}), name: 'Notes');
      expect(pdfs.map((p) => p.name), ['BBB.pdf', 'AAA']);
    });

    test('no PDF and no zip are explained', () async {
      await expectLater(goodnotesPdfs(zipOf({'a': text('not a pdf at all')}), name: 'n'), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('Export as PDF'))));
      await expectLater(goodnotesPdfs(Uint8List.fromList([1, 2, 3]), name: 'n'), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('Export as PDF'))));
    });
  });

  group('the whole import', () {
    late NoteRepository repo;
    late TagRepository tags;
    late Directory images;

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final table in ['note_tags', 'notes', 'folders']) {
        await db.delete(table);
      }
      repo = NoteRepository(db);
      tags = TagRepository(db);
      images = Directory.systemTemp.createTempSync('import_images');
      DocumentImages.dir = images.path;
    });
    tearDown(() {
      DocumentImages.dir = null;
      images.deleteSync(recursive: true);
    });

    Future<Map<String, String>> documents() async {
      final out = <String, String>{};
      for (final n in await repo.listNotes()) {
        out[n.title] = (await repo.loadNote(n.id))!.documentText;
      }
      return out;
    }

    test('an Obsidian vault: folders, notes, links both ways, tags, pictures', () async {
      final source = sourceFromZip(
        zipOf({
          'Uni/Maths/Graphs.md': text('---\ntags: [uni]\n---\nSee [[Trees]] and ![[tree.png]] #exam\n'),
          'Uni/Trees.md': text('Back to [[Graphs]]'),
          'Uni/tree.png': png,
          'Uni/lecture.mp3': [1, 2, 3],
          'Uni/.obsidian/x.json': text('{}'),
          'Inbox.md': text('empty'),
        }),
        name: 'vault',
      );
      var last = 0;
      final report = await importNotes(kind: ImportKind.obsidian, source: source, repository: repo, tags: tags, rootName: 'My vault', onProgress: (d, t) => last = d);
      expect(report.notes, 3);
      expect(report.pictures, 1);
      expect(report.skipped, {'lecture.mp3'});
      expect(report.failed, isEmpty);
      expect(last, 3);
      final docs = await documents();
      final ids = {for (final n in await repo.listNotes()) n.title: n.id};
      expect(docs['Graphs'], contains('[Trees](note:${ids['Trees']})'));
      expect(docs['Graphs'], matches(RegExp(r'!\[\]\(image:[^)]+\.png\)')));
      expect(docs['Trees'], contains('[Graphs](note:${ids['Graphs']})'));
      expect(docs['Graphs']!.startsWith('# Graphs\n'), isTrue);
      expect(await tags.tagsOf(ids['Graphs']!), unorderedEquals(['uni', 'exam']));
      expect(images.listSync(), hasLength(1));
      // folders: My vault / Uni / Maths
      final folders = await repo.listFolders();
      expect({for (final f in folders) f.name}, {'My vault', 'Uni', 'Maths'});
      final maths = folders.firstWhere((f) => f.name == 'Maths');
      final uni = folders.firstWhere((f) => f.name == 'Uni');
      final root = folders.firstWhere((f) => f.name == 'My vault');
      expect(maths.parentId, uni.id);
      expect(uni.parentId, root.id);
      expect(report.rootFolderId, root.id);
      expect((await repo.listNotes()).firstWhere((n) => n.title == 'Inbox').folderId, root.id);
    });

    test('a Notion export: nesting, a database as table, links by path, pictures', () async {
      const course = 'Course 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b';
      const week = 'Week 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const db = 'Tasks bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const row = 'Read chapter cccccccccccccccccccccccccccccccc';
      final source = sourceFromZip(
        zipOf({
          '$course.md': text('# Course\n\n[Week 1]($course/${week.replaceAll(' ', '%20')}.md)\n'.replaceAll(course, course.replaceAll(' ', '%20'))),
          '$course/$week.md': text('# Week 1\n\n![fig](${course.replaceAll(' ', '%20')}/fig.png)\n'),
          '$course/fig.png': png,
          '$db.csv': text('Name,Status\nRead chapter,Done\n'),
          '$db/$row.md': text('# Read chapter\n\nStatus: Done\n\nText'),
          '${db}_all.csv': text('x'),
        }),
        name: 'export',
      );
      final report = await importNotes(kind: ImportKind.notion, source: source, repository: repo, rootName: 'Notion');
      expect(report.failed, isEmpty);
      expect(report.notes, 3);
      expect(report.tables, 1);
      expect(report.pictures, 1);
      final ids = {for (final n in await repo.listNotes()) n.title: n.id};
      expect(ids.keys, {'Course', 'Week 1', 'Tasks', 'Read chapter'});
      final docs = await documents();
      expect(docs['Course'], contains('[Week 1](note:${ids['Week 1']})'));
      expect(docs['Tasks'], contains('| [Read chapter](note:${ids['Read chapter']}) | Done |'));
      expect(docs['Read chapter'], contains('- **Status:** Done'));
      final folders = {for (final f in await repo.listFolders()) f.name: f};
      expect(folders.keys, {'Notion', 'Course', 'Tasks'});
      final notes = {for (final n in await repo.listNotes()) n.title: n};
      expect(notes['Course']!.folderId, folders['Course']!.id);
      expect(notes['Week 1']!.folderId, folders['Course']!.id);
      expect(notes['Tasks']!.folderId, folders['Tasks']!.id);
      expect(notes['Read chapter']!.folderId, folders['Tasks']!.id);
    });

    final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');
    test('a PDF becomes a PDF note that a link can point at', skip: !pdfium.existsSync(), () async {
      Pdfrx.pdfiumModulePath = pdfium.absolute.path;
      final doc = pw.Document()..addPage(pw.Page(build: (_) => pw.Text('Slide')));
      final pdf = await doc.save();
      final copies = Directory.systemTemp.createTempSync('import_pdfs');
      addTearDown(() => copies.deleteSync(recursive: true));
      final source = sourceFromZip(zipOf({'V/Uni/Lecture 1.pdf': pdf, 'V/Notes.md': text('Slides: [[Lecture 1.pdf]] and ![[Lecture 1.pdf]]')}), name: 'v');
      final report = await importNotes(kind: ImportKind.obsidian, source: source, repository: repo, pdfDirectory: copies);
      expect(report.failed, isEmpty);
      expect(report.pdfs, 1);
      final notes = {for (final n in await repo.listNotes()) n.title: n};
      expect(notes.keys, {'Lecture 1', 'Notes'});
      expect(notes['Lecture 1']!.folderId, isNotNull);
      final pdfNote = (await repo.loadNote(notes['Lecture 1']!.id))!;
      expect(pdfNote.pdfName, 'Lecture 1.pdf');
      expect(pdfNote.pdfPageCount, 1);
      expect((await repo.loadNote(notes['Notes']!.id))!.documentText, contains('[Lecture 1](note:${notes['Lecture 1']!.id})'));
    });

    test('a page that cannot be written is reported, the others are still made', () async {
      final source = ImportSource('v', [
        SourceFile('a.md', 1, () async => Uint8List.fromList(text('fine'))),
        SourceFile('b.md', 1, () async => throw const FileSystemException('gone')),
      ]);
      final report = await importNotes(kind: ImportKind.obsidian, source: source, repository: repo);
      expect(report.notes, 1);
      expect(report.failed.single, startsWith('b.md'));
    });
  });
}

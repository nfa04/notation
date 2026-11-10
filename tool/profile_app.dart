// Measures what a big library costs the app, as a release-like (AOT) build runs it: the database, the code that runs at each save and
// at each key, and real frames of the real editor (typing, writing with the pen, scrolling). It prints numbers, it checks nothing.
//
//   flutter build linux --profile -t tool/profile_app.dart
//   PROFILE_DIR=~/.cache/notation-profile build/linux/x64/profile/bundle/notation
//
// It works only in PROFILE_DIR (its own database, never the notes of the person) and starts from an empty one when PROFILE_FRESH=1 or
// there is none yet; delete the folder when done. A second instance needs its own session bus if the app is running already: it would
// hand over to that one and end. Set DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent for that. PROFILE_ONLY=data,code,frames runs a part.
// PROFILE_CPU=1 FLUTTER_ENGINE_SWITCHES=1 FLUTTER_ENGINE_SWITCH_1=enable-dart-profiling says which functions the time goes to.
// PROFILE_TABLET=1 runs as a device with no screen reader does (Linux always has the accessibility tree on) and says what a key would take
// on the reference device, a tablet of about 2016 (Cortex-A53, 1.6 GHz): about 12 times slower than the Ryzen 7 this was made on, going by
// published single-core scores. PROFILE_ONLY=frames,sweep,doconly then types in documents up to the reference of 100 pages.
// PROFILE_ONLY=save runs what a save costs while a document of 5, 40 and 140 KB is written (plain and with 1 formatted stretch in every 90
// letters); PROFILE_ONLY=export makes a PDF, pictures, a .uninote file, Word and a web page of the heavy note and of documents.
// PROFILE_ONLY=pdfscroll reads, flings and jumps through imported PDFs of dense text, scans and vector drawings (made once in PROFILE_DIR).
// PROFILE_ONLY=startup runs the real main() of the app and follows its memory: set XDG_DATA_HOME to a folder inside PROFILE_DIR, copy
// notes.db to <it>/io.github.nfa04.notation/ and run it with no network:
//   unshare -rn sh -c 'ip link set lo up; PROFILE_ONLY=startup ... build/linux/x64/profile/bundle/notation'
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show FramePhase, FrameTiming, Offset;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show TextEditingDeltaInsertion;
import 'package:notes/automations/automation_service.dart' show ImageExporter, NoteEditorHandle;
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/link_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/export/image_export.dart' show ImagePreset;
import 'package:notes/export/pdf_ink_text.dart' show pdfInkTextSetting;
import 'package:notes/ink/ink_clusters.dart' show clusterStrokes;
import 'package:notes/history/note_history.dart';
import 'package:notes/main.dart' as app;
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/markdown/grammar.dart';
import 'package:notes/markdown/document_export.dart';
import 'package:notes/markdown/markdown_formatting.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/models/rich_text.dart' show AttributeType, RichInlineTextController, TextSpanAttribute;
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/folder_view.dart';
import 'package:notes/search/search_query.dart';
import 'package:notes/style/stylus_settings.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _notes = 5000, _folders = 200, _tasks = 2000;
const _heavyPages = 30, _heavyPerPage = 200, _heavyPoints = 60;
const _pageStrokes = 5000;

/// The reference document: with what [markdownOf] writes, this is 100 pages.
const _referenceSize = 140000;

final _results = <String>[];

void say(String what, String value) {
  final line = 'PERF  ${what.padRight(58)} $value';
  stdout.writeln(line);
  _results.add(line);
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(micros < 10000 ? 2 : 1);

String _stats(List<int> micros) {
  if (micros.isEmpty) return 'no samples';
  final s = [...micros]..sort();
  int at(double q) => s[(q * (s.length - 1)).round()];
  return 'median ${_ms(at(0.5)).padLeft(8)} ms   p95 ${_ms(at(0.95)).padLeft(8)} ms   max ${_ms(s.last).padLeft(8)} ms   n=${s.length}';
}

/// Runs [body] and says for how long at most the main isolate could do nothing else: the time the screen would have stood still.
Future<void> stalled(String what, Future<void> Function() body) async {
  var last = Stopwatch()..start();
  var worst = 0;
  final ticker = Timer.periodic(const Duration(milliseconds: 4), (_) {
    worst = max(worst, last.elapsedMilliseconds);
    last = Stopwatch()..start();
  });
  final sw = Stopwatch()..start();
  await body();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  ticker.cancel();
  say(what, '${sw.elapsedMilliseconds} ms in all, the screen stood still for up to $worst ms');
}

/// Runs [body] [runs] times and says how long it took.
Future<void> timed(String what, Future<void> Function() body, {int runs = 7}) async {
  final all = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await body();
    all.add(sw.elapsedMicroseconds);
  }
  say(what, _stats(all));
}

void timedSync(String what, void Function() body, {int runs = 25}) {
  final all = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    body();
    all.add(sw.elapsedMicroseconds);
  }
  say(what, _stats(all));
}

const _words = 'the of and a to in is you that it he was for on are as with his they at be this have from or one had by word but not what all were '
    'we when your can said there use an each which she do how their if will up other about out many then them these so some her would make like him '
    'into time has look two more write go see number no way could people my than first water been call who oil its now find long down day did get';

String _sentence(Random r, int words) {
  final all = _words.split(' ');
  return List.generate(words, (_) => all[r.nextInt(all.length)]).join(' ');
}

/// A document of about [chars] characters with what people write: headings, lists, tasks, emphasis, code, tables.
String markdownOf(int chars, Random r) {
  final b = StringBuffer();
  var i = 0;
  while (b.length < chars) {
    switch (i++ % 8) {
      case 0:
        b.writeln('## ${_sentence(r, 4)}\n');
      case 1 || 5:
        b.writeln('${_sentence(r, 30)} **${_sentence(r, 3)}** and *${_sentence(r, 2)}* with `code` in it. ${_sentence(r, 25)}\n');
      case 2:
        for (var k = 0; k < 4; k++) {
          b.writeln('- ${_sentence(r, 9)}');
        }
        b.writeln();
      case 3:
        for (var k = 0; k < 3; k++) {
          b.writeln('- [ ] ${_sentence(r, 6)}');
        }
        b.writeln();
      case 4:
        b.writeln('> ${_sentence(r, 16)}\n');
      case 6:
        b.writeln('```dart\nfinal a = ${r.nextInt(100)};\nprint(a);\n```\n');
      case 7:
        b.writeln('| a | b | c |\n|---|---|---|\n| ${r.nextInt(9)} | ${r.nextInt(9)} | ${r.nextInt(9)} |\n');
    }
  }
  return b.toString();
}

DrawingStroke _pen(Random r, double x, double y, int points) {
  var p = Offset(x, y);
  return DrawingStroke(
    color: const Color(0xFF101010),
    width: 2.2,
    points: [for (var i = 0; i < points; i++) p += Offset(0.8 + r.nextDouble(), (r.nextDouble() - 0.5) * 3)],
    pressures: [for (var i = 0; i < points; i++) 90 + r.nextInt(80)],
  );
}

class _Library {
  final Database db;
  final NoteRepository repo;
  final String heavy, onePage, document;
  _Library(this.db, this.repo, this.heavy, this.onePage, this.document);
}

Future<_Library> _seed(String path) async {
  final fresh = !File(path).existsSync();
  final db = await AppDatabase.open(path: path);
  final repo = NoteRepository(db);
  if (!fresh) {
    final ids = (await db.query('settings', where: "key LIKE 'profile_%'")).map((r) => r['value'] as String).toList();
    return _Library(db, repo, ids[0], ids[1], ids[2]);
  }
  final sw = Stopwatch()..start();
  final r = Random(42);
  final folderIds = <String>[];
  for (var i = 0; i < _folders; i++) {
    folderIds.add(await repo.createFolder('Folder $i', parentId: i < 20 || r.nextBool() ? null : folderIds[r.nextInt(20)]));
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  final tags = List.generate(40, (i) => 'tag$i');
  final allIds = <String>[];
  var batch = db.batch();
  for (var i = 0; i < _notes; i++) {
    final id = NoteRepository.newId();
    allIds.add(id);
    final text = markdownOf(1500 + r.nextInt(4000), r);
    batch.insert('notes', {
      'id': id,
      'title': _sentence(r, 4),
      'folder_id': i % 5 == 0 ? null : folderIds[r.nextInt(_folders)],
      'created_at': now - i * 3600000,
      'updated_at': now - i * 1800000,
      'document_text': i > 0 && i % 7 == 0 ? '$text\nsee [a note](note:${allIds[r.nextInt(i)]})\n' : text,
    });
    for (var t = 0; t < 3; t++) {
      batch.insert('note_tags', {'note_id': id, 'tag': tags[r.nextInt(tags.length)]}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    batch.insert('text_boxes', {
      'id': 'box$i',
      'note_id': id,
      'page_index': 0,
      'x': 50.0,
      'y': 50.0,
      'width': 200.0,
      'height': 80.0,
      'font_size': 14.0,
      'text': _sentence(r, 12),
      'spans': '[]',
      'seq': 0,
    });
    if (i % 200 == 199) {
      await batch.commit(noResult: true);
      batch = db.batch();
    }
  }
  await batch.commit(noResult: true);
  final tasks = TaskRepository(db);
  for (var i = 0; i < _tasks; i += 1) {
    await tasks.createTask(_sentence(r, 5));
  }

  final heavy = await repo.createNote(title: 'Heavy handwriting');
  final page = await repo.createNote(title: 'One page of 5000 lines');
  final document = await repo.createNote(title: 'Long document');
  await repo.saveNote(NoteData(
    id: heavy,
    title: 'Heavy handwriting',
    background: PageBackground.lines,
    pageFormat: PageFormat.a4,
    strokes: {
      for (var p = 0; p < _heavyPages; p++) p: [for (var i = 0; i < _heavyPerPage; i++) _pen(r, 40 + (i % 12) * 55, 60 + (i ~/ 12) * 42, _heavyPoints)],
    },
  ));
  await repo.saveNote(NoteData(
    id: page,
    title: 'One page of 5000 lines',
    background: PageBackground.blank,
    pageFormat: PageFormat.a4,
    strokes: {0: [for (var i = 0; i < _pageStrokes; i++) _pen(r, 20 + r.nextDouble() * 500, 20 + r.nextDouble() * 760, 25)]},
  ));
  await repo.saveNote(NoteData(id: document, title: 'Long document', background: PageBackground.blank, pageFormat: PageFormat.a4, documentText: markdownOf(60000, r)));
  await repo.settings.set('profile_1', heavy);
  await repo.settings.set('profile_2', page);
  await repo.settings.set('profile_3', document);
  await repo.settings.set('intro_done', '1');
  say('seeding', '${sw.elapsedMilliseconds} ms, ${(File(path).lengthSync() / (1 << 20)).toStringAsFixed(0)} MB');
  return _Library(db, repo, heavy, page, document);
}

/// Foreign keys whose child column no index begins with: each delete of a parent reads the whole child table.
Future<void> _unindexedForeignKeys(Database db) async {
  final tables = [for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")) r['name'] as String];
  final missing = <String>[];
  for (final t in tables) {
    final firsts = <String>{};
    for (final i in await db.rawQuery("PRAGMA index_list('$t')")) {
      final cols = await db.rawQuery("PRAGMA index_info('${i['name']}')");
      final partial = i['partial'] == 1;
      if (cols.isNotEmpty && !partial) firsts.add(cols.first['name'] as String? ?? '');
    }
    for (final k in await db.rawQuery("PRAGMA foreign_key_list('$t')")) {
      final col = k['from'] as String;
      if (!firsts.contains(col)) missing.add('$t.$col -> ${k['table']}');
    }
  }
  say('foreign keys without an index', missing.isEmpty ? 'none' : missing.join(', '));
}

Future<void> _plan(Database db, String label, String sql, [List<Object?> args = const []]) async {
  final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql', args);
  say('plan: $label', rows.map((r) => r['detail']).join(' | '));
}

Future<void> _data(_Library l) async {
  final db = l.db, repo = l.repo;
  await _unindexedForeignKeys(db);
  await _plan(db, 'listNotes', 'SELECT n.id FROM notes n LEFT JOIN folders f ON f.id = n.folder_id WHERE n.deleted_at IS NULL ORDER BY n.updated_at DESC');
  await _plan(db, 'folder note count', 'SELECT COUNT(*) FROM notes n WHERE n.folder_id = ? AND n.deleted_at IS NULL', ['x']);
  await _plan(db, 'staleNotes', 'SELECT id FROM notes WHERE deleted_at IS NULL AND COALESCE(last_opened_at, updated_at, created_at) < ?', [1]);
  await _plan(db, 'versions latest', "SELECT * FROM note_versions WHERE note_id = ? AND manual = 0 AND branch = ? ORDER BY created_at DESC LIMIT 1", ['x', 'main']);
  await _plan(db, 'tags of note', 'SELECT tag FROM note_tags WHERE note_id = ?', ['x']);

  await timed('listNotes ($_notes notes)', repo.listNotes);
  await timed('listFolders ($_folders folders)', repo.listFolders);
  final tags = TagRepository(db);
  await timed('tags.all', tags.all);
  await timed('tags.counts', tags.counts);
  await timed('tasks.listTasks ($_tasks)', TaskRepository(db).listTasks);
  final ids = [for (final n in await repo.listNotes()) n.id];
  final links = LinkRepository(db);
  await timed('linksTo (backlinks of a note)', () => links.linksTo(ids[100]));
  await timed('mentionsOf', () => links.mentionsOf(ids[100], 'water people find'));
  await timed('searchSources (all the text of the library)', repo.text.searchSources, runs: 3);
  final sources = await repo.text.searchSources();
  final chars = sources.fold<int>(0, (a, s) => a + s.text.length);
  say('search corpus', '${sources.length} pieces, ${(chars / (1 << 20)).toStringAsFixed(1)} MB');
  timedSync('searchNow "water" on the main isolate', () => searchNow(const SearchQuery('water'), sources), runs: 5);
  await timed('search in an isolate, sources sent over', () => RunningSearch.start(const SearchQuery('people find'), sources).results, runs: 3);

  await timed('loadNote heavy (${_heavyPages * _heavyPerPage} lines, ${_heavyPages * _heavyPerPage * _heavyPoints} points)', () => repo.loadNote(l.heavy), runs: 5);
  await timed('loadNote one page (5000 lines)', () => repo.loadNote(l.onePage), runs: 5);
  final note = (await repo.loadNote(l.heavy))!;
  await timed('saveNote heavy, nothing changed', () => repo.saveNote(note));
  final r = Random(1);
  await timed('saveNote heavy, a new line', () {
    note.strokes[3]!.add(_pen(r, 100, 100, 40));
    return repo.saveNote(note);
  });
  await timed('saveNote heavy, a changed line', () {
    note.strokes[3]!.first.points.add(Offset(r.nextDouble(), r.nextDouble()));
    return repo.saveNote(note);
  });
  final doc = (await repo.loadNote(l.document))!;
  await timed('saveNote long document', () => repo.saveNote(doc));
  timedSync('NoteRepository.newId', NoteRepository.newId, runs: 1000);

  final tmp = await Directory(p('versions-$pid')).create(recursive: true);
  final history = NoteHistory(db, repo, supportDirectory: () async => tmp);
  final files = NoteFileService(repo, supportDirectory: () async => tmp);
  for (var i = 0; i < 2; i++) {
    await stalled('history.snapshot heavy (made while writing)', () => history.snapshot(l.heavy, manual: true));
    await stalled('exportBytes heavy (the copy of a shared note)', () => files.exportBytes(l.heavy));
    await stalled('loadNote heavy', () => repo.loadNote(l.heavy));
    await stalled('saveNote heavy', () => repo.saveNote(note));
    await stalled('listNotes', repo.listNotes);
    await stalled('searchSources', repo.text.searchSources);
  }

  // deleting: each child table of a note that has no index is read to the end
  final victims = ids.sublist(ids.length - 40);
  var at = 0;
  await timed('deleteNote (cascades)', () => repo.deleteNote(victims[at++]), runs: 20);
  await timed('purge: 20 notes put in the trash and deleted', () async {
    for (var i = 0; i < 1; i++) {
      await repo.trashNote(victims[at]);
      await repo.deleteNote(victims[at++]);
    }
  }, runs: 20);
}

/// Like [stalled], [runs] times, and says the time all of it took and how long the screen stood still at most, in the middle and at worst.
Future<void> stalledRuns(String what, Future<void> Function(int run) body, {int runs = 7, Future<void> Function()? before}) async {
  final total = <int>[], still = <int>[];
  for (var i = 0; i < runs; i++) {
    await before?.call();
    var last = Stopwatch()..start();
    var worst = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 2), (_) {
      worst = max(worst, last.elapsedMicroseconds);
      last = Stopwatch()..start();
    });
    final sw = Stopwatch()..start();
    await body(i);
    total.add(sw.elapsedMicroseconds);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ticker.cancel();
    still.add(worst);
  }
  say(what, 'all of it: ${_stats(total)}');
  say('   ... the screen stood still', _stats(still));
}

/// The editor of note [id] on the screen, in Document, with its handle and the controller of the text.
Future<({NoteEditorHandle handle, LiveMarkdownController text, State editor})?> _openForWork(_Library l, String id, {bool document = true}) async {
  await _mount(const SizedBox());
  await _mount(_editor(l, id));
  await _settle(300);
  final editor = _find((e) => e.widget is FixedPageNoteEditor) as StatefulElement?;
  if (editor == null) return null;
  final handle = editor.state as NoteEditorHandle;
  await handle.ready;
  await _settle(300);
  if (!document) return (handle: handle, text: LiveMarkdownController(), editor: editor.state);
  await _tapText('Document');
  await _waitFor(() => _find((e) => e.widget is BlockEditor) != null);
  await _settle(300);
  final blocks = _find((e) => e.widget is BlockEditor) as StatefulElement?;
  if (blocks == null) return null;
  return (handle: handle, text: (blocks.state as BlockEditorState).widget.controller, editor: editor.state);
}

/// What a save costs while a document is written: the editor works out whether anything changed, copies the note and has it written.
Future<void> _saves(_Library l) async {
  say('--- saving', 'a letter typed into the middle of the document, then the editor saves at once');
  for (final kb in [5, 40, _referenceSize ~/ 1000]) {
    for (final formatted in [false, true]) {
      final text = markdownOf(kb * 1000, Random(kb));
      final spans = formatted ? [for (var at = 0; at + 12 < text.length; at += 90) TextSpanAttribute(start: at, end: at + 12, type: AttributeType.color, value: '${0xFF000000 + (at * 7919) % 0xFFFFFF}')] : <TextSpanAttribute>[];
      final id = await l.repo.createNote(title: 'Save of $kb KB');
      await l.repo.saveNote(NoteData(id: id, title: 'd', background: PageBackground.blank, pageFormat: PageFormat.a4, documentText: text, documentSpans: spans));
      final what = 'document of $kb KB${formatted ? ' with ${spans.length} formatted stretches' : ''}';
      final work = await _openForWork(l, id);
      if (work == null) {
        say(what, 'no editor');
        continue;
      }
      final c = work.text;
      await work.handle.saveNow();
      var n = 0;
      void type() {
        final at = c.text.length ~/ 2;
        c.value = TextEditingValue(text: c.text.replaceRange(at, at, '${n++ % 10}'), selection: TextSelection.collapsed(offset: at + 1));
      }
      await stalledRuns('saveNow: $what', (_) => work.handle.saveNow(), before: () async => type());
      // the database alone, with the text as the editor would hand it over
      final note = (await l.repo.loadNote(id))!;
      await stalledRuns('repo.saveNote only: $what', (i) {
        note.documentText = '${note.documentText}${i % 10}';
        return l.repo.saveNote(note);
      });
    }
  }
  await _mount(const SizedBox());
}

/// What making a file of a note costs: a PDF, pictures, a .uninote file, a Word file, a web page.
Future<void> _exports(_Library l) async {
  say('--- exporting', 'the real editor, the screen stood still is the most the main isolate was busy at a stretch');
  final dir = await Directory(p('exports-$pid')).create(recursive: true);
  final tmp = await Directory(p('files-$pid')).create(recursive: true);
  final files = NoteFileService(l.repo, supportDirectory: () async => tmp);

  Future<void> pdf(String what, String id, {int runs = 2}) async {
    final work = await _openForWork(l, id, document: false);
    if (work == null) return say('PDF of $what', 'no editor');
    final out = '${dir.path}/$id.pdf';
    String? problem;
    await stalledRuns('PDF of $what', (_) async => problem = await work.handle.exportPdfTo(out), runs: runs);
    say('   ... the file', problem != null ? 'FAILED: $problem' : '${(File(out).lengthSync() / 1024).toStringAsFixed(0)} KB');
  }

  Future<void> pictures(String what, String id) async {
    final work = await _openForWork(l, id, document: false);
    if (work == null) return say('pictures of $what', 'no editor');
    final folder = await Directory('${dir.path}/pics-$id').create(recursive: true);
    String? said;
    await stalledRuns('picture of the pages of $what (web size)', (_) async => said = await (work.editor as ImageExporter).exportImagesInto(folder.path, ImagePreset.web), runs: 2);
    say('   ... said', '$said');
  }

  final r = Random(11);
  final documents = <int, String>{};
  for (final kb in [5, 40, _referenceSize ~/ 1000]) {
    final id = await l.repo.createNote(title: 'Export of $kb KB');
    await l.repo.saveNote(NoteData(id: id, title: 'd', background: PageBackground.blank, pageFormat: PageFormat.a4, documentText: markdownOf(kb * 1000, r)));
    documents[kb] = id;
  }
  for (final e in documents.entries) {
    await pdf('a document of ${e.key} KB', e.value);
  }
  await pdf('a note of ${_heavyPages * _heavyPerPage} lines on $_heavyPages pages', l.heavy, runs: 1);
  await pdf('one page of $_pageStrokes lines', l.onePage, runs: 1);
  // the text under the handwriting (see pdf_ink_text.dart): off, on with nothing read yet, on with every block read
  await l.repo.settings.set(pdfInkTextSetting, '0');
  await pdf('the heavy note, text under the writing OFF', l.heavy, runs: 2);
  await pdf('one page of $_pageStrokes lines, text under the writing OFF', l.onePage, runs: 2);
  await l.repo.settings.set(pdfInkTextSetting, '1');
  await pdf('the heavy note, text under the writing on, nothing read', l.heavy, runs: 2);
  await pdf('one page of $_pageStrokes lines, text under the writing on, nothing read', l.onePage, runs: 2);
  for (final id in [l.heavy, l.onePage]) {
    final note = (await l.repo.loadNote(id))!;
    final read = <InkText>[];
    for (final e in note.strokes.entries) {
      for (final c in clusterStrokes(e.key, e.value)) {
        read.add(InkText(key: c.key, page: e.key, text: 'lorem ipsum dolor\nsit amet consectetur', bounds: c.bounds));
      }
    }
    await l.repo.text.saveInkText(id, read, {for (final t in read) t.key});
    say('blocks of writing read in ${id == l.heavy ? 'the heavy note' : 'the page of $_pageStrokes lines'}', '${read.length}');
  }
  await pdf('the heavy note, text under the writing on, all read', l.heavy, runs: 2);
  await pdf('one page of $_pageStrokes lines, text under the writing on, all read', l.onePage, runs: 2);
  await pictures('the note of ${_heavyPages * _heavyPerPage} lines', l.heavy);
  await stalledRuns('.uninote file of the heavy note', (_) async => await files.exportBytes(l.heavy), runs: 3);
  await stalledRuns('.uninote file of a document of $_referenceSize bytes', (_) async => await files.exportBytes(documents[_referenceSize ~/ 1000]!), runs: 3);

  for (final e in documents.entries) {
    final note = (await l.repo.loadNote(e.value))!;
    final controller = RichInlineTextController()..value = TextEditingValue(text: note.documentText);
    final attributes = controller.attributes;
    final pages = DocumentPages(date: DateTime(2026, 11, 3));
    await stalledRuns('Word file of a document of ${e.key} KB', (_) async => documentDocx(note.documentText, attributes, pages), runs: 3);
    await stalledRuns('web page of a document of ${e.key} KB', (_) async => documentHtml(note.documentText, attributes, title: 'x'), runs: 3);
    await stalledRuns('PDF of a document of ${e.key} KB, from the text alone', (_) async => await documentPdf(controller, pages), runs: 2);
  }
  await _mount(const SizedBox());
}

String p(String name) => '${Platform.environment['PROFILE_DIR']}/$name';

void _code(_Library l) {
  final r = Random(7);
  for (final size in [5000, 50000, 200000]) {
    final text = markdownOf(size, r);
    timedSync('parseMarkdown ${size ~/ 1000} KB', () => parseMarkdown(text));
  }
  final strokes = [for (var i = 0; i < _pageStrokes; i++) _pen(r, 20 + r.nextDouble() * 500, 20 + r.nextDouble() * 760, 25)];
  timedSync('stamp of 5000 lines', () {
    var h = 0;
    for (final s in strokes) {
      h ^= s.stamp;
    }
    if (h == 1) stdout.write('');
  });
  timedSync('InkLayerPainter built for 5000 lines', () => InkLayerPainter(strokes: strokes));

  // what a key costs in the reference document besides laying the text out and drawing it
  var text = markdownOf(_referenceSize, r);
  var parsed = ParsedText(text, parseMarkdown(text));
  var issues = grammarIssues(text, blocks: parsed.blocks);
  say('the reference document', '${text.length} characters, ${parsed.blocks.length} blocks');
  timedSync('all of it parsed', () => parseMarkdown(text), runs: 9);
  var at = _referenceSize ~/ 2;
  at = text.indexOf('\n\n', at) - 20;
  final parse = <int>[], grammar = <int>[], words = <int>[], derived = <int>[];
  for (var i = 0; i < 200; i++) {
    final now = text.replaceRange(at + i, at + i, 'a');
    final sw = Stopwatch()..start();
    final made = reparsed(text, parsed.blocks, now);
    parse.add(sw.elapsedMicroseconds);
    sw
      ..reset()
      ..start();
    issues = grammarIssuesAfter(made, text, issues);
    grammar.add(sw.elapsedMicroseconds);
    sw
      ..reset()
      ..start();
    wordCount(now, blocks: made.blocks);
    words.add(sw.elapsedMicroseconds);
    sw
      ..reset()
      ..start();
    footnoteNumbers(made.blocks);
    documentStyles(made.blocks);
    captionNumbers(made.blocks);
    crossReferences(made.blocks, figure: 'Figure', table: 'Table');
    derived.add(sw.elapsedMicroseconds);
    text = now;
    parsed = made;
  }
  say('a key: only its block parsed, the rest moved', _stats(parse));
  say('a key: grammar around it', _stats(grammar));
  say('a key: words', _stats(words));
  say('a key: numbering of notes, figures and styles', _stats(derived));
}

// ---- where the time goes

const _afterStart = Duration(seconds: 24);

/// The Dart functions the main isolate spent its time in during [body], from the VM's own sampling profiler: the time in a function
/// itself and in what it called. With PROFILE_CPU=1; a profile build has the names of the functions.
Future<void> sampled(String what, Future<void> Function() body) => _sampled(what, body, frames: true);

/// [sampled] for all the main isolate did, not only its frames.
Future<void> sampledAll(String what, Future<void> Function() body) => _sampled(what, body, frames: false);

Future<void> _sampled(String what, Future<void> Function() body, {required bool frames}) async {
  final uri = Platform.environment['PROFILE_CPU'] == '1' ? (await developer.Service.getInfo()).serverWebSocketUri : null;
  if (uri == null) return body();
  final socket = await WebSocket.connect(uri.toString());
  final replies = socket.asBroadcastStream();
  var id = 0;
  Future<Map<String, dynamic>> call(String method, Map<String, Object?> params) async {
    final mine = '${++id}';
    socket.add(jsonEncode({'jsonrpc': '2.0', 'id': mine, 'method': method, 'params': params}));
    final reply = await replies.map((m) => jsonDecode(m as String) as Map<String, dynamic>).firstWhere((m) => m['id'] == mine);
    if (reply['result'] == null) throw StateError('$method: ${reply['error']}');
    return reply['result'] as Map<String, dynamic>;
  }

  final isolate = developer.Service.getIsolateId(Isolate.current)!;
  await call('clearCpuSamples', {'isolateId': isolate});
  await body();
  final r = await call('getCpuSamples', {'isolateId': isolate, 'timeOriginMicros': 0, 'timeExtentMicros': 1 << 53});
  await socket.close();
  final names = [
    for (final f in r['functions'] as List)
      () {
        final fn = (f as Map)['function'] as Map;
        final owner = fn['owner'];
        return '${owner is Map ? '${owner['name']}.' : ''}${fn['name']}';
      }(),
  ];
  final self = <String, int>{}, all = <String, int>{};
  final samples = [
    for (final s in r['samples'] as List)
      if (!frames || ((s as Map)['stack'] as List).cast<int>().any((i) => names[i].contains('_drawFrame') || names[i].contains('_beginFrame') || names[i].contains('handleBeginFrame'))) s,
  ];
  for (final s in samples) {
    final stack = ((s as Map)['stack'] as List).cast<int>();
    if (stack.isEmpty) continue;
    // (the engine's own code has no name: it is counted to the Dart function that called it)
    final caller = stack.map((i) => names[i]).firstWhere((n) => !n.contains('[Native]') && !n.contains('[Stub]') && !n.startsWith('.[') , orElse: () => 'native');
    self.update(caller, (v) => v + 1, ifAbsent: () => 1);
    for (final n in {for (final i in stack) names[i]}) {
      all.update(n, (v) => v + 1, ifAbsent: () => 1);
    }
  }
  String top(Map<String, int> m, int n) => (m.entries.toList()..sort((a, b) => b.value - a.value)).take(n).map((e) => '\n      ${(e.value * 100 / samples.length).toStringAsFixed(1).padLeft(5)}%  ${e.key}').join();
  say('$what: cpu, itself (of ${samples.length} samples)', top(self, 18));
  // (the frames everything goes through say nothing: what is left is the phases of a frame, and this app's own code)
  bool telling(String n) => RegExp(r'^(PipelineOwner\.flush|BuildOwner\.buildScope|RenderParagraph\.|RenderEditable\.|TextPainter\.|SemanticsOwner\.|TextSpan\.|InlineSpan)').hasMatch(n) || !RegExp(r'^(_?Render|RenderObject|_MixinApplication|ChildLayoutHelper|Element|ComponentElement|StatelessElement|StatefulElement|SingleChildRenderObjectElement|MultiChildRenderObjectElement|RenderObjectElement|\[Native\]|_?[A-Z]\w*Element\.|Listener|_Layout|_rebuild|runLayout|invokeLayout|updateChild|PipelineOwner|Scheduler|_MixinApp|_invoke|_rootRun|_Timer|_Future|_Completer|_Zone|_drawFrame|_beginFrame|Future|main|_startMicrotask|_microtask|_Async)').hasMatch(n);
  say('$what: cpu, with what it calls', top(Map.fromEntries(all.entries.where((e) => telling(e.key))), 40));
}

// ---- real frames

final _frames = <FrameTiming>[];
List<int> builds = const [];
List<int> rasters = const [];

void _listenFrames() => SchedulerBinding.instance.addTimingsCallback(_frames.addAll);

Future<void> _settle([int ms = 400]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  SchedulerBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
}

/// Says how long the frames of [body] took.
Future<void> frames(String what, Future<void> Function() body) async {
  await _settle();
  _frames.clear();
  final sw = Stopwatch()..start();
  await body();
  sw.stop();
  await _settle(300);
  final b = builds = [for (final f in _frames) f.buildDuration.inMicroseconds];
  final s = rasters = [for (final f in _frames) f.rasterDuration.inMicroseconds];
  final over = b.where((v) => v > 8000).length;
  say('$what: build', '${_stats(b)}   over 8 ms: $over');
  say('$what: raster', _stats(s));
  // (how often a frame came: the time from one vsync to the next, while frames were wanted)
  final starts = [for (final f in _frames) f.timestampInMicroseconds(FramePhase.vsyncStart)]..sort();
  final gaps = [for (var i = 1; i < starts.length; i++) starts[i] - starts[i - 1]];
  if (gaps.isNotEmpty) {
    final mid = ([...gaps]..sort())[gaps.length ~/ 2];
    say('$what: frames', '${_frames.length} in ${sw.elapsedMilliseconds} ms, ${(1e6 / mid).toStringAsFixed(0)} a second at the median gap (${_stats(gaps)})');
  }
}

ScrollPosition? _longScroll() {
  ScrollPosition? found;
  _find((e) {
    if (e.widget is! Scrollable) return false;
    final pos = ((e as StatefulElement).state as ScrollableState).position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 500) return false;
    found = pos;
    return true;
  });
  return found;
}

Element? _find(bool Function(Element) test) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    if (test(e)) {
      found = e;
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

/// Taps the text [label] on the screen.
Future<bool> _tapText(String label) async {
  final e = _find((e) => e.widget is RichText && (e.widget as RichText).text.toPlainText() == label);
  final box = e?.renderObject as RenderBox?;
  if (box == null) return false;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  GestureBinding.instance
    ..handlePointerEvent(PointerDownEvent(pointer: 900, position: at, buttons: kPrimaryButton))
    ..handlePointerEvent(PointerUpEvent(pointer: 900, position: at));
  await _settle();
  return true;
}

Future<void> _mount(Widget w) async {
  runApp(MaterialApp(home: w));
  await _settle();
}

Future<int> _waitFor(bool Function() ready) async {
  final sw = Stopwatch()..start();
  while (!ready() && sw.elapsedMilliseconds < 30000) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    SchedulerBinding.instance.scheduleFrame();
  }
  return sw.elapsedMilliseconds;
}

Widget _editor(_Library l, String id) => FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: l.repo, stylus: StylusSettings.inMemory());

Future<void> _typing(_Library l, String id, String what) async {
  await _mount(const SizedBox());
  final started = Stopwatch()..start();
  _frames.clear();
  await sampled('$what: opening', () => stalled('$what: opening', () async {
    await _mount(_editor(l, id));
  }));
  await _settle(300);
  final slowest = [..._frames]..sort((x, y) => y.buildDuration.compareTo(x.buildDuration));
  say('$what: its slowest frames', slowest.take(5).map((f) => '${f.buildDuration.inMilliseconds} + ${f.rasterDuration.inMilliseconds} ms').join(', '));
  var sheets = 0;
  _find((e) {
    if (e.widget.key case ValueKey<String>(:final value) when value.startsWith('document-sheet-')) sheets++;
    return false;
  });
  say('$what: opened', '${started.elapsedMilliseconds} ms, $sheets sheets');
  // (the rest of the text comes in after the first of it is on screen)
  var was = -1;
  while (sheets != was) {
    was = sheets;
    await _settle(300);
    sheets = 0;
    _find((e) {
      if (e.widget.key case ValueKey<String>(:final value) when value.startsWith('document-sheet-')) sheets++;
      return false;
    });
  }
  say('$what: all sheets there', '${started.elapsedMilliseconds - 300} ms, $sheets sheets');
  final entering = Stopwatch()..start();
  await sampled('$what: going to Document', () => stalled('$what: going to Document', () async {
    await _tapText('Document');
    await _waitFor(() => _find((e) => e.widget is BlockEditor) != null);
  }));
  say('$what: in Document', '${entering.elapsedMilliseconds} ms');
  await _typingInBlocks(what);
}

/// Types in the block editor as a keyboard does: a change of the stretch of the text the keyboard was told of, half way down the document.
Future<void> _typingInBlocks(String what) async {
  final e = _find((e) => e.widget is BlockEditor);
  if (e == null) return say('$what: typing', 'no block editor on screen');
  final state = (e as StatefulElement).state as BlockEditorState;
  final c = state.widget.controller;
  state.widget.focusNode.requestFocus();
  await _settle(300);
  c.selection = TextSelection.collapsed(offset: c.text.indexOf('\n', c.text.length ~/ 2));
  await _settle(600);
  final keys = <int>[], input = <int>[];
  await sampledAll('$what: typing', () => frames('$what: typing 60 keys', () async {
    for (var i = 0; i < 60; i++) {
      final v = state.currentTextEditingValue!;
      final at = v.selection.start;
      final sw = Stopwatch()..start();
      state.updateEditingValueWithDeltas([
        TextEditingDeltaInsertion(oldText: v.text, textInserted: i % 6 == 5 ? ' ' : 'a', insertionOffset: at, selection: TextSelection.collapsed(offset: at + 1), composing: TextRange.empty),
      ]);
      input.add(sw.elapsedMicroseconds);
      await WidgetsBinding.instance.endOfFrame;
      keys.add(sw.elapsedMicroseconds);
    }
  }));
  say('$what: a key, to the end of its frame', _stats(keys));
  say('$what: a key, before its frame', _stats(input));
  if (_tablet) {
    double middle(List<int> v) => ([...v]..sort())[v.length ~/ 2] / 1000 * _tabletFactor;
    final i = middle(input), b = middle(builds), r = middle(rasters);
    say('$what: on the reference tablet', 'about ${(i + b + r).toStringAsFixed(0)} ms for a key: ${i.toStringAsFixed(0)} input, ${b.toStringAsFixed(0)} build, ${r.toStringAsFixed(0)} raster');
  }
  final measuring = Stopwatch()..start();
  await _waitFor(() => state.allMeasured);
  say('$what: all lines measured', '${measuring.elapsedMilliseconds} ms after the last key');
  final scroll = _longScroll();
  if (scroll != null) {
    await frames('$what: scrolling', () async {
      for (var i = 0; i < 200; i++) {
        scroll.jumpTo((scroll.pixels + (i < 100 ? 60 : -60)).clamp(0.0, scroll.maxScrollExtent));
        await WidgetsBinding.instance.endOfFrame;
      }
    });
    await frames('$what: jumping about', () async {
      final r = Random(1);
      for (var i = 0; i < 30; i++) {
        scroll.jumpTo(r.nextDouble() * scroll.maxScrollExtent);
        await WidgetsBinding.instance.endOfFrame;
      }
    });
  }

}

/// The written document that is only read is in pieces: they must take the room one paragraph with all of it takes, in the real fonts.
Future<void> _pieces(_Library l) async {
  final text = (await l.repo.loadNote(l.document))!.documentText;
  final c = LiveMarkdownController()..text = text;
  final key = GlobalKey();
  double height() => (key.currentContext!.findRenderObject()! as RenderBox).size.height;
  Widget sized(Widget child) => Align(alignment: Alignment.topLeft, child: SingleChildScrollView(child: SizedBox(width: 700, child: KeyedSubtree(key: key, child: child))));
  await _mount(sized(LiveMarkdownView(controller: c, fontSize: 16, references: false)));
  final inPieces = height();
  await _mount(sized(Builder(builder: (context) => RichText(strutStyle: StrutStyle.disabled, text: liveMarkdownSpan(context, c, documentTextStyle(16), width: LiveMarkdownView.textWidth(700))))));
  say('the document in pieces and in one paragraph', '${inPieces.toStringAsFixed(1)} and ${height().toStringAsFixed(1)} high');
}

Future<void> _ink(_Library l) async {
  for (final (id, what) in [(l.onePage, 'page of 5000 lines'), (l.heavy, 'heavy note')]) {
    await _mount(const SizedBox());
    final started = Stopwatch()..start();
    await _mount(_editor(l, id));
    await _waitFor(() => _find((e) => e.widget is CustomPaint && (e.widget as CustomPaint).painter is InkLayerPainter) != null);
    say('$what: opened', '${started.elapsedMilliseconds} ms');
    await _settle(800);
    await frames('$what: scrolling', () async {
      final pos = _longScroll();
      if (pos == null) return;
      for (var i = 0; i < 120; i++) {
        pos.jumpTo(min(pos.maxScrollExtent, i * 24.0));
        await WidgetsBinding.instance.endOfFrame;
      }
      pos.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
    });
    if (!await _tapText('Draw')) say('$what: writing', 'could not find Draw');
    final page = _find((e) => e.widget is CustomPaint && (e.widget as CustomPaint).painter is InkLayerPainter);
    final box = page?.renderObject as RenderBox?;
    if (box == null) continue;
    final origin = box.localToGlobal(const Offset(120, 160));
    await frames('$what: writing 5 lines of 120 moves', () async {
      for (var n = 0; n < 5; n++) {
        var pos = origin + Offset(0, n * 30.0);
        GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 800 + n, position: pos, kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
        await WidgetsBinding.instance.endOfFrame;
        for (var i = 1; i <= 120; i++) {
          pos = origin + Offset(i * 2.0, n * 30.0 + 8 * sin(i / 6));
          GestureBinding.instance.handlePointerEvent(PointerMoveEvent(pointer: 800 + n, position: pos, kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
          await WidgetsBinding.instance.endOfFrame;
        }
        GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 800 + n, position: pos, kind: PointerDeviceKind.stylus));
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    });
    await Future<void>.delayed(const Duration(seconds: 2)); // (its autosave)
  }
}

Future<void> _lists(_Library l) async {
  final started = Stopwatch()..start();
  await _mount(FolderView(repository: l.repo, onOpenNote: (_) {}));
  await _waitFor(() => _longScroll() != null);
  say('folder view: opened', '${started.elapsedMilliseconds} ms');
  await frames('folder view: scrolling', () async {
    final pos = _longScroll();
    if (pos == null) return;
    for (var i = 0; i < 120; i++) {
      pos.jumpTo(min(pos.maxScrollExtent, i * 40.0));
      await WidgetsBinding.instance.endOfFrame;
    }
  });
}

// ---- scrolling through an imported PDF

/// A PDF of [pages] pages of one [kind] in PROFILE_DIR (made once): `text` is dense text (about 750 words a page), `scan` a full-page
/// JPEG of 200 dpi on each page, `vector` 3000 separately stroked lines a page.
Future<File> _pdfFile(String dir, String kind, int pages) async {
  final file = File('$dir/pdf-$kind-$pages.pdf');
  if (file.existsSync()) return file;
  final r = Random(7);
  final doc = pw.Document(compress: kind != 'scan');
  final scans = <Uint8List>[];
  if (kind == 'scan') {
    for (var v = 0; v < 6; v++) {
      final image = img.Image(width: 1654, height: 2339);
      for (final px in image) {
        final n = 200 + r.nextInt(40);
        px
          ..r = n
          ..g = n
          ..b = n - 8;
      }
      for (var i = 0; i < 40; i++) {
        img.drawLine(image, x1: 100, y1: 150 + i * 50 + v, x2: 1500, y2: 150 + i * 50 + v, color: img.ColorRgb8(20, 20, 20), thickness: 3);
      }
      scans.add(Uint8List.fromList(img.encodeJpg(image, quality: 80)));
    }
  }
  for (var p = 0; p < pages; p++) {
    doc.addPage(pw.Page(
      pageFormat: pdf.PdfPageFormat.a4,
      margin: kind == 'text' ? const pw.EdgeInsets.all(40) : pw.EdgeInsets.zero,
      build: (_) => switch (kind) {
        'scan' => pw.Image(pw.MemoryImage(scans[p % scans.length]), fit: pw.BoxFit.fill),
        'vector' => pw.CustomPaint(
            size: const pdf.PdfPoint(595, 842),
            painter: (canvas, size) {
              final lr = Random(p);
              for (var i = 0; i < 3000; i++) {
                final x = lr.nextDouble() * size.x, y = lr.nextDouble() * size.y;
                canvas
                  ..setStrokeColor(pdf.PdfColor(lr.nextDouble(), lr.nextDouble(), lr.nextDouble()))
                  ..setLineWidth(0.5 + lr.nextDouble() * 2)
                  ..moveTo(x, y)
                  ..curveTo(x + 20, y + 30, x - 15, y + 40, x + lr.nextDouble() * 60 - 30, y + lr.nextDouble() * 60 - 30)
                  ..strokePath();
              }
            },
          ),
        _ => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Page ${p + 1}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            for (var l = 0; l < 54; l++) pw.Text(_sentence(r, 14), style: const pw.TextStyle(fontSize: 9)),
          ]),
      },
    ));
  }
  file.writeAsBytesSync(await doc.save());
  return file;
}

/// A note of the PDF [file] (made once).
Future<String> _pdfNote(_Library l, String kind, File file, int pages) async {
  final key = 'profile_pdf_${kind}_$pages';
  final known = await l.repo.settings.get(key);
  if (known != null && await l.repo.loadNote(known) != null) return known;
  final id = await l.repo.createNote(title: 'PDF $kind');
  final note = (await l.repo.loadNote(id))!;
  note.pdfName = file.uri.pathSegments.last;
  note.pdfPath = file.path;
  note.pdfPageCount = pages;
  await l.repo.saveNote(note);
  await l.repo.settings.set(key, id);
  return id;
}

/// Whether a spinner is on the screen: a page whose picture is not there yet.
bool _blankOnScreen() {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  return _find((e) {
        if (e.widget is! CircularProgressIndicator) return false;
        final box = e.renderObject as RenderBox?;
        if (box == null || !box.attached || !box.hasSize) return false;
        return screen.overlaps(box.localToGlobal(Offset.zero) & box.size);
      }) !=
      null;
}

/// How long until every page on the screen has its picture.
Future<int> _untilPagesThere() async {
  await WidgetsBinding.instance.endOfFrame;
  return _waitFor(() => !_blankOnScreen());
}

/// Reading, flinging and jumping through PDFs of dense text, scans and vector drawings, in the real editor: the frames, how long the
/// screen stood still, how often a page was blank on screen, and how long the page landed on took to appear.
Future<void> _pdfScroll(_Library l, String dir) async {
  final display = WidgetsBinding.instance.platformDispatcher.views.first.display;
  say('the display, as the engine has it', '${display.refreshRate.toStringAsFixed(1)} Hz, ${display.size.width.toInt()}x${display.size.height.toInt()} at ${display.devicePixelRatio}');
  for (final (kind, pages) in [('text', 60), ('scan', 40), ('vector', 40)]) {
    final file = await _pdfFile(dir, kind, pages);
    final id = await _pdfNote(l, kind, file, pages);
    final what = 'PDF of $kind, $pages pages';
    await _mount(const SizedBox());
    final rssBefore = ProcessInfo.currentRss;
    final opened = Stopwatch()..start();
    runApp(MaterialApp(home: _editor(l, id)));
    await _waitFor(() => _find((e) => e.widget is RawImage && (e.widget as RawImage).image != null) != null);
    say('$what: first page shown', '${opened.elapsedMilliseconds} ms');
    await _settle(2500); // (what is read ahead)
    final pos = _longScroll();
    if (pos == null) {
      say(what, 'no scrolling list');
      continue;
    }
    var looked = 0, blank = 0;
    await frames('$what: reading (25 px a frame)', () => stalled('$what: reading, the main isolate', () async {
          for (var i = 0; i < 360; i++) {
            pos.jumpTo(min(pos.maxScrollExtent, pos.pixels + 25));
            await WidgetsBinding.instance.endOfFrame;
            if (i % 6 == 0) {
              looked++;
              if (_blankOnScreen()) blank++;
            }
          }
        }));
    say('$what: reading, a page blank on screen', '$blank of $looked looks');
    await _untilPagesThere();
    await _settle(1000);
    final page = pos.maxScrollExtent / pages;
    await frames('$what: a fling over 15 pages', () => stalled('$what: a fling, the main isolate', () async {
          await pos.animateTo(min(pos.maxScrollExtent, pos.pixels + 15 * page), duration: const Duration(milliseconds: 1200), curve: Curves.decelerate);
        }));
    say('$what: after the fling, until the page is there', '${await _untilPagesThere()} ms');
    await _settle(1000);
    final r = Random(3);
    await sampledAll('$what: jumps', () => frames('$what: 15 jumps (the scrollbar)', () => stalled('$what: jumps, the main isolate', () async {
          for (var i = 0; i < 15; i++) {
            pos.jumpTo(r.nextDouble() * pos.maxScrollExtent);
            await WidgetsBinding.instance.endOfFrame;
            await WidgetsBinding.instance.endOfFrame;
          }
          await _untilPagesThere();
          await _settle(1500); // (the words of the pages come after their pictures)
        })));
    say('$what: after the jumps, until the page is there', '${await _untilPagesThere()} ms');
    await _settle(1500);
    say('$what: memory', '${(rssBefore >> 20)} MB before, ${ProcessInfo.currentRss >> 20} MB now');
  }
}

/// The app as it runs with no screen reader.
class _NoSemantics extends WidgetsFlutterBinding {
  @override
  bool get semanticsEnabled => false;
}

final _tablet = Platform.environment['PROFILE_TABLET'] == '1';
const _tabletFactor = 12;

Future<void> main() async {
  if (_tablet) _NoSemantics();
  WidgetsFlutterBinding.ensureInitialized();
  final dir = Platform.environment['PROFILE_DIR'];
  if (dir == null || dir.isEmpty) {
    stderr.writeln('Set PROFILE_DIR to a folder of its own (see the top of this file).');
    exit(2);
  }
  final only = (Platform.environment['PROFILE_ONLY'] ?? 'data,code,frames').split(',');
  // the real start of the app: on a copy of the database, in a folder of its own (see the top of this file)
  if (only.contains('startup')) {
    final data = Platform.environment['XDG_DATA_HOME'] ?? '';
    if (!data.startsWith(dir)) {
      stderr.writeln('The real start of the app opens the notes in XDG_DATA_HOME: set it to a folder inside PROFILE_DIR.');
      exit(2);
    }
    final begun = int.tryParse(Platform.environment['PROFILE_T0'] ?? '');
    final before = begun == null ? 0 : DateTime.now().microsecondsSinceEpoch - begun;
    final sw = Stopwatch()..start();
    await sampled('start', () async {
      app.main();
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    });
    say('process to main', '${(before / 1000).toStringAsFixed(0)} ms');
    say('main to the first frame', '${sw.elapsedMilliseconds} ms');
    say('memory then', '${ProcessInfo.currentRss >> 20} MB');
    // what starts a moment after: the tick, the purge of the trash, the indexers, the previews of the notes
    await sampledAll('the first ${_afterStart.inSeconds} s after the start', () async {
      final watch = Stopwatch()..start();
      while (watch.elapsed < _afterStart) {
        await Future<void>.delayed(const Duration(seconds: 2));
        say('memory at ${watch.elapsed.inSeconds} s', '${ProcessInfo.currentRss >> 20} MB');
      }
    });
    exit(0);
  }
  await Directory(dir).create(recursive: true);
  AppDatabase.initFfi();
  final path = '$dir/notes.db';
  if (Platform.environment['PROFILE_FRESH'] == '1') {
    for (final s in ['', '-wal', '-shm']) {
      final f = File('$path$s');
      if (f.existsSync()) f.deleteSync();
    }
  }
  try {
    final l = await _seed(path);
    if (only.contains('data')) await _data(l);
    if (only.contains('code')) _code(l);
    if (only.contains('frames')) {
      _listenFrames();
      await _mount(const SizedBox());
      await _pieces(l);
      if (only.contains('sweep')) {
        for (final kb in [5, 40, _referenceSize ~/ 1000]) {
          final id = await l.repo.createNote(title: 'Document of $kb KB');
          await l.repo.saveNote(NoteData(id: id, title: 'd', background: PageBackground.blank, pageFormat: PageFormat.a4, documentText: markdownOf(kb * 1000, Random(kb))));
          await _typing(l, id, 'document of $kb KB');
        }
      } else {
        await _typing(l, l.document, 'long document');
      }
      if (!only.contains('doconly')) {
        await _ink(l);
        await _lists(l);
      }
    }
    if (only.contains('save')) await _saves(l);
    if (only.contains('export')) await _exports(l);
    if (only.contains('pdfscroll')) {
      _listenFrames();
      await _pdfScroll(l, dir);
    }
  } catch (e, stack) {
    say('FAILED', '$e\n$stack');
  }
  File('$dir/results-${DateTime.now().millisecondsSinceEpoch}.txt').writeAsStringSync(_results.join('\n'));
  exit(0);
}

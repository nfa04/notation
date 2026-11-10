import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/export/ora_export.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

DrawingStroke line({String id = 'a', Color color = const Color(0xFFFF0000), String layer = baseLayerId}) =>
    DrawingStroke(id: id, color: color, width: 8, points: [for (var i = 0; i <= 5; i++) Offset(10.0 + i * 20, 50)], layer: layer);

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the stack lists the top layer first, with groups as stacks and the blend modes by their names', () {
    final layers = LayerStack(const [
      NoteLayer(baseLayerId, 'Ink'),
      NoteLayer('g', 'Colours', isGroup: true, opacity: 0.5),
      NoteLayer('a', 'Flat', group: 'g'),
      NoteLayer('b', 'Shade <1>', group: 'g', blend: LayerBlend.multiply, visible: false),
      NoteLayer('c', 'Top', opacity: 0.25),
    ]);
    final xml = oraStackXml(width: 100, height: 80, layers: layers, srcOf: (l) => 'data/${l.id}.png', paper: 'data/paper.png');
    final doc = XmlDocument.parse(xml);
    expect(doc.rootElement.getAttribute('w'), '100');
    final root = doc.rootElement.findElements('stack').single;
    final names = [for (final e in root.childElements) e.getAttribute('name')];
    expect(names, ['Top', 'Colours', 'Ink', 'Paper']);
    final group = root.childElements.elementAt(1);
    expect(group.name.local, 'stack');
    expect(group.getAttribute('opacity'), '0.500');
    expect([for (final e in group.childElements) e.getAttribute('name')], ['Shade <1>', 'Flat']);
    expect(group.childElements.first.getAttribute('composite-op'), 'svg:multiply');
    expect(group.childElements.first.getAttribute('visibility'), 'hidden');
    expect(root.childElements.first.getAttribute('opacity'), '0.250');
  });

  group('the page from the editor', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ora'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('the button writes an archive with a picture for each layer', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final NoteData note = (await repo.loadNote(id))!;
        note.layers = LayerStack(const [NoteLayer(baseLayerId, 'Ink'), NoteLayer('t', 'Colour', blend: LayerBlend.screen), NoteLayer('e', 'Empty')]);
        note.strokes[0] = [line(), line(id: 'b', color: const Color(0xFF0000FF), layer: 't')];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-ora-button')), findsOneWidget);

      String? problem = 'not run';
      var done = false;
      final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
      (state.exportOraTo('${dir.path}/a.ora') as Future<String?>).then((r) {
        problem = r;
        done = true;
      });
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done, isTrue);
      expect(problem, isNull);
      final archive = ZipDecoder().decodeBytes(File('${dir.path}/a.ora').readAsBytesSync());
      expect(archive.files.first.name, 'mimetype');
      expect(String.fromCharCodes(archive.files.first.content as List<int>), 'image/openraster');
      final names = [for (final f in archive.files) f.name];
      expect(names, containsAll(['stack.xml', 'mergedimage.png', 'Thumbnails/thumbnail.png', 'data/paper.png', 'data/layer1.png', 'data/layer2.png', 'data/layer3.png']));
      final xml = XmlDocument.parse(String.fromCharCodes(archive.findFile('stack.xml')!.content as List<int>));
      final layers = xml.rootElement.findElements('stack').single.childElements.toList();
      expect([for (final l in layers) l.getAttribute('name')], ['Empty', 'Colour', 'Ink', 'Paper']);
      expect(layers[1].getAttribute('composite-op'), 'svg:screen');
      final w = int.parse(xml.rootElement.getAttribute('w')!);
      expect(w, 1000);
      // a layer with lines is a picture the size of the page, an empty one a single pixel
      int widthOf(String f) {
        final b = archive.findFile(f)!.content as List<int>;
        return (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      }

      expect(widthOf('data/layer1.png'), w);
      expect(widthOf('data/layer2.png'), w);
      expect(widthOf('data/layer3.png'), 1);
      expect(widthOf('Thumbnails/thumbnail.png'), lessThanOrEqualTo(256), reason: 'a small picture (the long side is 256)');
    });
  });
}

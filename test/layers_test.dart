import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke stroke(String layer, {double y = 50, Color color = Colors.black, double width = 20, String? id}) =>
    DrawingStroke(id: id, color: color, width: width, points: [for (var i = 0; i < 8; i++) Offset(20.0 + i * 10, y)], layer: layer);

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the stack of layers', () {
    test('a note with no layers has the plain stack: the base layer, shown, unlocked and opaque', () {
      expect(LayerStack.plain.isPlain, isTrue);
      expect(LayerStack.plain.length, 1);
      expect(LayerStack.plain.toJsonText(), isNull, reason: 'nothing is kept for it: notes from before layers are as they were');
      expect(LayerStack.fromJsonText(null).isPlain, isTrue);
      expect(LayerStack.fromJsonText('').isPlain, isTrue);
      expect(LayerStack.fromJsonText('not json').isPlain, isTrue);
      expect(LayerStack.fromJsonText('{"a":1}').isPlain, isTrue);
      expect(LayerStack.fromJsonText('[1,"x",{"n":"no id"}]').isPlain, isTrue);
    });

    test('the base layer is always there, once, and the stack is kept as written', () {
      final s = LayerStack(const [NoteLayer('a', 'Sky'), NoteLayer('a', 'Again'), NoteLayer('b', 'Sea', visible: false, locked: true, opacity: 0.4)]);
      expect(s.layers.map((l) => l.id), [baseLayerId, 'a', 'b'], reason: 'the base layer went to the bottom, and a repeated id is kept once');
      expect(s.layers[1].name, 'Sky');
      final back = LayerStack.fromJsonText(s.toJsonText());
      expect(back, s);
      expect(back.layers[2].visible, isFalse);
      expect(back.layers[2].locked, isTrue);
      expect(back.layers[2].opacity, 0.4);
      expect(LayerStack.fromJsonText('[{"id":"x","n":"X","o":7}]').byId('x').opacity, 1, reason: 'an opacity out of range is kept in range');
    });

    test('a line on a layer that is not there is on the base layer', () {
      final s = LayerStack(const [NoteLayer('a', 'Sky')]);
      expect(s.indexOf('gone'), s.indexOf(baseLayerId));
      expect(s.of(stroke('gone')).id, baseLayerId);
      expect(s.without('a').of(stroke('a')).id, baseLayerId, reason: 'deleting a layer puts its lines on the base layer');
    });

    test('the base layer cannot be deleted, and there are never more than the most', () {
      var s = LayerStack.plain;
      expect(s.without(baseLayerId), s);
      for (var i = 0; i < maxLayers + 5; i++) {
        s = s.added(NoteLayer('l$i', 'L$i'));
      }
      expect(s.length, maxLayers);
    });

    test('layers are added above the one given, replaced, and moved up and down without leaving the stack', () {
      var s = LayerStack(const [NoteLayer('a', 'A'), NoteLayer('b', 'B')]); // base, a, b
      s = s.added(const NoteLayer('c', 'C'), above: 0);
      expect(s.layers.map((l) => l.id), [baseLayerId, 'c', 'a', 'b']);
      s = s.moved('c', 2);
      expect(s.layers.map((l) => l.id), [baseLayerId, 'a', 'b', 'c']);
      expect(s.moved('c', 5).layers.map((l) => l.id), [baseLayerId, 'a', 'b', 'c'], reason: 'the top one cannot go higher');
      expect(s.moved('c', -9).layers.first.id, 'c');
      expect(s.moved('zzz', 1), s);
      expect(s.replaced(s.byId('a').copyWith(name: 'Renamed')).byId('a').name, 'Renamed');
      expect(s.replaced(s.byId('a').copyWith(opacity: 3)).byId('a').opacity, 1);
    });

    test('only the lines of a shown, unlocked layer can be worked on', () {
      final s = LayerStack(const [NoteLayer('hid', 'H', visible: false), NoteLayer('lock', 'L', locked: true)]);
      expect(s.editable(stroke(baseLayerId)), isTrue);
      expect(s.editable(stroke('hid')), isFalse);
      expect(s.editable(stroke('lock')), isFalse);
      expect(LayerStack.plain.editable(stroke('anything')), isTrue);
    });

    test('lines are drawn bottom layer first, each layer in the order it was drawn in, and hidden layers not at all', () {
      final s = LayerStack(const [NoteLayer('top', 'T'), NoteLayer('hid', 'H', visible: false)]).moved('top', 5);
      final a = stroke('top', id: 'a'), b = stroke(baseLayerId, id: 'b'), c = stroke('hid', id: 'c'), d = stroke('top', id: 'd'), e = stroke(baseLayerId, id: 'e');
      expect(s.ordered([a, b, c, d, e]).map((x) => x.id), ['b', 'e', 'a', 'd']);
    });

    test('an export has the order and the opacity of the layers in the colour of the lines, and leaves the originals alone', () {
      final s = LayerStack(const [NoteLayer('x', 'X', opacity: 0.5)]);
      final base = stroke(baseLayerId), faded = stroke('x', color: const Color(0xFF00FF00));
      final out = s.forExport([faded, base]);
      expect(out.map((o) => o.layer), [baseLayerId, 'x']);
      expect(out[0], same(base));
      expect(out[1].color.a, closeTo(0.5, 1e-6));
      expect(out[1].points, faded.points);
      expect(faded.color.a, 1);
    });
  });

  group('kept with the note', () {
    test('the layers and each line\'s layer are saved and come back, and a note without layers writes nothing', () async {
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      expect(note.layers.isPlain, isTrue);
      note.layers = LayerStack(const [NoteLayer('x', 'Ink', locked: true, opacity: 0.6)]);
      note.strokes[0] = [stroke(baseLayerId, id: 'one'), stroke('x', id: 'two')];
      await repo.saveNote(note);
      final back = (await repo.loadNote(id))!;
      expect(back.layers, note.layers);
      expect([for (final s in back.strokes[0]!) s.layer], [baseLayerId, 'x']);

      back.layers = LayerStack.plain;
      await repo.saveNote(back);
      expect((await repo.loadNote(id))!.layers.isPlain, isTrue);
    });

    test('a note file keeps them, and a file without them (or from before them) opens with the plain stack', () {
      final strokes = {
        0: [stroke(baseLayerId, id: 'a'), stroke('x', id: 'b')],
        2: [stroke('x', id: 'c')],
      };
      final read = decodeStrokes(encodeStrokes(strokes));
      expect([for (final s in read[0]!) s.layer], [baseLayerId, 'x']);
      expect(read[2]!.single.layer, 'x');
      expect(read[0]!.map((s) => s.id), ['a', 'b']);
    });

    test('a whole note exported and imported again has its layers and the layer of each line', () async {
      final dir = await Directory.systemTemp.createTemp('layerfile');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final files = NoteFileService(repo, supportDirectory: () async => dir);
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.layers = LayerStack(const [NoteLayer('x', 'Ink', visible: false, opacity: 0.3)]);
      note.strokes[0] = [stroke('x', id: 'one'), stroke(baseLayerId, id: 'two')];
      await repo.saveNote(note);
      final bytes = (await files.exportBytes(id))!;
      final copy = (await repo.loadNote((await files.importBytes(bytes)).noteId))!;
      expect(copy.layers, note.layers);
      expect({for (final s in copy.strokes[0]!) s.layer}, {'x', baseLayerId});
    });

    test('devices share each line\'s layer and the layers themselves, and a device that sends no layers does not clear them', () {
      final a = Replica('a'), b = Replica('b');
      final na = NoteData(id: 'n'), nb = NoteData(id: 'n');
      na.layers = LayerStack(const [NoteLayer('x', 'Sky', opacity: 0.5)]);
      na.strokes[0] = [stroke('x', id: 's1')];
      Map<String, Object?> none() => const {};
      for (final op in a.localChanges(na)) {
        b.apply(nb, op, makeBox: (i) => TextBoxWidgetModel(id: i, position: Offset.zero), saveImage: (i, bytes, e) => '', onNoteField: (f, d) => Replica.applyNoteField(nb, f, d));
      }
      expect(nb.layers, na.layers);
      expect(nb.strokes[0]!.single.layer, 'x');
      expect(b.localChanges(nb), isEmpty, reason: 'nothing to send back');
      // an older device's setup says nothing about layers
      final old = NoteData(id: 'n')..layers = nb.layers;
      Replica.applyNoteField(old, 'setup', {'bg': 'blank', 'fmt': 'a4', 'land': false, 'nat': <int>[]});
      expect(old.layers, nb.layers);
      Replica.applyNoteField(old, 'setup', {'layers': null});
      expect(old.layers.isPlain, isTrue, reason: 'a device that deleted its layers says so');
      expect(none(), isEmpty);
    });

    test('a database from before layers is upgraded in place', () async {
      final dir = await Directory.systemTemp.createTemp('oldlayers');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/notes.db';
      final db = await AppDatabase.open(path: path);
      expect((await db.rawQuery('PRAGMA table_info(strokes)')).map((c) => c['name']), contains('layer'));
      expect((await db.rawQuery('PRAGMA table_info(notes)')).map((c) => c['name']), contains('layers'));
      await db.close();
    });
  });

  group('drawing the layers', () {
    Future<ui.Image> paint(List<DrawingStroke> strokes, LayerStack layers) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 120, 100), Paint()..color = Colors.white);
      InkLayerPainter(strokes: strokes, layers: layers).paint(canvas, const Size(120, 100));
      return recorder.endRecording().toImage(120, 100);
    }

    Future<({int r, int g, int b})> pixel(ui.Image img, int x, int y) async {
      final data = (await img.toByteData())!;
      final i = (y * img.width + x) * 4;
      return (r: data.getUint8(i), g: data.getUint8(i + 1), b: data.getUint8(i + 2));
    }

    testWidgets('a hidden layer shows nothing, and a line on a higher layer is over one on a lower layer however they were drawn', (tester) async {
      await tester.runAsync(() async {
        final red = stroke(baseLayerId, color: const Color(0xFFFF0000)), blue = stroke('top', color: const Color(0xFF0000FF));
        // the blue line was drawn first, but its layer is above
        var img = await paint([blue, red], LayerStack(const [NoteLayer('top', 'Top')]));
        expect((await pixel(img, 60, 50)).b, greaterThan(230), reason: 'blue is on top');
        expect((await pixel(img, 60, 50)).r, lessThan(40));
        img = await paint([blue, red], LayerStack(const [NoteLayer('top', 'Top', visible: false)]));
        expect((await pixel(img, 60, 50)).r, greaterThan(200), reason: 'only red is left');
        expect((await pixel(img, 60, 50)).b, lessThan(40));
        img = await paint([blue, red], LayerStack(const [NoteLayer('top', 'Top')]).moved('top', -1));
        expect((await pixel(img, 60, 50)).r, greaterThan(200), reason: 'moved below the base layer: red is on top');
      });
    });

    testWidgets('a see-through layer is see-through as a whole: two lines of it crossing are not darker where they cross', (tester) async {
      await tester.runAsync(() async {
        final a = DrawingStroke(color: Colors.black, width: 20, points: const [Offset(10, 50), Offset(110, 50)], layer: 'x');
        final b = DrawingStroke(color: Colors.black, width: 20, points: const [Offset(60, 10), Offset(60, 90)], layer: 'x');
        final img = await paint([a, b], LayerStack(const [NoteLayer('x', 'X', opacity: 0.5)]));
        final alone = await pixel(img, 30, 50), crossing = await pixel(img, 60, 50);
        expect(alone.r, closeTo(127, 6), reason: 'half of black over white');
        expect(crossing.r, closeTo(alone.r, 3), reason: 'the layer is faded as a whole');
      });
    });

    testWidgets('a note with the plain stack is drawn as before (no layer is made)', (tester) async {
      await tester.runAsync(() async {
        final img = await paint([stroke(baseLayerId, color: const Color(0xFF00AA00))], LayerStack.plain);
        expect((await pixel(img, 60, 50)).g, greaterThan(150));
      });
    });
  });
}

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/painters/canvas_painters.dart';

/// A thick horizontal line on [layer] from x [from] to [to].
DrawingStroke bar(String layer, Color color, {double from = 10, double to = 60, double y = 50, double width = 30}) =>
    DrawingStroke(color: color, width: width, points: [for (var i = 0; i <= 10; i++) Offset(from + (to - from) * i / 10, y)], layer: layer, brush: penBrushId);

Future<Color> pixel(WidgetTester tester, LayerStack layers, List<DrawingStroke> strokes, Offset at) async {
  late ByteData data;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    paintLayered(Canvas(recorder), strokes, 0.6, layers);
    final image = await recorder.endRecording().toImage(100, 100);
    data = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    image.dispose();
  });
  final i = (at.dy.round() * 100 + at.dx.round()) * 4;
  return Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
}

void main() {
  group('groups in the stack', () {
    final base = LayerStack.plain.layers.first;

    test('the layers of a group lie together right above it, and a group that is not there or a nested one is dropped', () {
      final s = LayerStack([base, const NoteLayer('g', 'Group', isGroup: true), const NoteLayer('a', 'A'), const NoteLayer('m', 'M', group: 'g'), const NoteLayer('b', 'B'), const NoteLayer('n', 'N', group: 'g'), const NoteLayer('x', 'X', group: 'nothing'), const NoteLayer('h', 'H', isGroup: true, group: 'g')]);
      expect(s.layers.map((l) => l.id).toList(), [baseLayerId, 'g', 'm', 'n', 'a', 'b', 'x', 'h'], reason: 'the members come together after the group, in their order');
      expect(s.layers[6].group, '', reason: 'a group that is not there is no group');
      expect(s.layers[7].group, '', reason: 'groups are not nested');
      expect(s.membersOf('g'), [2, 3]);
      expect(s.topLevel, [0, 1, 4, 5, 6, 7]);
    });

    test('a hidden or locked group hides or locks its layers, and the opacity and blend of both count', () {
      final s = LayerStack([base, const NoteLayer('g', 'G', isGroup: true, visible: false, opacity: 0.5, blend: LayerBlend.screen), const NoteLayer('m', 'M', group: 'g', opacity: 0.5)]);
      expect(s.byId('m').visible, isFalse);
      expect(s.byId('m').opacity, 0.25);
      expect(s.byId('m').blend, LayerBlend.screen, reason: 'a layer with no blend of its own is laid over the others the way its group is');
      expect(s.layers[2].visible, isTrue, reason: 'the entry itself is as it was set');
      final locked = s.replaced(s.layers[1].copyWith(visible: true, locked: true));
      expect(locked.byId('m').editable, isFalse);
    });

    test('moving: a layer among those of its group, a group with all of its layers', () {
      final s = LayerStack([base, const NoteLayer('a', 'A'), const NoteLayer('g', 'G', isGroup: true), const NoteLayer('m', 'M', group: 'g'), const NoteLayer('n', 'N', group: 'g')]);
      expect(s.moved('m', 1).layers.map((l) => l.id), [baseLayerId, 'a', 'g', 'n', 'm']);
      expect(s.moved('n', 1).layers.map((l) => l.id), [baseLayerId, 'a', 'g', 'm', 'n'], reason: 'not out of its group');
      expect(s.moved('g', -1).layers.map((l) => l.id), [baseLayerId, 'g', 'm', 'n', 'a']);
      expect(s.moved('a', 1).layers.map((l) => l.id), [baseLayerId, 'g', 'm', 'n', 'a']);
    });

    test('grouping, taking out, ungrouping; a new layer above a layer of a group is in the group', () {
      var s = LayerStack([base, const NoteLayer('a', 'A'), const NoteLayer('b', 'B')]);
      s = s.groupedWith('a', 'g1', 'Group 1');
      expect(s.layers.map((l) => l.id), [baseLayerId, 'g1', 'a', 'b']);
      expect(s.byId('a').group, 'g1');
      expect(s.groupedWith(baseLayerId, 'g2', 'x'), s, reason: 'the base layer stays out of groups');
      s = s.inGroup('b', 'g1');
      expect(s.membersOf('g1'), [2, 3]);
      s = s.added(const NoteLayer('c', 'C'), above: s.indexOf('a'));
      expect(s.layers.firstWhere((l) => l.id == 'c').group, 'g1');
      s = s.inGroup('c', '');
      expect(s.byId('c').group, '');
      expect(s.without('g1').layers.every((l) => l.group.isEmpty), isTrue, reason: 'taking a group away keeps its layers');
    });

    test('blend, clip and groups are kept in the note and read back; a stack without them writes as before', () {
      final s = LayerStack([base, const NoteLayer('g', 'G', isGroup: true, collapsed: true), const NoteLayer('m', 'M', group: 'g', blend: LayerBlend.multiply, clip: true)]);
      final back = LayerStack.fromJsonText(s.toJsonText());
      expect(back, s);
      expect(back.layers[2].blend, LayerBlend.multiply);
      expect(back.layers[2].clip, isTrue);
      expect(back.layers[1].isGroup && back.layers[1].collapsed, isTrue);
      expect(LayerStack([base, const NoteLayer('a', 'A', opacity: 0.5)]).toJsonText(), isNot(contains('"b"')));
    });
  });

  group('drawing layers', () {
    final yellow = const Color(0xFFFFFF00), cyan = const Color(0xFF00FFFF), red = const Color(0xFFFF0000), green = const Color(0xFF00FF00);
    final base = LayerStack.plain.layers.first;

    testWidgets('multiply lays a layer over the one below as a product of the colors; normal covers it', (tester) async {
      final strokes = [bar(baseLayerId, yellow), bar('b', cyan)];
      final multiplied = LayerStack([base, const NoteLayer('b', 'B', blend: LayerBlend.multiply)]);
      final over = await pixel(tester, multiplied, strokes, const Offset(30, 50));
      expect((over.r * 255).round(), 0);
      expect((over.g * 255).round(), 255);
      expect((over.b * 255).round(), 0, reason: 'yellow times cyan is green');
      final normal = await pixel(tester, LayerStack([base, const NoteLayer('b', 'B')]), strokes, const Offset(30, 50));
      expect((normal.b * 255).round(), 255, reason: 'cyan covers yellow');
      final alone = await pixel(tester, multiplied, strokes, const Offset(80, 50));
      expect(alone.a, 0, reason: 'where nothing is drawn nothing is drawn');
    });

    testWidgets('a layer clipped to the one below shows only where that has drawn; a hidden base hides it', (tester) async {
      final strokes = [bar(baseLayerId, red, from: 10, to: 40), bar('b', green, from: 0, to: 100, width: 60)];
      final clipped = LayerStack([base, const NoteLayer('b', 'B', clip: true)]);
      final inside = await pixel(tester, clipped, strokes, const Offset(25, 50));
      expect((inside.g * 255).round(), 255, reason: 'on the base, the clipped layer is over it');
      final outside = await pixel(tester, clipped, strokes, const Offset(85, 50));
      expect(outside.a, 0, reason: 'off the base nothing of it shows');
      final free = await pixel(tester, LayerStack([base, const NoteLayer('b', 'B')]), strokes, const Offset(85, 50));
      expect((free.g * 255).round(), 255, reason: 'not clipped, it shows everywhere');
      final hiddenBase = LayerStack([base.copyWith(visible: false), const NoteLayer('b', 'B', clip: true)]);
      expect((await pixel(tester, hiddenBase, strokes, const Offset(25, 50))).a, 0);
    });

    testWidgets('a see-through group is one whole: where its layers overlap it is no darker', (tester) async {
      final strokes = [bar('a', red), bar('b', red, from: 30, to: 80)];
      final grouped = LayerStack([base, const NoteLayer('g', 'G', isGroup: true, opacity: 0.5), const NoteLayer('a', 'A', group: 'g'), const NoteLayer('b', 'B', group: 'g')]);
      final overlap = await pixel(tester, grouped, strokes, const Offset(45, 50));
      final single = await pixel(tester, grouped, strokes, const Offset(15, 50));
      expect(overlap.a, closeTo(single.a, 0.02));
      expect(single.a, closeTo(0.5, 0.02));
      // the same two as layers of their own, each half see-through, add up where they overlap
      final apart = LayerStack([base, const NoteLayer('a', 'A', opacity: 0.5), const NoteLayer('b', 'B', opacity: 0.5)]);
      expect((await pixel(tester, apart, strokes, const Offset(45, 50))).a, closeTo(0.75, 0.02));
    });

    testWidgets('a hidden group draws nothing of its layers', (tester) async {
      final strokes = [bar('a', red)];
      final hidden = LayerStack([base, const NoteLayer('g', 'G', isGroup: true, visible: false), const NoteLayer('a', 'A', group: 'g')]);
      expect((await pixel(tester, hidden, strokes, const Offset(30, 50))).a, 0);
      expect((await pixel(tester, hidden.replaced(hidden.layers[1].copyWith(visible: true)), strokes, const Offset(30, 50))).a, 1);
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/draw_result.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/canvas_models.dart';

Map<String, Object?> valid([Map<String, Object?> more = const {}]) => {'id': 'inks', 'name': 'Inks', 'version': '1.0.0', ...more};

DrawingStroke line({int n = 20, String? brush, List<int>? pressures}) => DrawingStroke(
      id: 'abc',
      color: const Color(0xFF000000),
      width: 4,
      points: [for (var i = 0; i < n; i++) Offset(i * 5.0, 10 + (i.isEven ? 2.0 : -2.0))],
      pressures: pressures,
      brush: brush ?? penBrushId,
    );

void main() {
  group('brushes in the manifest', () {
    test('numbers are read, kept in range, and come back as they went in', () {
      final m = ExtensionManifest.fromJson(valid({
        'brushes': [
          {'id': 'pencil', 'title': 'Pencil', 'width': 0.8, 'pressure': 0.7, 'opacity': 0.85, 'jitter': 0.4, 'taper': 0.5},
          {'id': 'nib', 'title': 'Nib', 'nibAngle': 45, 'nibFlatness': 0.2},
        ],
      }));
      expect(m.brushes.map((b) => b.id), ['pencil', 'nib']);
      expect(m.brushes[0].params.pressure, 0.7);
      expect(m.brushes[1].params.nibAngle, 45);
      expect(m.brushes[0].brushId('inks'), 'ext:inks/pencil');
      expect(ExtensionManifest.fromJson(jsonDecode(jsonEncode(m.toJson()))).brushes[1].params, m.brushes[1].params);
    });

    test('a number out of range, a bad id and a repeated id are refused', () {
      for (final bad in [
        {'id': 'x', 'title': 'X', 'opacity': 0},
        {'id': 'x', 'title': 'X', 'width': 'wide'},
        {'id': 'X!', 'title': 'X'},
        {'id': 'x'},
      ]) {
        expect(() => ExtensionManifest.fromJson(valid({'brushes': [bad]})), throwsA(isA<ManifestException>()), reason: '$bad');
      }
      expect(() => ExtensionManifest.fromJson(valid({'brushes': [{'id': 'x', 'title': 'X'}, {'id': 'x', 'title': 'Y'}]})), throwsA(isA<ManifestException>()));
    });
  });

  group('drawing tools in the manifest', () {
    test('they go with the permission draw.add, and the other way round', () {
      final tool = {'id': 'ruler', 'title': 'Ruler', 'preview': 'line'};
      final m = ExtensionManifest.fromJson(valid({'permissions': ['draw.add'], 'drawTools': [tool]}));
      expect(m.drawTools.single.preview, DrawPreview.line);
      expect(() => ExtensionManifest.fromJson(valid({'drawTools': [tool]})), throwsA(isA<ManifestException>()));
      expect(() => ExtensionManifest.fromJson(valid({'permissions': ['draw.add']})), throwsA(isA<ManifestException>()));
      expect(() => ExtensionManifest.fromJson(valid({'permissions': ['draw.add'], 'drawTools': [{...tool, 'preview': 'blob'}]})), throwsA(isA<ManifestException>()));
    });
  });

  group('the shape a brush makes', () {
    test('the roller is a wide band with streaks over it, square at the ends, and five times the chosen width', () {
      expect(Brushes.roller.widthScale, 5);
      final stroke = DrawingStroke(id: 'r1', color: const Color(0xFF000000), width: 20, points: const [Offset(0, 50), Offset(200, 50)], brush: rollerBrushId);
      final shape = Brushes.roller.shape(stroke)!;
      expect(shape.filled, isTrue);
      expect(shape.opacity, lessThan(1));
      expect(shape.layers, hasLength(4)); // three levels of streaks, and the edges
      final b = shape.path.getBounds();
      expect((b.left, b.right), (0, 200), reason: 'square ends: no rounding beyond the points');
      expect(b.height, closeTo(20, 0.1));
      expect(Brushes.roller.shape(stroke)!.layers[0].path.getBounds(), shape.layers[0].path.getBounds(), reason: 'the same line, the same streaks');
    });

    test('a brush of numbers is a filled outline; the same line gives the same outline', () {
      const brush = ParamBrush('ext:inks/pencil', 'Pencil', BrushParams(jitter: 0.5, taper: 0.5, opacity: 0.8));
      final a = brush.shape(line())!, b = brush.shape(line())!;
      expect(a.filled, isTrue);
      expect(a.opacity, 0.8);
      expect(a.path.getBounds(), b.path.getBounds());
    });

    test('a tapered line is thinner at its end than a plain one, and pressure makes a line thicker where it pressed', () {
      const plain = ParamBrush('p', 'P', BrushParams(smoothing: 0));
      const tapered = ParamBrush('t', 'T', BrushParams(smoothing: 0, taper: 1));
      expect(tapered.shape(line())!.path.getBounds().height, lessThanOrEqualTo(plain.shape(line())!.path.getBounds().height));

      const pressed = ParamBrush('q', 'Q', BrushParams(smoothing: 0, pressure: 1));
      final soft = pressed.shape(line(pressures: List.filled(20, 20)))!.path.getBounds();
      final hard = pressed.shape(line(pressures: List.filled(20, 250)))!.path.getBounds();
      expect(hard.height, greaterThan(soft.height));
      expect(pressed.usesPressure, isTrue);
    });

    test('a flat nib is thick across and thin along', () {
      const nib = ParamBrush('n', 'N', BrushParams(smoothing: 0, nibAngle: 0, nibFlatness: 0.1));
      final across = DrawingStroke(color: const Color(0xFF000000), width: 10, points: const [Offset(0, 0), Offset(0, 40)], brush: 'n');
      final along = DrawingStroke(color: const Color(0xFF000000), width: 10, points: const [Offset(0, 0), Offset(40, 0)], brush: 'n');
      expect(nib.shape(across)!.path.getBounds().width, closeTo(10, 0.5)); // going down, the horizontal nib is as wide as it is
      expect(nib.shape(along)!.path.getBounds().height, lessThan(3)); // going along, only its thickness shows
    });

    test('brushes are registered and let go of by extension, and a missing one is no brush', () {
      final before = Brushes.revision;
      Brushes.sync('ext:inks/', const [ParamBrush('ext:inks/a', 'A', BrushParams())]);
      expect(Brushes.byId('ext:inks/a'), isNotNull);
      expect(Brushes.revision, greaterThan(before));
      Brushes.sync('ext:inks/', const []);
      expect(Brushes.byId('ext:inks/a'), isNull);
      expect(Brushes.byId(penBrushId), isNotNull, reason: 'the built-in ones stay');
    });
  });

  group('what a drawing tool hands back', () {
    final color = const Color(0xFF112233);
    test('lines get the colour and width of the gesture where they say none', () {
      final s = parseDrawnStrokes({'strokes': [{'points': [[0, 0], [10, 10]]}, {'points': [[0, 0], [5, 5]], 'color': '#ff0000', 'width': 2, 'dash': 'dashed', 'brush': 'nope'}]}, color: color, width: 3);
      expect(s[0].color, color);
      expect(s[0].width, 3);
      expect(s[1].color, const Color(0xFFFF0000));
      expect((s[1].dash, s[1].brush), (StrokeDash.dashed, penBrushId));
    });

    test('nothing is taken from an answer that is not right', () {
      for (final bad in <Object?>[
        {'strokes': 5},
        {'strokes': [{'points': [[0, 0]]}]},
        {'strokes': [{'points': [[0, 0], [1, double.infinity]]}]},
        {'strokes': [{'points': [[0, 0], [1e9, 1]]}]},
        {'strokes': [{'points': [[0, 0], [1, 1]], 'width': 0}]},
        {'strokes': [{'points': [[0, 0], [1, 1]], 'color': 'red'}]},
        {'strokes': [for (var i = 0; i < 201; i++) {'points': [[0, 0], [1, 1]]}]},
      ]) {
        expect(() => parseDrawnStrokes(bad, color: color, width: 3), throwsA(isA<ExtensionError>()), reason: '$bad');
      }
      expect(parseDrawnStrokes(null, color: color, width: 3), isEmpty);
    });

    test('colours as text', () {
      expect(colorFromHex('#f00'), const Color(0xFFFF0000));
      expect(colorFromHex('#00000080')!.a, closeTo(0.5, 0.01));
      expect(colorFromHex('#xyz'), isNull);
      expect(colorToHex(const Color(0xFF112233)), '#112233');
    });

    test('the gesture the script gets has at most 2000 points, spread along the drag', () {
      final g = DrawGesture(points: [for (var i = 0; i < 5000; i++) Offset(i.toDouble(), 0)], color: color, width: 3, page: const Size(100, 200));
      final j = g.toJson();
      expect((j['points'] as List).length, DrawGesture.largest);
      expect(j['end'], [4999.0, 0.0]);
    });
  });

  group('running a drawing tool', () {
    final skip = QuickJsEngine.available ? null : 'the JavaScript engine is not here';
    late Directory dir;
    late Map<String, String> settings;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ext');
      settings = {};
    });
    tearDown(() => dir.delete(recursive: true));

    ExtensionService make() => ExtensionService((k) async => settings[k], (k, v) async => settings[k] = v, directory: () async => Directory('${dir.path}/extensions'));
    final gesture = DrawGesture(points: const [Offset(0, 0), Offset(40, 3)], color: const Color(0xFF000000), width: 2, page: const Size(100, 100));

    test('the line comes back straight; without leave it is not offered and not run', () async {
      final s = make();
      final e = await s.installSource(
        jsonEncode(valid({'permissions': ['draw.add'], 'drawTools': [{'id': 'ruler', 'title': 'Ruler', 'preview': 'line'}]})),
        "notation.drawTool('ruler', (ctx) => ({ strokes: [{ points: [ctx.start, [ctx.end[0], ctx.start[1]]] }] }));",
      );
      await s.setEnabled('inks', true);
      expect(s.drawTools, isEmpty);
      expect((await s.runDrawTool(e, e.manifest.drawTools.single, gesture)).error, contains('draw.add'));
      await s.setGranted('inks', ExtensionPermission.draw, true);
      expect(s.drawTools.map((t) => t.tool.id), ['ruler']);
      final r = await s.runDrawTool(s.byId('inks')!, e.manifest.drawTools.single, gesture);
      expect(r.error, isNull);
      expect(r.strokes.single.points, [const Offset(0, 0), const Offset(40, 0)]);
    }, skip: skip);

    test('brushes of an extension are there while it is on', () async {
      final s = make();
      await s.installSource(jsonEncode(valid({'brushes': [{'id': 'felt', 'title': 'Felt', 'width': 3}]})), '// nothing');
      expect(Brushes.byId('ext:inks/felt'), isNull, reason: 'off');
      await s.setEnabled('inks', true);
      expect(Brushes.byId('ext:inks/felt'), isA<ParamBrush>());
      await s.setEnabled('inks', false);
      expect(Brushes.byId('ext:inks/felt'), isNull);
    });
  });
}

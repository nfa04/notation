import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/brush_library.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/brush_desc.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'brush_look_frozen_test.dart' show lookOf, sampleStroke;

String look(Brush b, [double width = 10]) => lookOf(b.shape(sampleStroke('desc-look', width)));

void main() {
  setUpAll(AppDatabase.initFfi);
  tearDown(() => CustomBrushes.sync(const []));

  group('a brush as numbers', () {
    test('every kind has numbers of its own, each with a standard inside its range', () {
      for (final kind in BrushKind.values) {
        final knobs = BrushDesc.knobsOf(kind);
        expect(knobs, isNotEmpty);
        expect({for (final k in knobs) k.key}.length, knobs.length, reason: 'no number twice in $kind');
        for (final k in knobs) {
          expect(k.standard, inInclusiveRange(k.min, k.max), reason: '${kind.name}.${k.key}');
        }
      }
    });

    test('the id is made of the kind and the numbers, not of the name, and is the same after a trip through a file', () {
      final a = BrushDesc(BrushKind.ink, 'Fine', const {'width': 1.5, 'taper': 0.4});
      final b = BrushDesc(BrushKind.ink, 'Another name', const {'width': 1.5, 'taper': 0.4});
      expect(a.id, b.id);
      expect(a.id, startsWith(customBrushPrefix));
      expect(a.id.length, customBrushPrefix.length + 16);
      expect(BrushDesc(BrushKind.ink, 'Fine', const {'width': 1.6, 'taper': 0.4}).id, isNot(a.id));
      expect(BrushDesc(BrushKind.roller, 'Fine', const {'width': 1.5}).id, isNot(a.id));
      final again = BrushDesc.fromBytes(a.toBytes());
      expect(again, a);
      expect(again.id, a.id);
      // (a number that is left out is the standard, so it is the same brush as one that says so)
      expect(BrushDesc(BrushKind.ink, 'x').id, BrushDesc(BrushKind.ink, 'y', {for (final k in BrushDesc.knobsOf(BrushKind.ink)) if (!k.optional) k.key: k.standard}).id);
    });

    test('the id of a design is fixed for ever: lines in notes name it', () {
      // (if this changes, every note that is drawn with a designed brush loses its look)
      expect(BrushDesc(BrushKind.ink, 'x', const {'width': 2, 'pressure': 0.5, 'nibAngle': 30}).id, 'custom:0a7f2f3c5c38617b');
    });

    test('numbers outside their range are brought into it, unknown ones are left out, the name is cleaned', () {
      final d = BrushDesc(BrushKind.ink, '   a \n  very ${'long ' * 30}name ', const {'width': 99, 'pressure': -3, 'nope': 1});
      expect(d['width'], 10);
      expect(d['pressure'], 0);
      expect(d['nope'], isNull);
      expect(d['nibAngle'], isNull, reason: 'a round tip has no angle');
      expect(d.name.length, lessThanOrEqualTo(BrushDesc.maxName));
      expect(d.name, startsWith('a very long'));
      expect(BrushDesc(BrushKind.soft, '  ').name, 'Soft brush');
    });

    test('the file is JSON with the format, the version, the name, the kind and the numbers', () {
      final d = BrushDesc(BrushKind.charcoal, 'Dusty', const {'dust': 2.5});
      final json = jsonDecode(utf8.decode(d.toBytes())) as Map<String, Object?>;
      expect(json['format'], 'strokedesc');
      expect(json['version'], 1);
      expect(json['name'], 'Dusty');
      expect(json['kind'], 'charcoal');
      expect((json['params'] as Map)['dust'], 2.5);
      expect(json.containsKey('id'), isFalse);
      expect(strokeDescExtension, 'strokedesc');
    });

    test('a file that is not a brush is turned away with a reason, one with more than it needs is read', () {
      void bad(String text, Pattern reason) =>
          expect(() => BrushDesc.parse(text), throwsA(isA<BrushDescException>().having((e) => e.message, 'message', matches(reason))), reason: text);
      bad('not json', 'not JSON');
      bad('[1,2]', 'not a JSON object');
      bad('{"format":"other","version":1,"kind":"ink"}', 'wrong format');
      bad('{"format":"strokedesc","kind":"ink"}', 'version');
      bad('{"format":"strokedesc","version":2,"kind":"ink"}', 'newer version');
      bad('{"format":"strokedesc","version":1,"kind":"glitter"}', 'glitter');
      bad('{"format":"strokedesc","version":1,"kind":"ink","params":[1]}', 'numbers');
      bad('{"format":"strokedesc","version":1,"kind":"ink","params":{"width":"thick"}}', 'width');
      expect(() => BrushDesc.fromBytes(Uint8List(strokeDescMaxBytes + 1)), throwsA(isA<BrushDescException>()));
      expect(() => BrushDesc.fromBytes([0xFF, 0xFE, 0xFD]), throwsA(isA<BrushDescException>()));
      final fine = BrushDesc.parse('{"format":"strokedesc","version":1,"kind":"roller","name":7,"future":true,"params":{"dryness":0.5,"glitter":9}}');
      expect(fine.kind, BrushKind.roller);
      expect(fine['dryness'], 0.5);
      expect(fine.name, 'Roller brush');
    });
  });

  group('the brush a design makes', () {
    test('the starting designs draw like the brushes of the app they are taken from', () {
      final byName = {for (final d in BrushDesc.starting) d.name: d};
      for (final b in [Brushes.pencil, Brushes.fountain, Brushes.calligraphy, Brushes.marker]) {
        expect(look(byName[b.label]!.build()), look(b), reason: b.id);
        expect(look(byName[b.label]!.build(), 3), look(b, 3), reason: b.id);
      }
      expect(look(byName['Roller']!.build()), look(Brushes.roller));
      expect(look(byName['Charcoal']!.build()), look(Brushes.charcoal));
      expect(byName['Roller']!.build().widthScale, Brushes.roller.widthScale);
      expect(byName['Charcoal']!.build().widthScale, Brushes.charcoal.widthScale);
    });

    test('every number changes the look', () {
      final same = <String>[];
      for (final kind in BrushKind.values) {
        final base = BrushDesc(kind, 'x');
        for (final k in BrushDesc.knobsOf(kind)) {
          final start = k.optional ? base.withValue(k.key, k.standard) : base;
          // (the flatness of a nib only shows with a nib)
          var basis = k.key == 'nibFlatness' ? start.withValue('nibAngle', 40) : start;
          // (the pressure curve only matters with a pressure; the angle of a round dab does not show)
          if (k.key == 'speckleSize' || k.key == 'speckleSpread') basis = basis.withValue('speckle', 5);
          if (k.key == 'pressureCurve') basis = basis.withValue('pressure', 1);
          if (kind == BrushKind.stamp && const {'angle', 'angleJitter', 'follow'}.contains(k.key)) basis = basis.withValue('shape', 1);
          final low = basis.withValue(k.key, k.min).build();
          final high = basis.withValue(k.key, k.max).build();
          // (the thickness is not in the shape: the editor multiplies the width of the line by it)
          if (k.key == 'width') {
            if (low.widthScale == high.widthScale) same.add('${kind.name}.${k.key}');
          } else if (look(low) == look(high)) {
            same.add('${kind.name}.${k.key}');
          }
        }
      }
      expect(same, isEmpty, reason: 'numbers that do not change the look');
    });

    test('the thickness is the width of the line, and what the brush writes with is read as writing, what paints is not', () {
      expect(BrushDesc(BrushKind.roller, 'x', const {'width': 8}).build().widthScale, 8);
      expect(BrushDesc(BrushKind.soft, 'x', const {'width': 3}).build().widthScale, 3);
      expect(BrushDesc(BrushKind.ink, 'x').build().writing, isTrue);
      expect(BrushDesc(BrushKind.ink, 'x', const {'pressure': 0.5}).build().usesPressure, isTrue);
      expect(BrushDesc(BrushKind.roller, 'x').build().writing, isFalse);
      expect(BrushDesc(BrushKind.soft, 'x').build().writing, isFalse);
    });

    test('a soft brush is hard-edged at no softness and fades out at full softness, and blurs on the screen only when soft', () {
      final stroke = sampleStroke('s', 12);
      final hard = BrushDesc(BrushKind.soft, 'x', const {'softness': 0}).build().shape(stroke)!;
      final soft = BrushDesc(BrushKind.soft, 'x', const {'softness': 1}).build().shape(stroke)!;
      expect(hard.soft, isNull);
      expect(soft.soft, isNotNull);
      // (the outermost layer is where the edge is: strong when hard, faint when soft)
      expect(hard.opacity, greaterThan(0.6));
      expect(soft.opacity, lessThan(0.1));
      expect(hard.layers.length, lessThan(10), reason: 'a flat brush needs few layers');
      // (the opacity of the layers together is what the page shows at the middle: not more than the strength says)
      double middle(BrushShape s) => 1 - [s.opacity, ...s.layers.map((l) => l.opacity)].fold(1.0, (a, o) => a * (1 - o));
      expect(middle(soft), closeTo(0.85, 0.04));
      expect(middle(hard), closeTo(0.85, 0.04));
      expect(middle(BrushDesc(BrushKind.soft, 'x', const {'strength': 0.4}).build().shape(stroke)!), closeTo(0.34, 0.04));
    });

    test('a charcoal with no dust leaves none, and one with no gaps has more streaks', () {
      final stroke = sampleStroke('c', 8);
      int pieces(BrushShape s) => s.layers.fold(0, (a, l) => a + l.outline.pieces.length);
      final dusty = BrushDesc(BrushKind.charcoal, 'x', const {'dust': 3}).build().shape(stroke)!;
      final clean = BrushDesc(BrushKind.charcoal, 'x', const {'dust': 0}).build().shape(stroke)!;
      expect(pieces(clean), lessThan(pieces(dusty)));
      final gappy = BrushDesc(BrushKind.charcoal, 'x', const {'dryness': 0.8, 'dust': 0}).build().shape(stroke)!;
      final full = BrushDesc(BrushKind.charcoal, 'x', const {'dryness': 0, 'dust': 0}).build().shape(stroke)!;
      expect(pieces(full), greaterThan(pieces(gappy)));
    });

    test('a line, a one-point line and a line of one place are drawn by every kind without a failure', () {
      for (final kind in BrushKind.values) {
        final b = BrushDesc(kind, 'x').build();
        for (final points in [
          const [Offset(5, 5)],
          const [Offset(5, 5), Offset(5, 5)],
          const [Offset(0, 0), Offset(1e5, 1e5)],
        ]) {
          final s = DrawingStroke(id: 'e', color: Colors.black, width: 4, points: points);
          expect(() => b.shape(s), returnsNormally, reason: '${kind.name} $points');
        }
      }
    });
  });

  test('the extensions whose brushes a device is missing are named once each, in order; the pen, the app\'s brushes and designed ones are not extensions', () {
    expect(extensionsMissingFor(['ext:zeta/a', 'ext:alpha/x', 'ext:alpha/y', penBrushId, 'pencil', 'custom:0123456789abcdef', 'ext:noslash']), ['alpha', 'noslash', 'zeta']);
    expect(extensionsMissingFor(const []), isEmpty);
  });

  group('the numbers added later', () {
    DrawingStroke line({String id = 'l', double width = 6, List<Offset>? points, List<int>? pressures}) {
      final pts = points ?? [for (var i = 0; i < 60; i++) Offset(10.0 + i * 4, 50 + 10 * (i % 3))];
      return DrawingStroke(id: id, color: Colors.black, width: width, points: pts, pressures: pressures);
    }

    BrushShape shapeOf(BrushDesc d, DrawingStroke s) => d.build().shape(s)!;

    List<double> halves(BrushShape s) => (s.outline.pieces.single as OutlineRibbon).half;

    test('a number at its standard is not in the id, so a brush made before the number was there keeps its id; one that is not at it is', () {
      for (final kind in BrushKind.values) {
        for (final k in BrushDesc.knobsOf(kind).where((k) => k.sparse && !k.optional)) {
          expect(BrushDesc(kind, 'x', {k.key: k.standard}).id, BrushDesc(kind, 'x').id, reason: '${kind.name}.${k.key}');
          final other = k.standard == k.max ? k.min : k.max;
          expect(BrushDesc(kind, 'x', {k.key: other}).id, isNot(BrushDesc(kind, 'x').id), reason: '${kind.name}.${k.key}');
        }
      }
      // an optional one that is on is in the id, even at its standard
      expect(BrushDesc(BrushKind.ink, 'x', const {'startTaper': 0.5}).id, isNot(BrushDesc(BrushKind.ink, 'x').id));
      // the numbers of the first version are in the id always
      expect(BrushDesc(BrushKind.ink, 'x', const {'width': 2, 'pressure': 0.5, 'nibAngle': 30}).id, 'custom:0a7f2f3c5c38617b');
    });

    test('the ids of brushes with the later numbers are fixed too (a change here would take the look from every note drawn with them)', () {
      expect(BrushDesc(BrushKind.ink, 'x', const {'lightness': 0.5, 'blend': 1}).id, 'custom:610341740091eff5');
      expect(BrushDesc(BrushKind.stamp, 'x', const {'shape': 3, 'spacing': 1}).id, 'custom:51dae7c80bca2df6');
      expect(BrushDesc(BrushKind.stamp, 'x').id, 'custom:2616b3230ae0a68c');
    });

    test('a file from before the numbers were there is the brush it was, a file with them from a version without them is read with the rest', () {
      final old = BrushDesc.parse('{"format":"strokedesc","version":1,"name":"Old","kind":"roller","params":{"width":5,"coat":0.5,"streaks":1,"ridge":0.35,"dryness":0.3}}');
      expect(old.id, BrushDesc(BrushKind.roller, 'Old').id);
      expect(look(old.build()), look(Brushes.roller));
      // (a number the app does not know is ignored)
      expect(BrushDesc.parse('{"format":"strokedesc","version":1,"name":"N","kind":"ink","params":{"width":2,"glitter":9}}').id, BrushDesc(BrushKind.ink, 'N', const {'width': 2}).id);
    });

    test('the pressure curve bends the response, and without a pressure it does nothing', () {
      final pressed = line(pressures: [for (var i = 0; i < 60; i++) 128]);
      double mid(double curve) => halves(shapeOf(BrushDesc(BrushKind.ink, 'x', {'pressure': 1, 'pressureCurve': curve}), pressed))[30];
      expect(mid(2), lessThan(mid(1)), reason: 'a hard press is needed');
      expect(mid(0.5), greaterThan(mid(1)), reason: 'a light touch is enough');
    });

    test('a line gets thinner where the pen is fast', () {
      final points = <Offset>[
        for (var i = 0; i < 30; i++) Offset(10.0 + i * 2, 50), // slow
        for (var i = 1; i <= 30; i++) Offset(68.0 + i * 12, 50), // fast
      ];
      final stroke = line(points: points, width: 6);
      final fast = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'speedThin': 1, 'smoothing': 0}), stroke));
      final even = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'smoothing': 0}), stroke));
      expect(fast[10], greaterThanOrEqualTo(even[10]), reason: 'slow: a little thicker than the line is on the whole');
      expect(fast[50], lessThan(even[50] * 0.8), reason: 'fast: thinner');
    });

    test('the start and the end can run out each in its own way', () {
      final stroke = line();
      final h = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'startTaper': 1, 'endTaper': 0, 'smoothing': 0}), stroke));
      expect(h.first, lessThan(h[h.length ~/ 2] * 0.3), reason: 'the start is a point');
      expect(h.last, closeTo(h[h.length ~/ 2], h.last * 0.05), reason: 'the end is round');
      final back = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'startTaper': 0, 'endTaper': 1, 'smoothing': 0}), stroke));
      expect(back.last, lessThan(back[back.length ~/ 2] * 0.3));
      expect(back.first, closeTo(back[back.length ~/ 2], back.first * 0.05));
      // with neither said, the taper does both, as it did
      final both = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'taper': 1, 'smoothing': 0}), stroke));
      expect(both.first, lessThan(both[both.length ~/ 2] * 0.3));
      expect(both.last, lessThan(both[both.length ~/ 2] * 0.3));
    });

    test('a hand wobble changes the thickness slowly along the line', () {
      final h = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'waver': 1, 'smoothing': 0}), line(points: [for (var i = 0; i < 80; i++) Offset(10.0 + i * 3, 50)])));
      expect(h.reduce(math.max) / h.reduce(math.min), greaterThan(1.4));
      // (slowly: the neighbours are alike)
      for (var i = 1; i < h.length; i++) {
        expect((h[i] - h[i - 1]).abs(), lessThan(h[i] * 0.35));
      }
    });

    test('a colour that varies is drawn in pieces of other colours; a brush with none draws one colour', () {
      final stroke = line();
      final plain = shapeOf(BrushDesc(BrushKind.ink, 'x'), stroke);
      expect(plain.layers, isEmpty);
      for (final d in [
        BrushDesc(BrushKind.ink, 'x', const {'lightness': 1}),
        BrushDesc(BrushKind.ink, 'x', const {'hue': 60, 'nibAngle': 30}),
        BrushDesc(BrushKind.stamp, 'x', const {'lightness': 1, 'hue': 60, 'spacing': 0.5}),
      ]) {
        final s = shapeOf(d, stroke);
        expect(s.layers, isNotEmpty, reason: d.name);
        expect(s.layers.every((l) => l.lightness != 0 || l.hue != 0), isTrue);
        // the colours are near the line's own, and differ from it
        for (final l in s.layers) {
          final c = l.colorOf(Colors.red);
          expect(c, isNot(Colors.red));
          expect(l.lightness.abs(), lessThanOrEqualTo(0.31));
          expect(l.hue.abs(), lessThanOrEqualTo(60));
        }
      }
      // all of the line is there: the pieces together are as long as the line
      final varied = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'lightness': 1, 'smoothing': 0}), stroke);
      final unvaried = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'smoothing': 0}), stroke);
      final points = varied.outline.pieces.fold<int>(0, (a, p) => a + (p as OutlineRibbon).points.length) + varied.layers.fold<int>(0, (a, l) => a + l.outline.pieces.fold<int>(0, (b, p) => b + (p as OutlineRibbon).points.length));
      expect(points, greaterThanOrEqualTo((unvaried.outline.pieces.single as OutlineRibbon).points.length));
      expect(varied.opacity, unvaried.opacity);
    });

    test('tinting keeps the opacity, and a hue goes round the wheel', () {
      final c = tintedColor(const Color(0x80FF0000), 0, 120);
      expect(c.a, closeTo(0.5, 0.01));
      expect(HSLColor.fromColor(c).hue, closeTo(120, 1));
      expect(tintedColor(const Color(0xFFFF0000), 0, 0), const Color(0xFFFF0000));
      expect(HSLColor.fromColor(tintedColor(const Color(0xFFFF0000), 0, 400)).hue, closeTo(40, 1));
      expect(tintedColor(const Color(0xFF808080), 0.5, 0).computeLuminance(), greaterThan(Color(0xFF808080).computeLuminance()));
      expect(tintedColor(const Color(0xFF808080), -0.5, 0).computeLuminance(), lessThan(Color(0xFF808080).computeLuminance()));
    });

    test('a blend that darkens is in the shape of the ink, the roller and the stamp, and not of the others', () {
      final stroke = line();
      for (final kind in [BrushKind.ink, BrushKind.roller, BrushKind.stamp]) {
        expect(shapeOf(BrushDesc(kind, 'x', const {'blend': 1}), stroke).multiply, isTrue, reason: kind.name);
        expect(shapeOf(BrushDesc(kind, 'x'), stroke).multiply, isFalse, reason: kind.name);
      }
      expect(shapeOf(BrushDesc(BrushKind.soft, 'x'), stroke).multiply, isFalse);
      expect(shapeOf(BrushDesc(BrushKind.charcoal, 'x'), stroke).multiply, isFalse);
    });

    group('the stamp', () {
      int dabs(BrushShape s) => s.outline.pieces.length + s.layers.fold(0, (a, l) => a + l.outline.pieces.length);

      test('puts dabs along the line, as many as the spacing says, and a line of one point gets one', () {
        final straight = line(points: [for (var i = 0; i <= 100; i++) Offset(i * 2.0, 40)], width: 4); // 200 long
        // 4 wide, a dab every 4*0.5 = 2: about a hundred
        final close = dabs(shapeOf(BrushDesc(BrushKind.stamp, 'x', const {'spacing': 0.5}), straight));
        expect(close, inInclusiveRange(95, 106));
        final apart = dabs(shapeOf(BrushDesc(BrushKind.stamp, 'x', const {'spacing': 2}), straight));
        expect(apart, inInclusiveRange(24, 27));
        expect(dabs(shapeOf(BrushDesc(BrushKind.stamp, 'x'), line(points: const [Offset(5, 5)]))), 1);
        expect(dabs(shapeOf(BrushDesc(BrushKind.stamp, 'x'), line(points: const [Offset(5, 5), Offset(5, 5)]))), 1);
      });

      test('a very long line does not get more dabs than the app draws', () {
        final long = line(points: const [Offset(0, 0), Offset(200000, 0)], width: 2);
        expect(dabs(shapeOf(BrushDesc(BrushKind.stamp, 'x', const {'spacing': 0.05, 'width': 0.5}), long)), lessThanOrEqualTo(4100));
      });

      test('each shape is its own, and a round dab is an oval unless it is flattened', () {
        final stroke = line(points: const [Offset(5, 5)]);
        OutlinePiece piece(Map<String, double> p) => shapeOf(BrushDesc(BrushKind.stamp, 'x', p), stroke).outline.pieces.single;
        expect(piece(const {}), isA<OutlineOval>());
        expect(piece(const {'squash': 0.5}), isA<OutlinePolygon>());
        expect((piece(const {'shape': 1}) as OutlinePolygon).points.length, 4);
        expect((piece(const {'shape': 2}) as OutlinePolygon).points.length, 3);
        expect((piece(const {'shape': 3}) as OutlinePolygon).points.length, 10);
        expect((piece(const {'shape': 4}) as OutlinePolygon).points.length, 8);
      });

      test('every dab winds the way ovals do, so that dabs that overlap add up and never cancel', () {
        double area(List<Offset> p) {
          var a = 0.0;
          for (var i = 0; i < p.length; i++) {
            final q = p[(i + 1) % p.length];
            a += p[i].dx * q.dy - q.dx * p[i].dy;
          }
          return a / 2;
        }

        final stroke = line(points: [for (var i = 0; i < 20; i++) Offset(i * 3.0, 20)]);
        for (final shape in [0, 1, 2, 3, 4]) {
          final s = shapeOf(BrushDesc(BrushKind.stamp, 'x', {'shape': shape.toDouble(), 'squash': 0.6, 'angleJitter': 1, 'follow': 1}), stroke);
          for (final piece in s.outline.pieces) {
            expect(area((piece as OutlinePolygon).points), greaterThan(0), reason: 'shape $shape');
          }
        }
      });

      test('the same line is always stamped the same way, another line differently', () {
        final d = BrushDesc(BrushKind.stamp, 'x', const {'scatter': 1, 'sizeJitter': 1, 'angleJitter': 1, 'shape': 1});
        expect(lookOf(shapeOf(d, line(id: 'a'))), lookOf(shapeOf(d, line(id: 'a'))));
        expect(lookOf(shapeOf(d, line(id: 'a'))), isNot(lookOf(shapeOf(d, line(id: 'b')))));
      });

      test('the dabs follow the pressure when they are asked to, and the line when they turn with it', () {
        final soft = line(points: [for (var i = 0; i < 30; i++) Offset(i * 5.0, 30)], pressures: [for (var i = 0; i < 30; i++) i < 15 ? 30 : 250], width: 6);
        final s = shapeOf(BrushDesc(BrushKind.stamp, 'x', const {'pressure': 1, 'sizeJitter': 0, 'spacing': 1}), soft);
        final sizes = [for (final p in s.outline.pieces) (p as OutlineOval).rect.width];
        expect(sizes.last, greaterThan(sizes.first * 2));
        final noPress = shapeOf(BrushDesc(BrushKind.stamp, 'x', const {'pressure': 0, 'sizeJitter': 0, 'spacing': 1}), soft);
        final flat = [for (final p in noPress.outline.pieces) (p as OutlineOval).rect.width];
        expect(flat.toSet().length, 1);

        // a triangle on a line that goes up: it points the way the line goes when it turns with it, and straight up when it does not
        final up = line(points: const [Offset(5, 40), Offset(5, 10)], width: 10);
        List<Offset> corners(double follow) =>
            (shapeOf(BrushDesc(BrushKind.stamp, 'x', {'shape': 2, 'sizeJitter': 0, 'spacing': 3, 'follow': follow}), up).outline.pieces.first as OutlinePolygon).points;
        String key(List<Offset> p) => p.map((q) => '${q.dx.toStringAsFixed(2)},${q.dy.toStringAsFixed(2)}').join(' ');
        expect(key(corners(1)), isNot(key(corners(0))));
      });
    });
  });

  group('the library', () {
    late Database db;
    late BrushLibrary library;

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings');
      library = BrushLibrary(SettingsRepository(db));
    });

    test('a saved brush is a brush of the app at once, is there after a restart, and is listed', () async {
      final d = BrushDesc(BrushKind.ink, 'Fine liner', const {'width': 0.6});
      expect(Brushes.byId(d.id), isNull);
      await library.save(d);
      expect(Brushes.byId(d.id)?.label, 'Fine liner');
      expect(Brushes.isListed(d.id), isTrue);
      expect(CustomBrushes.of(d.id), d);

      CustomBrushes.sync(const []); // (the app is started again)
      expect(Brushes.byId(d.id), isNull);
      final loaded = await library.load();
      expect(loaded.map((b) => (b.desc, b.listed)), [(d, true)]);
      expect(Brushes.byId(d.id), isNotNull);
    });

    test('taking a brush out of the menu keeps it, so that lines drawn with it look the same', () async {
      final d = BrushDesc(BrushKind.roller, 'Wall');
      await library.save(d);
      await library.setListed(d.id, false);
      expect(Brushes.byId(d.id), isNotNull);
      expect(Brushes.isListed(d.id), isFalse);
      await library.setListed(d.id, true);
      expect(Brushes.isListed(d.id), isTrue);
    });

    test('brushes from a note are kept out of the menu, and never undo a choice the person made', () async {
      final mine = BrushDesc(BrushKind.ink, 'Mine');
      final theirs = BrushDesc(BrushKind.soft, 'Theirs');
      await library.save(mine);
      expect(await library.adopt([mine, theirs, theirs]), 1);
      expect(Brushes.isListed(mine.id), isTrue);
      expect(Brushes.isListed(theirs.id), isFalse);
      expect(Brushes.byId(theirs.id), isNotNull);
      expect(await library.adopt([mine, theirs]), 0);
    });

    test('a library with a brush that cannot be read keeps it and the rest still works', () async {
      final settings = SettingsRepository(db);
      await settings.set('brush:custom:aaaaaaaaaaaaaaaa', '{"format":"strokedesc","version":9,"kind":"ink"}');
      await settings.set('brush:custom:bbbbbbbbbbbbbbbb', 'garbage');
      final d = BrushDesc(BrushKind.ink, 'Good');
      await library.save(d);
      expect((await library.load()).map((b) => b.desc), [d]);
      expect(await settings.get('brush:custom:aaaaaaaaaaaaaaaa'), isNotNull);
    });

    test('a deleted brush is gone from the app and the library, stays gone after a restart, and what is left is a mark that travels', () async {
      final a = BrushDesc(BrushKind.ink, 'Keep');
      final b = BrushDesc(BrushKind.charcoal, 'Drop');
      await library.save(a);
      await library.save(b);
      await library.delete(b.id);
      expect(Brushes.byId(b.id), isNull);
      expect(Brushes.byId(a.id), isNotNull);
      CustomBrushes.sync(const []);
      expect((await library.load()).map((x) => x.desc), [a]);
      // (a setting that is missing would be given back by the next device: the mark is a setting and is synced)
      final settings = SettingsRepository(db);
      expect(await settings.get('brush:${b.id}'), isNotNull);
      expect((await settings.allWhere(syncedSetting)).keys, contains('brush:${b.id}'));
    });

    test('a deleted brush does not count for the most brushes, and a note or a session that has it brings it back', () async {
      final d = BrushDesc(BrushKind.soft, 'Back');
      await library.save(d);
      await library.delete(d.id);
      expect(await library.adopt([d]), 1);
      expect(Brushes.byId(d.id), isNotNull);
      expect(Brushes.isListed(d.id), isFalse, reason: 'it comes back as a brush of a note, not in the menu');
      await library.delete(d.id);
      await library.keep(d);
      expect(Brushes.byId(d.id), isNotNull);
      // deleting what is not there does no harm
      await library.delete('custom:0000000000000000');
      expect(CustomBrushes.all, [d]);
    });

    test('a brush travels with the settings of the profile', () async {
      // (devicesync/sync_library.dart: syncedSetting)
      expect(BrushLibrary.keyPrefix, 'brush:');
    });
  });

  group('in a note file', () {
    late Directory root;
    late Database dbA, dbB;
    late NoteRepository repoA, repoB;
    late NoteFileService serviceA, serviceB;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('strokedesc_');
      dbA = await AppDatabase.open(path: '${root.path}/a.db');
      dbB = await AppDatabase.open(path: '${root.path}/b.db');
      repoA = NoteRepository(dbA);
      repoB = NoteRepository(dbB);
      serviceA = NoteFileService(repoA, supportDirectory: () async => Directory('${root.path}/sa').create());
      serviceB = NoteFileService(repoB, supportDirectory: () async => Directory('${root.path}/sb').create());
    });
    tearDown(() async {
      await dbA.close();
      await dbB.close();
      await root.delete(recursive: true);
    });

    Future<String> drawnWith(BrushDesc d, {String? also}) async {
      final id = await repoA.createNote(title: 'Sketch');
      final n = (await repoA.loadNote(id))!;
      n.strokes[0] = [
        DrawingStroke(id: 's1', color: Colors.black, width: 4, points: [for (var i = 0; i < 8; i++) Offset(i * 9.0, i * 3.0)], brush: d.id),
        DrawingStroke(id: 's2', color: Colors.red, width: 4, points: [for (var i = 0; i < 8; i++) Offset(i * 9.0, 40 + i * 3.0)], brush: also ?? d.id),
        DrawingStroke(id: 's3', color: Colors.blue, width: 4, points: [for (var i = 0; i < 8; i++) Offset(i * 9.0, 80)], brush: 'pencil'),
      ];
      await repoA.saveNote(n);
      return id;
    }

    test('the file carries the designed brushes its lines use as .strokedesc files, and no others', () async {
      final used = BrushDesc(BrushKind.ink, 'Used', const {'width': 2});
      final unused = BrushDesc(BrushKind.roller, 'Not used');
      await BrushLibrary(repoA.settings).save(used);
      await BrushLibrary(repoA.settings).save(unused);
      final id = await drawnWith(used);
      final bytes = (await serviceA.exportBytes(id))!;
      final names = ZipDecoder().decodeBytes(bytes).files.map((f) => f.name).where((n) => n.startsWith('brushes/')).toList();
      expect(names, ['brushes/${used.id.substring(customBrushPrefix.length)}.strokedesc']);
      final parsed = decodeNoteFile(bytes);
      expect(parsed.brushes, [used]);
      expect(parsed.warnings, isEmpty);
    });

    test('a note drawn with no designed brush has none in its file, one with a brush this device does not know has nothing to bring', () async {
      final id = await repoA.createNote(title: 'Plain');
      final n = (await repoA.loadNote(id))!;
      n.strokes[0] = [DrawingStroke(id: 'x', color: Colors.black, width: 2, points: const [Offset(0, 0), Offset(5, 5)], brush: 'custom:0000000000000000')];
      await repoA.saveNote(n);
      final bytes = (await serviceA.exportBytes(id))!;
      expect(ZipDecoder().decodeBytes(bytes).files.where((f) => f.name.startsWith('brushes/')), isEmpty);
      expect(decodeNoteFile(bytes).brushes, isEmpty);
    });

    test('on a device that never had the brush, opening the file keeps it, out of the menu, and the lines keep their brush', () async {
      final d = BrushDesc(BrushKind.charcoal, 'Smudge', const {'dust': 2});
      await BrushLibrary(repoA.settings).save(d);
      final id = await drawnWith(d);
      final bytes = (await serviceA.exportBytes(id))!;
      final before = look(Brushes.byId(d.id)!);

      CustomBrushes.sync(const []); // (this is another device: it has never heard of the brush)
      expect(Brushes.byId(d.id), isNull);
      final result = await serviceB.importBytes(bytes);
      expect(result.warnings, isEmpty);
      expect(Brushes.byId(d.id), isNotNull);
      expect(Brushes.isListed(d.id), isFalse);
      expect(look(Brushes.byId(d.id)!), before, reason: 'it looks as it did where it was made');
      final copy = (await repoB.loadNote(result.noteId))!;
      expect(copy.strokes[0]!.map((s) => s.brush), [d.id, d.id, 'pencil']);
      // it is in the library of the device, so it is still there after a restart
      CustomBrushes.sync(const []);
      await BrushLibrary(repoB.settings).load();
      expect(Brushes.byId(d.id), isNotNull);
    });

    test('a brush file that is damaged, too big or from a newer version is left out with a warning, the note opens', () async {
      final d = BrushDesc(BrushKind.ink, 'Good');
      await BrushLibrary(repoA.settings).save(d);
      final id = await drawnWith(d);
      final archive = ZipDecoder().decodeBytes((await serviceA.exportBytes(id))!);
      final out = Archive();
      for (final f in archive.files) {
        out.add(f);
      }
      void add(String name, List<int> data) => out.add(ArchiveFile(name, data.length, data));
      add('brushes/damaged.strokedesc', utf8.encode('{"format"'));
      add('brushes/huge.strokedesc', Uint8List(strokeDescMaxBytes + 1));
      add('brushes/newer.strokedesc', utf8.encode('{"format":"strokedesc","version":7,"kind":"ink"}'));
      add('brushes/readme.txt', utf8.encode('not a brush'));
      CustomBrushes.sync(const []);
      final parsed = decodeNoteFile(Uint8List.fromList(ZipEncoder().encodeBytes(out)));
      expect(parsed.brushes, [d]);
      expect(parsed.warnings.where((w) => w.contains('brush')).length, 3);
      expect(parsed.note.strokes[0], hasLength(3));
    });

    test('a file cannot bring more brushes than the app takes', () async {
      final out = Archive();
      final base = ZipDecoder().decodeBytes((await serviceA.exportBytes(await repoA.createNote(title: 'Empty')))!);
      for (final f in base.files) {
        out.add(f);
      }
      for (var i = 0; i < maxBrushesInNoteFile + 20; i++) {
        final data = BrushDesc(BrushKind.ink, 'b$i', {'width': 0.2 + i * 0.04}).toBytes();
        out.add(ArchiveFile('brushes/$i.strokedesc', data.length, data));
      }
      final parsed = decodeNoteFile(Uint8List.fromList(ZipEncoder().encodeBytes(out)));
      expect(parsed.brushes.length, maxBrushesInNoteFile);
      expect(parsed.warnings, isNotEmpty);
    });
  });
}

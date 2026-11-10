import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/l10n/german.dart';
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

    test('every number, choice, heading and starting design the designer shows has a German text', () {
      final missing = <String>{};
      void need(String? text) {
        if (text != null && !germanTexts.containsKey(text)) missing.add(text);
      }

      for (final kind in BrushKind.values) {
        for (final k in BrushDesc.knobsOf(kind)) {
          if (k.own) continue; // (a point of a curve is dragged, and has no name on the screen)
          need(k.label);
          need(k.group);
          k.choices?.forEach(need);
        }
      }
      BrushDesc.starting.map((d) => d.name).forEach(need);
      expect(missing, isEmpty, reason: 'add these to lib/l10n/german.dart');
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
          // (the gap shows with dashes, the distance and the blur of a shadow with a shadow, and so on)
          for (final e in (const {
                'dashGap': {'dash': 2.0},
                'shadowDistance': {'shadow': 0.5},
                'shadowBlur': {'shadow': 0.5},
                'glowHue': {'glow': 1.0},
                'outlineTone': {'outline': 1.0},
              }[k.key] ?? const <String, double>{}).entries) {
            basis = basis.withValue(e.key, e.value);
          }
          // (the sample line moves at a steady pace, so the ends of the speed curve never show on it: they have a test of their own)
          if (k.key == 'speedAt0' || k.key == 'speedAt100') continue;
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
      // all of the line is there: the pieces together cover the same area as the line does
      final varied = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'lightness': 1, 'smoothing': 0}), stroke);
      final unvaried = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'smoothing': 0}), stroke);
      Rect bounds(BrushShape s) => [s.path, ...s.layers.map((l) => l.path)].map((p) => p.getBounds()).reduce((a, b) => a.expandToInclude(b));
      expect((bounds(varied).width - bounds(unvaried).width).abs(), lessThan(1.0));
      expect((bounds(varied).height - bounds(unvaried).height).abs(), lessThan(1.0));
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

  group('dashes, what is behind a line, colour along it, curves, a steady hand, mixes and codes', () {
    DrawingStroke line({String id = 'l', double width = 4, List<Offset>? points, List<int>? pressures, Color color = Colors.black}) {
      final pts = points ?? [for (var i = 0; i <= 100; i++) Offset(i * 2.0, 40)]; // 200 long
      return DrawingStroke(id: id, color: color, width: width, points: pts, pressures: pressures);
    }

    BrushShape shapeOf(BrushDesc d, DrawingStroke s) => d.build().shape(s)!;
    List<double> halves(BrushShape s) => (s.outline.pieces.single as OutlineRibbon).half;
    Rect bounds(Path p) => p.getBounds();

    test('the ids of the designs with these numbers are fixed too', () {
      expect(BrushDesc(BrushKind.ink, 'x', const {'dash': 3, 'shadow': 0.5}).id, 'custom:42ff0a813a815d58');
      expect(BrushDesc(BrushKind.ink, 'x', const {'pressureAt0': 0.5, 'pressureAt25': 0.8, 'pressureAt50': 1, 'pressureAt75': 1.2, 'pressureAt100': 1.5}).id, 'custom:09677d43718a72cd');
      expect(BrushDesc(BrushKind.stamp, 'x', const {'rainbow': 10, 'outline': 0.5}).id, 'custom:0fbb8db00f1bb8ab');
      expect(BrushDesc(BrushKind.mix, 'x').id, 'custom:620f4df237255354');
      expect(BrushDesc(BrushKind.mix, 'x', const {'sizeB': 2}, [BrushDesc(BrushKind.roller, 'r'), BrushDesc(BrushKind.stamp, 's')]).id, 'custom:0d945d17598986e0');
      // (a brush that has none of the new numbers has the id it had before them)
      expect(BrushDesc(BrushKind.ink, 'x', const {'lightness': 0.5, 'blend': 1}).id, 'custom:610341740091eff5');
    });

    test('a dashed line is cut into dashes whose ends are exactly where they should be, and a dot is a dash of no length', () {
      // 4 wide, a dash that looks 3 widths long (12, round ends included: 8 between the centres of the ends) and a gap of 1.5 widths (6): one every 18
      final dashed = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'dash': 3, 'dashGap': 1.5}), line());
      final runs = dashed.outline.pieces.cast<OutlineRibbon>();
      expect(runs.length, 12);
      expect(runs[1].points.first.dx, closeTo(18, 1e-6));
      expect(runs[1].points.last.dx, closeTo(26, 1e-6));
      expect(runs.last.points.last.dx, closeTo(200, 1e-6), reason: 'the last dash is cut where the line ends');
      expect(bounds(dashed.path).width, lessThan(bounds(shapeOf(BrushDesc(BrushKind.ink, 'x'), line()).path).width + 0.001));
      final dots = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'dash': 1, 'dashGap': 1}), line()).outline.pieces.cast<OutlineRibbon>();
      expect(dots.length, 26, reason: 'a dot every 8, the last at the very end');
      expect(dots.every((d) => (d.points.first - d.points.last).distance < 1e-6), isTrue);
      // a very long line does not get more dashes than a line draws
      final long = line(points: const [Offset(0, 0), Offset(300000, 0)], width: 2);
      expect(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'dash': 1, 'dashGap': 0.2}), long).outline.pieces.length, lessThanOrEqualTo(3100));
      // the thickness follows the pressure inside a dash and at its cut ends
      final pressed = line(pressures: [for (var i = 0; i <= 100; i++) 30 + i * 2]);
      final p = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'dash': 3, 'pressure': 1}), pressed).outline.pieces.cast<OutlineRibbon>();
      expect(p.last.half.last, greaterThan(p.first.half.first * 2));
    });

    test('a shadow, a glow and an outline are drawn behind the line, the furthest first, and a line with none has nothing behind it', () {
      final stroke = line();
      expect(shapeOf(BrushDesc(BrushKind.ink, 'x'), stroke).under, isEmpty);
      expect(shapeOf(BrushDesc(BrushKind.stamp, 'x'), stroke).under, isEmpty);
      final base = bounds(shapeOf(BrushDesc(BrushKind.ink, 'x'), stroke).path);

      final shadow = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'shadow': 0.6, 'shadowDistance': 1}), stroke);
      expect(shadow.under.length, 1);
      expect(shadow.under.single.lightness, -1);
      expect(shadow.under.single.opacity, 0.6);
      // (it falls to the lower right: a distance of one width, here 4)
      final moved = bounds(shadow.under.single.path).topLeft - bounds(shadow.path).topLeft;
      expect(moved.dx, closeTo(0.6 * 4, 1e-6));
      expect(moved.dy, closeTo(0.8 * 4, 1e-6));
      expect(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'shadow': 0.6, 'shadowBlur': 1}), stroke).under.length, 4, reason: 'a blurred shadow is rings');

      final glow = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'glow': 1, 'glowHue': 90}), stroke);
      expect(glow.under.length, 3);
      final heights = [for (final l in glow.under) bounds(l.path).height];
      expect(heights, [...heights]..sort((a, b) => b.compareTo(a)), reason: 'the widest ring is first');
      expect(heights.first, greaterThan(base.height));
      expect(glow.under.every((l) => l.hue == 90 && l.vivid), isTrue);

      final outline = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'outline': 1, 'outlineTone': 1}), stroke);
      expect(outline.under.length, 1);
      expect(outline.under.single.opacity, 1);
      expect(outline.under.single.lightness, 1);
      // (as thick as the line, outline 1: a border of half a width on each side)
      expect(bounds(outline.under.single.path).height, closeTo(base.height + 4, 0.1));
      expect(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'outline': 1, 'outlineTone': 2}), stroke).under.single.hue, 180);

      final all = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'glow': 1, 'shadow': 0.5, 'outline': 0.5}), stroke);
      expect(all.under.length, 5);
      expect(all.under.last.opacity, 1, reason: 'the outline is the last thing behind the line');
      // stamps have them too: every dab gets bigger
      final stamp = BrushDesc(BrushKind.stamp, 'x', const {'outline': 1, 'spacing': 2});
      final dabs = shapeOf(stamp, stroke);
      expect(dabs.under.length, 1);
      expect(bounds(dabs.under.single.path).height, greaterThan(bounds(dabs.path).height));
    });

    test('the colour changes along the line in pieces, in as few layers as there can be', () {
      final stroke = line();
      Set<double> hues(BrushShape s) => {for (final l in s.layers) l.hue};

      final gradient = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'gradientHue': 120}), stroke);
      expect(hues(gradient).reduce(math.max), closeTo(120, 1e-6));
      expect(hues(gradient).reduce(math.min), 0, reason: 'it begins as the colour of the line');
      expect(gradient.layers.every((l) => l.vivid), isTrue, reason: 'a turn of the hue needs a colour to turn: a black pen is given one');
      final lighter = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'gradientLight': 0.5}), stroke);
      expect(lighter.outline.pieces, isNotEmpty, reason: 'a lightness needs no colour to turn: the start is the line\'s own colour');
      expect(lighter.layers.every((l) => !l.vivid), isTrue);

      final fadeOut = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'fade': 0.8}), stroke);
      expect(fadeOut.layers.map((l) => l.opacity).reduce(math.min), closeTo(0.2, 0.001));
      final faintest = fadeOut.layers.reduce((a, b) => a.opacity < b.opacity ? a : b);
      expect(bounds(faintest.path).center.dx, greaterThan(bounds(fadeOut.path).center.dx), reason: 'it fades towards the end');
      final fadeIn = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'fade': -0.8}), stroke);
      final fresh = fadeIn.layers.reduce((a, b) => a.opacity < b.opacity ? a : b);
      expect(bounds(fresh.path).center.dx, lessThan(100), reason: 'it comes out of nothing at the start');

      final rainbow = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'rainbow': 10}), stroke);
      expect(rainbow.outline.pieces, isEmpty, reason: 'every part is a colour of its own');
      expect(hues(rainbow).length, greaterThan(6));
      for (final l in rainbow.layers) {
        // (on a black pen too: there is a colour to turn)
        expect(HSLColor.fromColor(l.colorOf(Colors.black)).saturation, greaterThan(0.5));
      }
      // the rainbow turns once round in the length it is given: 10 widths is 40, so the colours come back after 40
      final byPlace = <double, double>{};
      for (final l in rainbow.layers) {
        for (final piece in l.outline.pieces) {
          final x = piece is OutlinePolygon ? piece.points.map((q) => q.dx).reduce((a, b) => a + b) / piece.points.length : 0.0;
          if (x > 0 && x < 18) byPlace[x] = l.hue;
        }
      }
      expect(byPlace, isNotEmpty);

      // pressed hard is darker when it is asked to be
      final jump = line(pressures: [for (var i = 0; i <= 100; i++) i < 50 ? 30 : 250]);
      final shade = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'pressureShade': -1}), jump);
      final lightnesses = {for (final l in shade.layers) l.lightness};
      expect(lightnesses.any((l) => (l - 0.32).abs() < 0.01), isTrue);
      expect(lightnesses.any((l) => (l + 0.32).abs() < 0.01), isTrue);

      // never more layers than the app draws, however many colours are asked for
      final wild = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'rainbow': 1, 'lightness': 1, 'hue': 60, 'gradientHue': 100, 'fade': 0.9}), stroke);
      expect(wild.layers.length + wild.outline.pieces.length.clamp(0, 1), lessThanOrEqualTo(40));

      // stamps have the same
      final stamps = shapeOf(BrushDesc(BrushKind.stamp, 'x', const {'rainbow': 5, 'fade': 0.5}), stroke);
      expect(stamps.layers, isNotEmpty);
      expect(stamps.layers.every((l) => l.vivid), isTrue);
      expect(stamps.layers.map((l) => l.opacity).reduce(math.min), lessThan(0.7));
    });

    test('colour along a dashed line follows the line, and a rainbow keeps its pieces apart', () {
      final s = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'rainbow': 6, 'dash': 2, 'opacity': 0.6}), line());
      expect(s.layers, isNotEmpty);
      expect(s.layers.every((l) => l.opacity <= 0.6 + 1e-9), isTrue);
    });

    test('the pressure curve gives the thickness at every pressure, and takes the place of the pressure numbers', () {
      const curve = {'pressureAt0': 0.2, 'pressureAt25': 0.2, 'pressureAt50': 1.8, 'pressureAt75': 0.4, 'pressureAt100': 1.5};
      final pressed = line(width: 6, pressures: [for (var i = 0; i <= 100; i++) 128]);
      final half = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', curve), pressed));
      final expected = curveValue([0.2, 0.2, 1.8, 0.4, 1.5], 128 / 255);
      expect(half.toSet().length, 1);
      expect(half.first, closeTo(6 * expected / 2, 1e-9));
      // (the numbers it takes the place of do nothing now)
      expect(halves(shapeOf(BrushDesc(BrushKind.ink, 'x', {...curve, 'pressure': 1, 'pressureCurve': 3}), pressed)), half);
      // (without a pressure there is nothing to bend)
      final none = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', curve), line(width: 6)));
      expect(none.toSet(), {3.0});
      expect(BrushDesc(BrushKind.ink, 'x', curve).build().usesPressure, isTrue);
      expect(BrushDesc(BrushKind.ink, 'x', const {'pressureShade': 1}).build().usesPressure, isTrue);
      // (a curve with only some of its points: the others are 1)
      expect(BrushDesc(BrushKind.ink, 'x', const {'pressureAt50': 2}).build(), isA<ParamBrush>());
      expect((BrushDesc(BrushKind.ink, 'x', const {'pressureAt50': 2}).build() as ParamBrush).params.pressurePoints, [1.0, 1.0, 2.0, 1.0, 1.0]);
      expect((BrushDesc(BrushKind.ink, 'x').build() as ParamBrush).params.pressurePoints, isNull);
    });

    test('the speed curve gives the thickness at every speed', () {
      // (at an even pace the hand goes at the usual speed: the middle of the curve)
      for (final mid in [0.5, 1.0, 1.5]) {
        final half = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', {'speedAt50': mid, 'smoothing': 0}), line(width: 4)));
        expect(half[half.length ~/ 2], closeTo(4 * mid / 2, 1e-9));
      }
      // a fast part is where the right of the curve is
      final fastAtEnd = line(points: [for (var i = 0; i < 40; i++) Offset(i * 1.0, 10), for (var i = 1; i <= 40; i++) Offset(40 + i * 6.0, 10)], width: 4);
      final half = halves(shapeOf(BrushDesc(BrushKind.ink, 'x', const {'speedAt0': 1, 'speedAt25': 1, 'speedAt50': 1, 'speedAt75': 0.4, 'speedAt100': 0.2, 'smoothing': 0}), fastAtEnd));
      expect(half.last, lessThan(half.first * 0.7));
    });

    test('a steady hand evens out a shaky line and leaves its ends where they are', () {
      final shaky = line(points: [for (var i = 0; i < 60; i++) Offset(i * 4.0, 40 + (i.isEven ? 8 : -8))]);
      double spread(BrushShape s) {
        // (not the ends: they stay where they are)
        final ys = [for (final p in (s.outline.pieces.single as OutlineRibbon).points.sublist(8, 52)) p.dy];
        return ys.reduce(math.max) - ys.reduce(math.min);
      }

      final plain = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'smoothing': 0}), shaky);
      final steady = shapeOf(BrushDesc(BrushKind.ink, 'x', const {'smoothing': 0, 'stabilise': 1}), shaky);
      expect(spread(steady), lessThan(spread(plain) / 2));
      final ends = (steady.outline.pieces.single as OutlineRibbon).points;
      expect(ends.first, shaky.points.first);
      expect(ends.last, shaky.points.last);
    });

    group('a mix', () {
      final ink = BrushDesc(BrushKind.ink, 'ink', const {'width': 2});
      final charcoal = BrushDesc(BrushKind.charcoal, 'coal');
      final stars = BrushDesc(BrushKind.stamp, 'stars', const {'shape': 3});

      test('draws the second brush over the first, made as thick as that brush makes its lines, or under it', () {
        final stroke = line(width: 4);
        final over = BrushDesc(BrushKind.mix, 'x', const {}, [ink, charcoal]);
        final shape = shapeOf(over, stroke);
        expect(shape.line, isNull);
        expect(shape.next, isNotNull);
        // (the charcoal makes its lines three times as thick as the ink does)
        expect(shape.next!.line!.width, closeTo(4 * 3 / 2, 1e-9));
        expect(shape.next!.line!.points, stroke.points);
        expect(over.build().widthScale, 2, reason: 'the first sets the width');
        final bigger = shapeOf(BrushDesc(BrushKind.mix, 'x', const {'sizeB': 2}, [ink, charcoal]), stroke);
        expect(bigger.next!.line!.width, closeTo(2 * shape.next!.line!.width, 1e-9));
        final under = shapeOf(BrushDesc(BrushKind.mix, 'x', const {'underneath': 1}, [ink, charcoal]), stroke);
        expect(under.line, isNotNull, reason: 'the second is first now');
        expect(under.next!.line, isNull);
      });

      test('is read as writing only if both parts are, and uses pressure if one does', () {
        expect(BrushDesc(BrushKind.mix, 'x', const {}, [ink, ink]).build().writing, isTrue);
        expect(BrushDesc(BrushKind.mix, 'x', const {}, [ink, stars]).build().writing, isFalse);
        expect(BrushDesc(BrushKind.mix, 'x', const {}, [ink, ink]).build().usesPressure, isFalse);
        expect(BrushDesc(BrushKind.mix, 'x', const {}, [ink, charcoal]).build().usesPressure, isTrue);
      });

      test('has an id made of the numbers and of the ids of its parts, not of their names, and changing a part changes it', () {
        final a = BrushDesc(BrushKind.mix, 'x', const {}, [ink, stars]);
        expect(BrushDesc(BrushKind.mix, 'y', const {}, [ink.named('other'), stars.named('names')]).id, a.id);
        expect(a.withPart(1, charcoal).id, isNot(a.id));
        expect(a.withPart(0, ink.withValue('width', 3)).id, isNot(a.id));
        expect(BrushDesc(BrushKind.mix, 'x', const {}, [stars, ink]).id, isNot(a.id));
      });

      test('is made of two brushes that are not mixes; any other kind has no parts', () {
        final mix = BrushDesc(BrushKind.mix, 'x');
        expect(mix.parts.length, 2, reason: 'an ink and a charcoal to begin with');
        expect(() => BrushDesc(BrushKind.mix, 'x', const {}, [mix, ink]), throwsA(isA<BrushDescException>()));
        expect(() => BrushDesc(BrushKind.mix, 'x', const {}, [ink]), throwsA(isA<BrushDescException>()));
        expect(() => BrushDesc(BrushKind.mix, 'x', const {}, [ink, ink, ink]), throwsA(isA<BrushDescException>()));
        expect(BrushDesc(BrushKind.ink, 'x', const {}, [ink, stars]).parts, isEmpty);
      });

      test('every pair of kinds can be mixed and drawn, also a line of one point', () {
        final kinds = [for (final k in BrushKind.values) if (k != BrushKind.mix) BrushDesc(k, k.name)];
        for (final a in kinds) {
          for (final b in kinds) {
            final mix = BrushDesc(BrushKind.mix, 'x', const {}, [a, b]);
            expect(mix.build().shape(line()), isNotNull, reason: '${a.kind.name} + ${b.kind.name}');
            expect(() => mix.build().shape(line(points: const [Offset(5, 5)])), returnsNormally);
          }
        }
      });

      test('travels in a file, in a live session and as text, with its parts, and the parts of a part are not read', () {
        final mix = BrushDesc(BrushKind.mix, 'Mixed', const {'sizeB': 1.5, 'underneath': 1}, [ink, stars]);
        final same = BrushDesc.fromBytes(mix.toBytes());
        expect(same, mix);
        expect(same.id, mix.id);
        expect(BrushDesc.fromCompactJson(mix.toCompactJson()), mix);
        expect(BrushDesc.fromCode(mix.toCode()), mix);
        // a mix in a mix, in a file or a line of a session, is turned away (and without going down level after level)
        Map<String, Object?> deep(int n) => n == 0 ? ink.toCompactJson() : {'k': 'mix', 'n': 'm', 'p': <String, Object?>{}, 'parts': [deep(n - 1), ink.toCompactJson()]};
        expect(BrushDesc.fromCompactJson(deep(1)).parts.length, 2, reason: 'two inks are a mix');
        expect(() => BrushDesc.fromCompactJson(deep(2)), throwsA(isA<BrushDescException>()));
        expect(() => BrushDesc.fromCompactJson(deep(3000)), throwsA(isA<BrushDescException>()));
        final file = {...mix.toJson(), 'parts': [mix.toJson(), ink.toJson()]};
        expect(() => BrushDesc.fromJson(file), throwsA(isA<BrushDescException>()));
        expect(() => BrushDesc.fromJson({...mix.toJson(), 'parts': [ink.toJson()]}), throwsA(isA<BrushDescException>()));
      });

      test('is a brush of the app once it is there, and is equal to the same mix', () {
        final mix = BrushDesc(BrushKind.mix, 'x', const {}, [ink, stars]);
        CustomBrushes.sync([(desc: mix, listed: true)]);
        expect(Brushes.byId(mix.id), isA<MixBrush>());
        expect(mix.build(), mix.build());
        expect(mix.build(), isNot(mix.withPart(1, charcoal).build()));
      });
    });

    test('a brush as a line of text comes back the same, whatever is around it, and what is not a brush is turned away', () {
      final d = BrushDesc(BrushKind.ink, 'Neon', const {'glow': 1.5, 'dash': 2, 'pressureAt0': 0.5});
      final code = d.toCode();
      expect(code, startsWith(BrushDesc.codePrefix));
      expect(code, isNot(contains('\n')));
      expect(BrushDesc.fromCode(code), d);
      expect(BrushDesc.fromCode('  \n$code\n '), d);
      expect(BrushDesc.fromCode('${code.substring(0, 30)}\n${code.substring(30)}'), d, reason: 'a message may break a long line');
      expect(BrushDesc.fromCode(String.fromCharCodes(d.toBytes())), d, reason: 'the text of a .strokedesc is taken as well');
      for (final junk in ['', 'hello', '${BrushDesc.codePrefix}!!!', BrushDesc.codePrefix, '${BrushDesc.codePrefix}${base64Url.encode(utf8.encode('[]'))}', '${BrushDesc.codePrefix}${base64Url.encode(utf8.encode('{"k":"glitter"}'))}', 'x' * 40000]) {
        expect(() => BrushDesc.fromCode(junk), throwsA(isA<BrushDescException>()), reason: junk.length > 50 ? 'long' : junk);
      }
    });

    test('several numbers can be set at once', () {
      final d = BrushDesc(BrushKind.ink, 'x', const {'width': 2, 'startTaper': 0.3}).withValues({'width': 3, 'startTaper': null, 'glow': 1});
      expect(d['width'], 3);
      expect(d['startTaper'], isNull);
      expect(d['glow'], 1);
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

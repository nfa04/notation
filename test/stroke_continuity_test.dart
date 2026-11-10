import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/point_codec.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';

Future<Uint8List> _render(DrawingStroke s, int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  UnifiedInkPainter(strokes: [s]).paint(c, Size(w.toDouble(), h.toDouble()));
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData())!.buffer.asUint8List();
}

DrawingStroke _wave(bool varyPressure, {bool reverse = false}) {
  final pts = [for (var i = 0; i <= 400; i++) Offset(10 + i * 0.5, 50 + 20 * math.sin(i * 0.05))];
  final pr = [for (var i = 0; i <= 400; i++) varyPressure ? 60 + (i * 7) % 150 : 200];
  return DrawingStroke(color: Colors.black, width: 4, points: reverse ? pts.reversed.toList() : pts, pressures: reverse ? pr.reversed.toList() : pr);
}

void main() {
  for (final rev in [false, true]) {
    for (final vary in [false, true]) {
      testWidgets('pressure stroke has no gaps (reverse=$rev vary=$vary)', (t) async {
        final s = _wave(vary, reverse: rev);
        final px = (await t.runAsync(() => _render(s, 230, 100)))!;
        var gaps = 0;
        for (var i = 0; i < s.points.length; i++) {
          final x = s.points[i].dx.round(), y = s.points[i].dy.round();
          if (px[(y * 230 + x) * 4 + 3] < 200) gaps++;
        }
        expect(gaps, 0, reason: 'centerline pixels left unpainted');
      });
    }
  }

  testWidgets('sharp handwriting turns leave no gaps', (t) async {
    final pts = <Offset>[];
    for (var i = 0; i < 300; i++) {
      pts.add(Offset(10 + i * 0.6 + (i % 7 < 3 ? 0 : -1.5), 50 + 25 * math.sin(i * 0.9) * (i % 11 == 0 ? 0.2 : 1)));
    }
    final s = DrawingStroke(color: Colors.black, width: 5, points: pts, pressures: [for (var i = 0; i < pts.length; i++) 40 + (i * 13) % 200]);
    final px = (await t.runAsync(() => _render(s, 230, 100)))!;
    var gaps = 0;
    for (final p in pts) {
      if (px[(p.dy.round() * 230 + p.dx.round()) * 4 + 3] < 200) gaps++;
    }
    expect(gaps, 0);
  });

  test('codec keeps every point', () {
    final pts = [for (var i = 0; i < 1000; i++) Offset(i * 0.37, i * 0.11)];
    final back = decodePoints(encodePoints(pts));
    expect(back.length, pts.length);
  });
}

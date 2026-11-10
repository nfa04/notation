import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/painters/soft_strokes.dart';

DrawingStroke airbrush(String id, {int points = 30, double width = 20}) => DrawingStroke(
      id: id,
      color: Colors.black,
      width: width,
      points: [for (var i = 0; i < points; i++) Offset(20 + i * 8.0, 40 + (i % 7))],
      brush: 'airbrush',
    );

void frame(SoftRaster r, List<DrawingStroke> strokes) {
  final canvas = Canvas(ui.PictureRecorder());
  for (final s in strokes) {
    r.paint(canvas, s, brushShape(s)!.soft!, 1);
  }
}

void main() {
  group('soft strokes', () {
    test('the airbrush has blurred layers for the screen and keeps its vector layers for the PDF', () {
      final shape = brushShape(airbrush('a'))!;
      expect(shape.soft, isNotNull);
      expect(shape.soft!.blurred, isNotEmpty);
      expect(shape.layers, isNotEmpty);
      expect(shape.soft!.bounds.width, greaterThan(200));
    });

    test('the pen, the pencil and the other brushes have none, so their drawing is as it was', () {
      final pen = DrawingStroke(id: 'p', color: Colors.black, width: 2, points: [const Offset(0, 0), const Offset(10, 10)]);
      expect(brushShape(pen), isNull);
      for (final b in [Brushes.pencil, Brushes.fountain, Brushes.calligraphy, Brushes.marker, Brushes.roller]) {
        final s = DrawingStroke(id: 'q', color: Colors.black, width: 4, points: [for (var i = 0; i < 20; i++) Offset(i * 5.0, 3.0 * (i % 3))], brush: b.id);
        expect(b.shape(s)!.soft, isNull, reason: b.id);
      }
    });

    test('the charcoal is drawn for the screen through the grain of paper, and keeps its vector layers for the PDF', () {
      final s = DrawingStroke(id: 'c', color: Colors.black, width: 12, points: [for (var i = 0; i < 30; i++) Offset(i * 6.0, 3.0 * (i % 3))], brush: 'charcoal');
      final shape = brushShape(s)!;
      expect(shape.soft!.grain, isNotEmpty);
      expect(shape.layers, isNotEmpty);
      final r = SoftRaster();
      for (var f = 0; f < 3; f++) {
        frame(r, [s]);
      }
      expect(r.count, 1);
    });

    test('a line gets an image only when it stays as it is for a few frames', () {
      final r = SoftRaster();
      final line = airbrush('a');
      frame(r, [line]);
      frame(r, [line]);
      expect(r.count, 0);
      frame(r, [line]);
      expect(r.count, 1);
      expect(r.bytes, greaterThan(0));
    });

    test('a line that changes at every frame (the one being drawn) never gets one', () {
      final r = SoftRaster();
      for (var n = 5; n < 20; n++) {
        frame(r, [airbrush('live', points: n)]);
      }
      expect(r.count, 0);
    });

    test('images stay within the memory budget, the longest unused first to go', () {
      final r = SoftRaster(budget: 300 * 1024);
      final lines = [for (var i = 0; i < 8; i++) airbrush('l$i')];
      for (var f = 0; f < 4; f++) {
        frame(r, lines);
      }
      expect(r.bytes, lessThanOrEqualTo(300 * 1024));
      expect(r.count, lessThan(8));
      r.clear();
      expect(r.count, 0);
      expect(r.bytes, 0);
    });
  });
}

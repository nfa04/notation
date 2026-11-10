import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/brush_desc.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';

/// The pixels (red channel) of [strokes] drawn on white, 200 x 80.
Future<Uint8List> _draw(List<DrawingStroke> strokes) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 200, 80), Paint()..color = Colors.white);
  paintStrokes(canvas, strokes, 0.6);
  final image = await recorder.endRecording().toImage(200, 80);
  final data = (await image.toByteData())!;
  image.dispose();
  return data.buffer.asUint8List();
}

int _red(Uint8List px, int x, int y) => px[(y * 200 + x) * 4];

DrawingStroke _line(String brush, {double width = 6}) =>
    DrawingStroke(id: 'paint-$brush', color: Colors.black, width: width, points: [for (var i = 0; i <= 36; i++) Offset(10.0 + i * 5, 40)], brush: brush);

void main() {
  tearDown(() => CustomBrushes.sync(const []));

  testWidgets('the page draws what is behind a line behind it, and the line over it', (tester) async {
    final shadowed = BrushDesc(BrushKind.ink, 'shadow', const {'width': 1, 'shadow': 0.6, 'shadowDistance': 1, 'smoothing': 0});
    final plain = BrushDesc(BrushKind.ink, 'plain', const {'width': 1, 'smoothing': 0});
    CustomBrushes.sync([(desc: shadowed, listed: true), (desc: plain, listed: true)]);
    await tester.runAsync(() async {
      final withShadow = await _draw([_line(shadowed.id)]);
      final without = await _draw([_line(plain.id)]);
      // (the line is 6 thick, from 37 to 43; the shadow falls 3.6 right and 4.8 down: it shows from 43 to 47.8)
      expect(_red(withShadow, 100, 40), lessThan(10), reason: 'the line is over its shadow');
      expect(_red(without, 100, 46), 255);
      final under = _red(withShadow, 100, 46);
      expect(under, inInclusiveRange(80, 130), reason: 'a shadow is the colour of the line made black, 60 % dark: about 102');
      expect(_red(withShadow, 100, 30), 255, reason: 'and nothing above the line');
    });
  });

  testWidgets('a mix draws both of its brushes, the second over the first or under it, whatever the page does with the lines', (tester) async {
    final ink = BrushDesc(BrushKind.ink, 'ink', const {'width': 1, 'smoothing': 0});
    final bars = BrushDesc(BrushKind.stamp, 'squares', const {'width': 3, 'shape': 1, 'spacing': 1, 'sizeJitter': 0, 'opacity': 0.5});
    final mix = BrushDesc(BrushKind.mix, 'mix', const {}, [ink, bars]);
    final under = BrushDesc(BrushKind.mix, 'mix under', const {'underneath': 1}, [ink, bars]);
    CustomBrushes.sync([(desc: ink, listed: true), (desc: mix, listed: true), (desc: under, listed: true)]);
    await tester.runAsync(() async {
      final alone = await _draw([_line(ink.id)]);
      final mixed = await _draw([_line(mix.id)]);
      final beneath = await _draw([_line(under.id)]);
      // (the squares are 3 x the width of the ink: 18 across, so they show well outside the 6 of the ink)
      expect(_red(alone, 100, 33), 255);
      expect(_red(mixed, 100, 33), lessThan(255));
      expect(_red(beneath, 100, 33), lessThan(255));
      // over: the half see-through squares are over the ink and darken it nowhere more than black; under: the ink is over them
      expect(_red(mixed, 100, 40), lessThan(10));
      expect(_red(beneath, 100, 40), lessThan(10));
      // lines of a mix and lines of the pen in one picture do not disturb each other
      final both = await _draw([_line(penBrushId), _line(mix.id)]);
      expect(_red(both, 100, 33), lessThan(255));
    });
  });
}

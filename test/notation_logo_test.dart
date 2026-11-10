import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/widgets/notation_logo.dart';

void main() {
  // The logo is drawn twice with the same numbers: branding/make_icons.py makes the icon files, NotationLogo draws it in the
  // app. This looks at a few points, in a picture of 256 pixels, to see that the painter still draws what the icon shows.
  testWidgets('draws the tile, the ink, the pen and its amber tip', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: RepaintBoundary(key: key, child: const NotationLogo(size: 256, color: AppTheme.defaultAccent))),
    ));
    late ByteData data;
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      data = (await image.toByteData())!;
    });
    Color at(int x, int y) {
      final i = (y * 256 + x) * 4;
      return Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
    }

    expect(at(0, 0).a, 0, reason: 'outside the rounded corner');
    final tile = at(25, 128);
    expect(tile.b, greaterThan(tile.r), reason: 'the tile is blue');
    expect(at(73, 128), const Color(0xFFFFFFFF), reason: 'the left stem is white');
    expect(at(183, 195), NotationLogoPainter.amber, reason: 'the tip of the pen is amber');
    expect(at(183, 50), const Color(0xFFFFFFFF), reason: 'the body of the pen is white');
  });

  testWidgets('takes the colour of the accent', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: RepaintBoundary(key: key, child: const NotationLogo(size: 256, color: Color(0xFFE53935)))),
    ));
    late ByteData data;
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      data = (await (await boundary.toImage()).toByteData())!;
    });
    final i = (128 * 256 + 25) * 4;
    expect(data.getUint8(i), greaterThan(data.getUint8(i + 2)), reason: 'a red accent gives a red tile');
  });
}

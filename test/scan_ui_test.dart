import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/screens/scan_screen.dart';
import 'package:notes/scan/doc_scan.dart';

void main() {
  testWidgets('a photographed page is straightened and handed back, with the corners where the page is', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final image = img.Image(width: 640, height: 480, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(50, 45, 40));
    img.fillPolygon(image, vertices: [img.Point(90, 60), img.Point(560, 40), img.Point(590, 430), img.Point(70, 420)], color: img.ColorRgb8(235, 235, 230));
    for (var i = 0; i < 5; i++) {
      img.drawLine(image, x1: 140, y1: 110 + i * 50, x2: 500, y2: 107 + i * 50, color: img.ColorRgb8(20, 20, 20), thickness: 6);
    }
    final bytes = img.encodePng(image);

    ScanResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await scanPage(context, bytes),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    for (var i = 0; i < 20 && find.byKey(const ValueKey('scan-corner-0')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('scan-corner-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-read')), findsNothing); // (no text reader given)

    await tester.tap(find.byKey(const ValueKey('scan-filter-blackWhite')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('scan-done')));
    await tester.pump();
    for (var i = 0; i < 40 && result == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(result, isNotNull);
    expect(result!.isPng, isTrue); // (black and white is kept as a PNG)
    final page = img.decodeImage(result!.page)!;
    expect(page.width, greaterThan(400));
    expect(page.getPixel(8, 8).r, greaterThan(200));
    expect(result!.text, isNull);
    expect(ScanFilter.values, hasLength(3));
    await tester.pumpAndSettle();
  });
}

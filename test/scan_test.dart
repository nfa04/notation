import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/scan/doc_scan.dart';
import 'package:notes/scan/ocr_geometry.dart';
import 'package:notes/scan/ocr_service.dart';
import 'package:path/path.dart' as p;

/// A photograph of a page: a light, slightly turned sheet on a dark table, with lines of "text" on it.
img.Image photo() {
  final image = img.Image(width: 640, height: 480, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(50, 45, 40));
  img.fillPolygon(image, vertices: [img.Point(90, 60), img.Point(560, 40), img.Point(590, 430), img.Point(70, 420)], color: img.ColorRgb8(235, 235, 230));
  for (var i = 0; i < 6; i++) {
    final y = 110 + i * 45;
    img.drawLine(image, x1: 140, y1: y, x2: 500, y2: y - 3, color: img.ColorRgb8(20, 20, 20), thickness: 6);
  }
  return image;
}

void main() {
  group('the page in a photograph', () {
    test('its corners are found', () {
      final c = findPageCorners(photo());
      expect(c, hasLength(4));
      final want = [const Offset(90 / 640, 60 / 480), const Offset(560 / 640, 40 / 480), const Offset(590 / 640, 430 / 480), const Offset(70 / 640, 420 / 480)];
      for (var i = 0; i < 4; i++) {
        expect((c[i] - want[i]).dx.abs(), lessThan(0.03), reason: 'corner $i');
        expect((c[i] - want[i]).dy.abs(), lessThan(0.03), reason: 'corner $i');
      }
    });

    test('a picture with no page in it gets corners a little inside', () {
      final plain = img.Image(width: 300, height: 200, numChannels: 3);
      img.fill(plain, color: img.ColorRgb8(120, 120, 120));
      expect(findPageCorners(plain).first, const Offset(0.05, 0.05));
    });

    test('straightening gives an upright page: paper at the edges, print where the lines were', () {
      final c = findPageCorners(photo());
      final page = straightenPage(photo(), c);
      expect(page.width, greaterThan(400));
      expect(page.height, greaterThan(300));
      final corner = page.getPixel(8, 8);
      expect(corner.r, greaterThan(200));
      // there are dark rows (the lines) and light rows between
      var darkRows = 0;
      for (var y = 0; y < page.height; y++) {
        var dark = 0;
        for (var x = page.width ~/ 4; x < page.width * 3 ~/ 4; x += 4) {
          if (page.getPixel(x, y).r < 90) dark++;
        }
        if (dark > 10) darkRows++;
      }
      expect(darkRows, greaterThan(10));
    });

    test('the filters make the paper white and keep the print', () {
      final page = straightenPage(photo(), findPageCorners(photo()));
      for (final f in [ScanFilter.clean, ScanFilter.blackWhite]) {
        final out = applyFilter(page, f);
        expect(out.getPixel(10, 10).r, greaterThan(220), reason: f.name);
        var dark = 0;
        for (var y = 0; y < out.height; y += 2) {
          for (var x = 0; x < out.width; x += 2) {
            if (out.getPixel(x, y).r < 90) dark++;
          }
        }
        expect(dark, greaterThan(200), reason: f.name);
      }
      final black = applyFilter(page, ScanFilter.blackWhite);
      for (var x = 0; x < black.width; x += 37) {
        final v = black.getPixel(x, 20).r;
        expect(v == 0 || v == 255, isTrue);
      }
    });
  });

  group('reading a picture', () {
    test('lines of text are found in the detector\'s map, widened and put back to the size of the picture', () {
      final map = Float32List(100 * 50);
      for (var y = 10; y < 16; y++) {
        for (var x = 10; x < 80; x++) {
          map[y * 100 + x] = 0.9;
        }
      }
      for (var x = 20; x < 30; x++) {
        map[40 * 100 + x] = 0.9; // a speck, one pixel high
      }
      final boxes = findTextBoxes(map, 100, 50, 200, 100);
      expect(boxes, hasLength(1));
      expect(boxes.single.rect.left, lessThan(20));
      expect(boxes.single.rect.right, greaterThan(160));
      expect(boxes.single.rect.top, lessThan(20));
      expect(boxes.single.rect.bottom, greaterThan(32));
    });

    test('the reader\'s scores become text: repeats joined, blanks dropped', () {
      final alphabet = readerAlphabet('a\nb\nc\n');
      expect(alphabet, ['', 'a', 'b', 'c', ' ']);
      // steps: a a blank b b blank blank b c
      final ids = [1, 1, 0, 2, 2, 0, 0, 2, 3];
      final scores = <double>[];
      for (final id in ids) {
        scores.addAll([for (var c = 0; c < 5; c++) c == id ? 0.9 : 0.025]);
      }
      final r = decodeCtc(scores, ids.length, 5, alphabet);
      expect(r.text, 'abbc');
      expect(r.confidence, closeTo(0.9, 1e-9));
    });

    test('lines are put in reading order, side by side joined, big gaps are blank lines', () {
      OcrLine l(String t, double x, double y) => OcrLine(t, Rect.fromLTWH(x, y, 100, 20), 1);
      final page = OcrPage([l('second', 10, 40), l('right', 200, 0), l('left', 10, 2), l('far below', 10, 200)], 400, 300);
      expect(page.text, 'left  right\nsecond\n\nfar below');
    });

    test('a page is read with the models (stand-ins here): lines found, read, and put together', () async {
      final dir = await Directory.systemTemp.createTemp('ocr');
      addTearDown(() => dir.delete(recursive: true));
      final settings = <String, String>{};
      final service = OcrService(
        (k) async => settings[k],
        (k, v) async => settings[k] = v,
        modelDirectory: (id) async => Directory(p.join(dir.path, id)),
        models: (_, _) => _FakeModels(),
      );
      await service.load();
      expect(service.installed, isFalse);
      expect(() => service.recognize(Uint8List(0)), throwsStateError);
      await Directory(p.join(dir.path, 'latin')).create();
      for (final n in ['det.onnx', 'rec.onnx']) {
        await File(p.join(dir.path, 'latin', n)).writeAsBytes([0]);
      }
      await File(p.join(dir.path, 'latin', 'dict.txt')).writeAsString('h\ni\n');
      await service.load();
      expect(service.installed, isTrue);

      final picture = img.Image(width: 320, height: 160, numChannels: 3);
      img.fill(picture, color: img.ColorRgb8(255, 255, 255));
      final page = await service.recognize(img.encodePng(picture));
      expect(page.text, 'hi');
      expect(page.lines.single.rect.width, greaterThan(100));

      await service.setLanguage(OcrLanguage.all[1]);
      expect(settings[OcrService.languageKey], 'eslav');
      expect(service.installed, isFalse); // (another script: other files)
    });
  });
}

class _FakeModels implements OcrModels {
  @override
  Future<Float32List> detect(DetectorInput input) async {
    final map = Float32List(input.width * input.height);
    for (var y = input.height ~/ 4; y < input.height ~/ 4 + 8; y++) {
      for (var x = 40; x < input.width - 40; x++) {
        map[y * input.width + x] = 0.95;
      }
    }
    return map;
  }

  @override
  Future<({List<double> scores, int steps, int classes})> read(ReaderInput input) async {
    // classes: blank, h, i, space; steps: h i
    final ids = [1, 2];
    final scores = <double>[];
    for (final id in ids) {
      scores.addAll([for (var c = 0; c < 4; c++) c == id ? 0.9 : 0.03]);
    }
    return (scores: scores, steps: 2, classes: 4);
  }

  @override
  Future<void> close() async {}
}

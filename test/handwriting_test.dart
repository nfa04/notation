import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/handwriting_service.dart';
import 'package:notes/ink/math_decoder.dart' show formulaImageSize;
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke stroke(double left, double top, double right, double bottom, {Color color = const Color(0xFF000000)}) =>
    DrawingStroke(color: color, width: 3, points: [Offset(left, top), Offset((left + right) / 2, bottom), Offset(right, top)]);

void main() {
  group('grouping strokes', () {
    test('two lines come out top to bottom', () {
      final lines = groupIntoLines([
        stroke(0, 200, 40, 240), // second line, drawn first
        stroke(0, 0, 40, 40),
      ]);
      expect(lines.length, 2);
      expect(lines.first.single.bounds.top, 0);
      expect(lines.last.single.bounds.top, 200);
    });

    test('gaps split words, a few words make a chunk, long lines are cut', () {
      // eight "words" of one letter each, separated by gaps of half the line height
      final strokes = [for (var i = 0; i < 8; i++) stroke(i * 70.0, 0, i * 70.0 + 40, 40)];
      final lines = groupIntoLines(strokes, maxWords: 3, maxWidthPerHeight: 50);
      expect(lines.length, 1);
      expect(lines.single.map((c) => c.strokes.length), [3, 3, 2]);
      // chunks keep the reading order
      expect(lines.single.first.bounds.left, 0);
      expect(lines.single.last.bounds.left, 6 * 70.0);
    });

    test('strokes close together are one word', () {
      final lines = groupIntoLines([for (var i = 0; i < 5; i++) stroke(i * 45.0, 0, i * 45.0 + 40, 40)]);
      expect(lines.single.length, 1);
      expect(lines.single.single.strokes.length, 5);
    });

    test('a dot above a letter stays with its line', () {
      final lines = groupIntoLines([stroke(0, 10, 40, 60), stroke(18, 0, 22, 6)]);
      expect(lines.length, 1);
    });

    test('nothing to read gives no lines', () {
      expect(groupIntoLines([]), isEmpty);
      expect(groupIntoLines([DrawingStroke(color: const Color(0xFF000000), width: 3, points: [Offset.zero])]), isEmpty);
    });
  });

  test('ink is drawn black on white over the whole picture', () async {
    final pixels = await renderInkForModel([stroke(10, 10, 110, 60)]);
    expect(pixels.length, formulaImageSize * formulaImageSize * 3);
    expect(pixels.first, 1.0); // a corner is white
    expect(pixels.where((v) => v < 0.1).length, greaterThan(500)); // there is ink
    expect(pixels.where((v) => v > 0.1 && v < 0.9), isNotEmpty); // anti-aliased
  });

  group('the service', () {
    late Directory dir;
    final settings = <String, String>{};
    final read = <int>[];

    GlmOcrService glm({Future<void> Function(String, String, void Function(double))? download}) => GlmOcrService(
          modelDirectory: () async => Directory('${dir.path}/glm'),
          checksums: const {},
          loadVocab: () async => 'hello\nĠworld\n.\n',
          read: (vision, text, embeddings, pictures) async {
            read.add(pictures.length);
            return [for (var i = 0; i < pictures.length; i++) i == 0 ? [0, 1, 2] : [0]];
          },
          download: download ??
              (url, path, progress) async {
                File(path).writeAsBytesSync([1]);
                progress(1);
              },
        );

    HandwritingService service({GlmOcrService? g, Future<void> Function()? removeOld}) => HandwritingService(
          glm: g ?? glm(),
          readSetting: (k) async => settings[k],
          writeSetting: (k, v) async => settings[k] = v,
          removeOldFiles: removeOld ?? () async {},
        );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('handwriting_');
      settings.clear();
      read.clear();
    });
    tearDown(() => dir.delete(recursive: true));

    test('GLM-OCR reads unless the person chose another reader; an old choice of TrOCR is GLM-OCR now', () async {
      final fresh = service();
      await fresh.load();
      expect(fresh.reader, HandwritingReader.glm);
      settings[HandwritingService.readerKey] = 'trocr'; // (what an earlier version kept)
      final old = service();
      await old.load();
      expect(old.reader, HandwritingReader.glm);
    });

    test('starts without the model, installs it and removes it again', () async {
      final s = service();
      await s.load();
      expect(s.status, HandwritingStatus.notInstalled);
      await s.install();
      expect(s.error, isNull);
      expect(s.status, HandwritingStatus.installed);
      expect(File('${dir.path}/glm/vision.onnx').existsSync(), isTrue);
      expect(Directory('${dir.path}/glm').listSync().any((f) => f.path.endsWith('.part')), isFalse);

      final again = service();
      await again.load(); // (a new start finds it)
      expect(again.status, HandwritingStatus.installed);

      await s.remove();
      expect(s.status, HandwritingStatus.notInstalled);
      expect(Directory('${dir.path}/glm').existsSync(), isFalse);
    });

    test('what the TrOCR reader of earlier versions left behind is cleared away when the service starts', () async {
      var cleared = 0;
      await (service(removeOld: () async => cleared++)).load();
      expect(cleared, 1);
      // the real clearing goes to the app's folder; here the folder of the old files is what it deletes
      final old = Directory('${dir.path}/models/trocr')..createSync(recursive: true);
      File('${old.path}/encoder.onnx').writeAsBytesSync([1]);
      await service(removeOld: () async => old.deleteSync(recursive: true)).load();
      expect(old.existsSync(), isFalse);
    });

    test('a failing download is reported and leaves nothing behind', () async {
      final failing = service(g: glm(download: (_, _, _) async => throw const SocketException('offline')));
      await failing.install();
      expect(failing.status, HandwritingStatus.notInstalled);
      expect(failing.error, contains('offline'));
    });

    test('reads two lines (the pieces of a line are put together)', () async {
      final s = service();
      await s.install();
      final text = await s.recognize([
        stroke(0, 0, 40, 40),
        stroke(300, 0, 340, 40), // far to the right: the same line
        stroke(0, 200, 40, 240), // the next line
      ]);
      expect(read.single, 2); // (one picture for each line: the line is not wider than 24 times its height)
      expect(text, 'hello world.\nhello');
    });

    test('the highlighter is not read', () async {
      final s = service();
      await s.install();
      expect(await s.recognize([stroke(0, 0, 40, 40, color: const Color(0x59FFEB3B))]), '');
      expect(read, isEmpty);
    });

    test('refuses to read without the model', () async {
      expect(() => service().recognize([stroke(0, 0, 40, 40)]), throwsStateError);
    });
  });
}

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/ink/math_decoder.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke stroke(double left, double top, double right, double bottom, {Color color = const Color(0xFF000000)}) =>
    DrawingStroke(color: color, width: 3, points: [Offset(left, top), Offset((left + right) / 2, bottom), Offset(right, top)]);

class _ScriptedMath implements MathOcrModel {
  final List<int> says;
  final seenIds = <List<int>>[];
  bool closed = false, released = false;
  _ScriptedMath(this.says);

  @override
  Future<Object> encode(Float32List pixels) async => 'encoded';

  @override
  Future<int> nextToken(Object encoded, List<int> ids) async {
    expect(encoded, 'encoded');
    seenIds.add(List.of(ids));
    return says[seenIds.length - 1 < says.length ? seenIds.length - 1 : says.length - 1];
  }

  @override
  Future<void> release(Object encoded) async => released = true;

  @override
  Future<void> close() async => closed = true;
}

void main() {
  final vocab = MathVocab.parse(File('assets/math/vocab.txt').readAsStringSync());

  group('reading the ids the real model gave', () {
    // produced by the real ONNX files for rendered formulas (checked with onnxruntime)
    test('a fraction with a root', () {
      expect(
        vocab.decode([1, 64, 277, 262, 300, 307, 274, 307, 345, 261, 262, 269, 261, 270, 263, 418, 262, 282, 265, 262, 269, 261, 274, 338, 265, 262, 269, 261, 261, 2]),
        r'\frac{a\,+\,b}{2}=\sqrt{x^{2}+y^{2}}',
      );
    });

    test('an integral', () {
      expect(
        vocab.decode([1, 64, 370, 264, 262, 279, 261, 265, 262, 268, 261, 282, 265, 262, 269, 261, 296, 282, 270, 263, 277, 262, 268, 261, 262, 312, 261, 2]),
        r'\int_{0}^{1}x^{2}dx=\frac{1}{3}',
      );
    });

    test('a short one, and the command that needs its space', () {
      expect(vocab.decode([1, 41, 270, 305, 318, 265, 262, 269, 261, 2]), 'E=mc^{2}');
      expect(vocab.decode([1, 64, 720, 262, 281, 270, 268, 261, 262, 263, 731, 262, 284, 261, 262, 263, 357, 261, 261, 281, 270, 263, 277, 262, 284, 267, 284, 274, 268, 266, 261, 262, 269, 261, 2]),
          startsWith(r'\underset{i=1}{\overset{n}{\sum}}i='));
    });

    test('has the whole vocabulary', () {
      expect(vocab.tokens.length, 1868);
      expect(vocab.tokens[1], '<s>');
      expect(vocab.tokens[2], '</s>');
    });

    test('special tokens are left out', () {
      expect(vocab.decode([0, 1, 2, 3, 4]), '');
    });
  });

  group('tidying LaTeX', () {
    test('only the meaningless spaces go', () {
      expect(MathVocab.tidyLatex(r'\alpha x + \beta'), r'\alpha x+\beta');
      expect(MathVocab.tidyLatex(r'\frac { a } { b }'), r'\frac{a}{b}');
      expect(MathVocab.tidyLatex(r'x ^ { 2 } + 1'), r'x^{2}+1');
      expect(MathVocab.tidyLatex(r'\sin x'), r'\sin x');
    });

    test('text keeps its spaces', () {
      expect(MathVocab.tidyLatex(r'x \text { for all } y'), r'x\text{ for all }y');
      expect(MathVocab.tidyLatex(r'\text { if } { a } { b }'), r'\text{ if }{a}{b}');
    });

    test('nothing gives nothing', () {
      expect(MathVocab.tidyLatex('  '), '');
    });
  });

  group('decoding loop', () {
    test('feeds back what it said and stops at the end token', () async {
      final model = _ScriptedMath([10, 11, mathEosToken]);
      final ids = await greedyDecodeMath(model, Float32List(0));
      expect(ids, [mathStartToken, 10, 11, mathEosToken]);
      expect(model.seenIds, [
        [mathStartToken],
        [mathStartToken, 10],
        [mathStartToken, 10, 11],
      ]);
      expect(model.released, isTrue);
    });

    test('stops when it has said enough', () async {
      final ids = await greedyDecodeMath(_ScriptedMath([7]), Float32List(0), maxTokens: 12);
      expect(ids.length, 12);
    });
  });

  test('the picture is channels first and runs from -1 to 1', () {
    // two different pixels, the rest white
    final rgb = Float32List(384 * 384 * 3)..fillRange(0, 384 * 384 * 3, 1.0);
    rgb.setRange(0, 3, [0.0, 0.5, 1.0]); // first pixel: R=0 G=.5 B=1
    final input = toModelInput(rgb);
    expect(input.length, 3 * 384 * 384);
    expect(input[0], -1.0); // red plane, first pixel
    expect(input[384 * 384], 0.0); // green plane, first pixel
    expect(input[2 * 384 * 384], 1.0); // blue plane, first pixel
    expect(input[1], 1.0); // a white pixel
  });

  group('the service', () {
    late Directory dir;
    late _ScriptedMath model;
    late MathService service;
    final downloads = <String>[];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('math_');
      downloads.clear();
      model = _ScriptedMath([41, 270, 305, 318, 265, 262, 269, 261, mathEosToken]); // E = m c ^ { 2 }
      service = MathService(
        defaultModel: FormulaModel.pix2text,
        modelDirectory: () async => Directory('${dir.path}/m'),
        loadVocab: () async => File('assets/math/vocab.txt').readAsStringSync(),
        open: (enc, dec) async {
          expect(File(enc).existsSync(), isTrue);
          expect(File(dec).existsSync(), isTrue);
          return model;
        },
        download: (url, path, progress) async {
          downloads.add(url);
          File(path).writeAsBytesSync([1, 2, 3]);
          progress(0.5);
          progress(1);
        },
      );
    });
    tearDown(() => dir.delete(recursive: true));

    test('downloads both files, remembers them, and removes them', () async {
      await service.load();
      expect(service.status, HandwritingStatus.notInstalled);

      await service.install();
      expect(service.error, isNull);
      expect(service.status, HandwritingStatus.installed);
      expect(downloads.length, 2);
      expect(downloads.every((u) => u.contains('pix2text-mfr-1.5')), isTrue);
      expect(service.progress, closeTo(1, 1e-9));
      expect(Directory('${dir.path}/m').listSync().map((f) => f.path.split('/').last).toList()..sort(),
          ['decoder_model.onnx', 'encoder_model.onnx']); // no .part left

      final again = MathService(defaultModel: FormulaModel.pix2text, modelDirectory: () async => Directory('${dir.path}/m'));
      await again.load();
      expect(again.status, HandwritingStatus.installed);

      await service.remove();
      expect(service.status, HandwritingStatus.notInstalled);
    });

    test('a failed download leaves no half file', () async {
      final failing = MathService(
        defaultModel: FormulaModel.pix2text,
        modelDirectory: () async => Directory('${dir.path}/m'),
        download: (url, path, progress) async {
          File(path).writeAsBytesSync([1]);
          throw const SocketException('offline');
        },
      );
      await failing.install();
      expect(failing.status, HandwritingStatus.notInstalled);
      expect(failing.error, contains('offline'));
      expect(Directory('${dir.path}/m').listSync(), isEmpty);
    });

    test('reads a formula as one picture and closes the model', () async {
      await service.install();
      final latex = await service.recognize([stroke(0, 0, 40, 40), stroke(60, 0, 100, 40), stroke(0, 80, 100, 100)]);
      expect(latex, 'E=mc^{2}');
      expect(model.closed, isTrue);
      expect(model.seenIds.length, 9);
    });

    test('the highlighter is not read', () async {
      await service.install();
      expect(await service.recognize([stroke(0, 0, 40, 40, color: const Color(0x59FFEB3B))]), '');
      expect(model.seenIds, isEmpty);
    });

    test('refuses to read without the model', () async {
      expect(() => service.recognize([stroke(0, 0, 40, 40)]), throwsStateError);
    });
  });
}

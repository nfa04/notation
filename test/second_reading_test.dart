import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_prefetcher.dart';
import 'package:notes/ink/math_marks.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/ink/texteller_decoder.dart';

import 'ink_prefetch_test.dart' show FakeReader, until, word;
import 'texteller_test.dart' show FakeTeller, FakePix2Text, zigzag;

ReadLine line(String key, double top, String? latex) => (page: 0, key: key, rect: Rect.fromLTWH(100, top, 200, 30), latex: latex);

void main() {
  group('the same reading', () {
    test('spacing, left and right and braces around one character do not make a difference', () {
      expect(sameReading('x^{2} + 1', r'x^2+1'), isTrue);
      expect(sameReading(r'\left( a + b \right)', '(a+b)'), isTrue);
      expect(sameReading(r'a\,b', 'ab'), isTrue);
      expect(sameReading('x = 4', 'x = 5'), isFalse);
      expect(sameReading(r'\frac{1}{2}', r'\frac{1}{3}'), isFalse);
      expect(sameReading('x^{12}', 'x^{21}'), isFalse);
    });
  });

  group('marks of lines that may have been misread', () {
    final lines = [line('a', 0, r'2x + 3 = 11'), line('b', 40, r'2x = 8'), line('c', 80, r'x = 5')];

    test('a mistake that another reading does not show is doubtful, and keeps its verdict', () {
      final marks = MathMarker().mark(lines, others: {'c': [r'x = 4']});
      final c = marks.firstWhere((m) => m.key == 'c');
      expect(c.check.isProblem, isTrue);
      expect(c.doubtful, isTrue);
      expect(c.others, [r'x = 4']);
    });

    test('a mistake that every reading shows is not doubtful', () {
      final c = MathMarker().mark(lines, others: {'c': [r'x = 6', r'x = 7']}).firstWhere((m) => m.key == 'c');
      expect(c.doubtful, isFalse);
      expect(c.others, hasLength(2));
    });

    test('the same reading is not an other one, and nothing is doubtful without any', () {
      final c = MathMarker().mark(lines, others: {'c': [r'x=5', r'x = 5']}).firstWhere((m) => m.key == 'c');
      expect(c.others, isEmpty);
      expect(c.doubtful, isFalse);
      expect(MathMarker().mark(lines).firstWhere((m) => m.key == 'c').doubtful, isFalse);
    });

    test('a line that is not a mistake is never doubtful', () {
      final b = MathMarker().mark(lines, others: {'b': [r'2x = 9']}).firstWhere((m) => m.key == 'b');
      expect(b.check.isProblem, isFalse);
      expect(b.doubtful, isFalse);
      expect(b.others, [r'2x = 9'], reason: 'it is still offered');
    });

    test('the lines around it stay as they are when an other reading is tried', () {
      // the other reading of c is fine on its own (x = 1), but not after these lines
      final c = MathMarker().mark(lines, others: {'c': [r'x = 1']}).firstWhere((m) => m.key == 'c');
      expect(c.doubtful, isFalse);
    });
  });

  group('the background reader looks again', () {
    test('once, after the line was read; the other readings are there afterwards', () async {
      final math = FakeReader((s) => 'x = 5', sayAgain: (s) => ['x = 4', 'x = 6']);
      final reader = InkPrefetcher(strokes: () => {0: word('a', 100, 100)}, idle: const Duration(milliseconds: 10));
      addTearDown(reader.dispose);
      reader.configure(math: math);
      await until(() => reader.readings().any((r) => r.latex != null));
      final key = reader.readings().single.block.key;
      expect(reader.lookedAgain(key), isFalse);
      var heard = 0;
      reader.addListener(() => heard++);
      await reader.lookAgain(key);
      expect(reader.othersOf(key), ['x = 4', 'x = 6']);
      expect(reader.lookedAgain(key), isTrue);
      expect(heard, greaterThan(0));
      await reader.lookAgain(key);
      expect(math.lookedAgain, 1, reason: 'not asked a second time');
    });

    test('not for what has not been read', () async {
      final math = FakeReader((s) => 'x = 5', sayAgain: (s) => ['x = 4']);
      final reader = InkPrefetcher(strokes: () => {0: word('a', 100, 100)}, idle: const Duration(hours: 1));
      addTearDown(reader.dispose);
      reader.configure(math: math);
      await reader.lookAgain('nothing');
      expect(math.lookedAgain, 0);
    });

    test('a correction by the person is what it says: no other readings after it', () async {
      final math = FakeReader((s) => 'x = 5', sayAgain: (s) => ['x = 4']);
      final reader = InkPrefetcher(strokes: () => {0: word('a', 100, 100)}, idle: const Duration(milliseconds: 10));
      addTearDown(reader.dispose);
      reader.configure(math: math);
      await until(() => reader.readings().any((r) => r.latex != null));
      final key = reader.readings().single.block.key;
      await reader.lookAgain(key);
      reader.correct(key, 'x = 4');
      expect(reader.othersOf(key), isEmpty);
      expect(reader.readings().single.latex, 'x = 4');
    });

    test('a reader that cannot look again leaves it at that', () async {
      final math = FakeReader((s) => 'x = 5');
      final reader = InkPrefetcher(strokes: () => {0: word('a', 100, 100)}, idle: const Duration(milliseconds: 10));
      addTearDown(reader.dispose);
      reader.configure(math: math);
      await until(() => reader.readings().any((r) => r.latex != null));
      final key = reader.readings().single.block.key;
      await reader.lookAgain(key);
      expect(reader.othersOf(key), isEmpty);
      expect(reader.lookedAgain(key), isTrue);
    });
  });

  group('the formula service looks again', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('again_');
      for (final f in ['tt/encoder.onnx', 'tt/decoder.onnx', 'p2t/encoder_model.onnx', 'p2t/decoder_model.onnx']) {
        File('${dir.path}/$f')
          ..createSync(recursive: true)
          ..writeAsBytesSync([1]);
      }
    });
    tearDown(() => dir.delete(recursive: true));

    MathService make(FakeTeller teller, {FormulaModel model = FormulaModel.texteller}) => MathService(
          defaultModel: model,
          modelDirectory: () async => Directory('${dir.path}/p2t'),
          tellerDirectory: () async => Directory('${dir.path}/tt'),
          loadVocab: () async => File('assets/math/vocab.txt').readAsStringSync(),
          loadTellerVocab: () async => File('assets/texteller/vocab.txt').readAsStringSync(),
          open: (_, _) async => FakePix2Text(),
          openTeller: (_, _) async => teller,
        );

    test('it reads the picture once for each of the other pens, and leaves out readings that are the same', () async {
      final teller = FakeTeller([0, 265, 92, 2]);
      final service = make(teller);
      await service.load();
      final strokes = [for (var i = 0; i < 4; i++) zigzag(100.0 + i * 20, 100, 14, 22, id: 's$i')];
      final others = await service.recognizeAgain(strokes);
      expect(teller.seen, hasLength(MathService.otherPens.length));
      expect(others, hasLength(1), reason: 'the model said the same each time');
    });

    test('the pictures are drawn with other pens', () async {
      final pictures = <double>[];
      final teller = _SumTeller(pictures);
      final service = make(teller);
      await service.load();
      await service.recognizeAgain([for (var i = 0; i < 4; i++) zigzag(100.0 + i * 20, 100, 14, 22, id: 's$i')]);
      expect(pictures, hasLength(2));
      expect(pictures[0], lessThan(pictures[1]), reason: 'the thinner pen leaves less ink than the thicker one');
    });

    test('the old reader has no other way to look', () async {
      final service = make(FakeTeller([0, 2]), model: FormulaModel.pix2text);
      await service.load();
      expect(await service.recognizeAgain([zigzag(100, 100, 14, 22, id: 'a')]), isEmpty);
    });
  });
}

class _SumTeller extends FakeTeller {
  _SumTeller(this.sums) : super([0, 265, 92, 2]);
  final List<double> sums;

  @override
  Future<List<int>> read(Float32List pixels, {int maxTokens = texTellerMaxTokens}) async {
      sums.add(pixels.fold(0.0, (a, b) => a + (b < 0.296 ? 0.296 - b : 0)));
    return super.read(pixels, maxTokens: maxTokens);
  }
}

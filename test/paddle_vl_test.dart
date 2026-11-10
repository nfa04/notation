import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/handwriting_service.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/onnx_paddle_vl.dart';
import 'package:notes/ink/paddle_vl.dart';
import 'package:notes/ink/paddle_vl_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:path/path.dart' as p;

void main() {
  group('the picture and the prompt', () {
    test('the patches are cut like the reference implementation cuts them (numbers from numpy)', () {
      const w = 56, h = 28;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = 4 * (y * w + x);
          rgba[i] = (x * 7 + y * 3) % 256;
          rgba[i + 1] = (x * 5 + y * 11) % 256;
          rgba[i + 2] = (x * 13 + y) % 256;
          rgba[i + 3] = 255;
        }
      }
      final patches = paddleVlPatches(rgba, w, h);
      expect(patches.length, 8 * 3 * 14 * 14);
      double at(int patch, int c, int y, int x) => patches[((patch * 3 + c) * 14 + y) * 14 + x];
      expect(at(0, 0, 0, 0), -1.0);
      expect(at(0, 1, 2, 5), closeTo(-0.6313725709915161, 1e-6));
      expect(at(1, 2, 3, 0), closeTo(0.45098042488098145, 1e-6));
      expect(at(3, 2, 13, 13), closeTo(0.6941176652908325, 1e-6));
      expect(at(2, 0, 5, 7), closeTo(-0.9686274528503418, 1e-6));
      expect(at(3, 1, 0, 13), closeTo(-0.8509804010391235, 1e-6));
    });

    test('the prompt has one place in it for every 2 x 2 patches', () {
      final prompt = paddleVlPrompt(8, 72);
      expect(prompt.where((t) => t == paddleVlImageToken).length, 144);
      expect(prompt.length, 5 + 144 + 8);
      expect(prompt.first, 100273); // <|begin_of_sentence|>
      expect(prompt.last, 23); // the colon, then the newline that asks for the answer
    });
  });

  group('the words', () {
    final vocabulary = PaddleVlVocabulary.parse(jsonEncode({
      'model': {
        'vocab': {'▁Hello': 5, '▁world': 6, '!': 7, '<0xC3>': 8, '<0xBC>': 9, 'x': 10},
      },
      'added_tokens': [
        {'id': 2, 'content': '</s>', 'special': true},
        {'id': 100295, 'content': '<|IMAGE_PLACEHOLDER|>', 'special': true},
      ],
    }));

    test('pieces are joined with their spaces, bytes are put together, special tokens are left out', () {
      expect(vocabulary.decode([5, 6, 7]), 'Hello world!');
      expect(vocabulary.decode([8, 9, 10]), 'üx');
      expect(vocabulary.decode([100295, 5, 2]), 'Hello');
      expect(vocabulary.decode([99999, -1]), '');
    });

    test('a loop at the end is cut to its first round', () {
      expect(withoutLoop([1, 2, 3, 4, 4, 4, 4, 4]), [1, 2, 3, 4]);
      expect(withoutLoop([9, 1, 2, 1, 2, 1, 2, 1, 2]), [9, 1, 2]);
      expect(withoutLoop([1, 2, 3, 3, 3]), [1, 2, 3, 3, 3]); // (only three rounds: could be meant)
      expect(withoutLoop([1, 2, 3]), [1, 2, 3]);
    });
  });

  group('the reader', () {
    test('a line of ink becomes a picture of the sizes the model wants', () async {
      final line = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [const Offset(10, 10), const Offset(60, 40), const Offset(110, 10)]),
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [const Offset(120, 10), const Offset(300, 50)]),
      ];
      final picture = await renderInkForPaddleVl(line);
      expect(picture.gridHeight, 8);
      expect(picture.gridWidth * 14, greaterThanOrEqualTo(paddleVlMinWidth));
      expect((picture.gridWidth * 14) % 28, 0);
      expect(picture.patches.length, picture.gridHeight * picture.gridWidth * 3 * 14 * 14);
      expect(picture.patches.any((v) => v < 0), isTrue); // (there is ink)
      expect(picture.patches.any((v) => v == 1), isTrue); // (and paper)
      // a very long line is made smaller, not wider than the model takes
      final long = await renderInkForPaddleVl([
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [const Offset(0, 0), const Offset(200000, 40)]),
      ]);
      expect(long.gridWidth * 14, paddleVlMaxWidth);
    });

    testWidgets('the service reads each line as a picture and writes the words (stand-in networks here), and the reader can be chosen', (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('paddle_vl');
        addTearDown(() => dir.delete(recursive: true));
        final seen = <PaddleVlPicture>[];
        final settings = <String, String>{};
        final paddle = PaddleVlService(
          modelDirectory: () async => dir,
          read: (vision, decoder, embeddings, pictures) async {
            seen.addAll(pictures);
            return [for (var i = 0; i < pictures.length; i++) i.isEven ? [5, 6] : [5, 7]];
          },
          download: (url, path, progress) async {
            File(path).writeAsStringSync(url.endsWith('tokenizer.json')
                ? jsonEncode({'model': {'vocab': {'▁Hello': 5, '▁world': 6, '!': 7}}, 'added_tokens': []})
                : 'x');
            progress(1);
          },
        );
        final hw = HandwritingService(
          paddle: paddle,
          glm: GlmOcrService(modelDirectory: () async => Directory(p.join(dir.path, 'glm'))),
          readSetting: (k) async => settings[k],
          writeSetting: (k, v) async => settings[k] = v,
          removeOldFiles: () async {},
        );
        await hw.load();
        expect(hw.reader, HandwritingReader.glm);
        await hw.setReader(HandwritingReader.paddle);
        expect(settings[HandwritingService.readerKey], 'paddle');
        expect(hw.installed, isFalse);
        expect(hw.sizeMb, 900);
        expect(() => hw.recognize([_stroke(0, 0)]), throwsStateError);

        await hw.install();
        expect(hw.installed, isTrue);
        final text = await hw.recognize([_stroke(0, 0), _stroke(0, 200)]);
        expect(text, 'Hello world\nHello!');
        expect(seen.length, 2);

        final again = HandwritingService(
          paddle: paddle,
          glm: GlmOcrService(modelDirectory: () async => Directory(p.join(dir.path, 'glm'))),
          readSetting: (k) async => settings[k],
          removeOldFiles: () async {},
        );
        await again.load();
        expect(again.reader, HandwritingReader.paddle);
        expect(again.installed, isTrue);
      });
    });
  });
}

DrawingStroke _stroke(double left, double top) =>
    DrawingStroke(color: const Color(0xFF000000), width: 3, points: [Offset(left, top), Offset(left + 20, top + 40), Offset(left + 40, top)]);

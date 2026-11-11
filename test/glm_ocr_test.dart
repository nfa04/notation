import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/handwriting_service.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:path/path.dart' as p;

/// The numbers in test/fixtures/glm_golden.json come from the Python of the model (the HF processor, `get_rope_index`):
/// `python3 tool/handwriting_bench/glm_onnx/patches_check.py test/fixtures`.
void main() {
  final golden = jsonDecode(File('test/fixtures/glm_golden.json').readAsStringSync()) as Map<String, dynamic>;

  group('the picture and the prompt, as the reference implementation does them', () {
    test('the patches have the same numbers, in the same order', () {
      final w = golden['width'] as int, h = golden['height'] as int;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          for (var c = 0; c < 3; c++) {
            rgba[4 * (y * w + x) + c] = (x * 7 + y * 13 + c * 31) % 256;
          }
          rgba[4 * (y * w + x) + 3] = 255;
        }
      }
      final patches = glmPatches(rgba, w, h);
      expect(patches.length, golden['count']);
      expect(patches.length, (golden['patches'] as int) * 1176);
      var sum = 0.0;
      for (final v in patches) {
        sum += v;
      }
      expect(sum, closeTo(golden['sum'] as double, 0.5));
      for (final s in golden['samples'] as List) {
        expect(patches[s[0] as int], closeTo((s[1] as num).toDouble(), 1e-5), reason: 'at ${s[0]}');
      }
    });

    test('the patches have the positions the reference gives them', () {
      final small = [for (final pair in golden['vision_pos_small'] as List) ...(pair as List).cast<int>()];
      expect(glmPatchPositions(8, 10), small);
      expect(glmPatchPositions(10, 24).fold<int>(0, (a, b) => a + b), golden['vision_pos_big_sum']);
    });

    test('the prompt and the position of every token of it are the reference\'s', () {
      expect(glmPrompt(8, 10), (golden['prompt_small'] as List).cast<int>());
      List<int> flat(String key) => [for (final row in golden[key] as List) ...(row as List).cast<int>()];
      expect(glmPromptPositions(8, 10), flat('text_pos_small'));
      expect(glmPromptPositions(10, 24), flat('text_pos_big'));
      final positions = glmPromptPositions(10, 24);
      expect(positions.length, 3 * glmPrompt(10, 24).length);
    });
  });

  group('the words', () {
    final vocabulary = GlmVocabulary.parse(File('assets/glm_ocr/vocab.txt').readAsStringSync());

    test('the vocabulary of the app is the model\'s: ids written by the model give the text it wrote', () {
      expect(vocabulary.pieces.length, glmOrdinaryTokens);
      expect(vocabulary.decode([5731, 16211, 596, 59253]), 'Subtraction'); // (the last is the end, left out)
      expect(vocabulary.decode([10606, 8310]), 'product register');
      expect(vocabulary.decode([70, 97, 393, 27318, 1265, 2840, 10743, 4868, 32, 49, 59253]), 'Faul-adder mit carry-in 1');
    });

    test('a letter that is spelt in several bytes is put together, a space is a space, special tokens are left out', () {
      const small = GlmVocabulary(['Hello', 'Ġworld', 'Ã¼', 'Ċ', '!']);
      expect(small.decode([0, 1, 4]), 'Hello world!');
      expect(small.decode([0, 3, 1]), 'Hello\n world'.trim());
      expect(small.decode([2, 59246, 59280]), 'ü');
    });
  });

  group('the table of word vectors', () {
    test('a row is the whole numbers of its place times the scale of its row', () async {
      final dir = await Directory.systemTemp.createTemp('glm_table');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'embeddings.bin');
      final file = await File(path).open(mode: FileMode.write);
      await file.setPosition(5 * glmHidden);
      await file.writeFrom([for (var i = 0; i < glmHidden; i++) i % 3 == 0 ? 254 : (i % 3 == 1 ? 10 : 0)]); // -2, 10, 0
      await file.setPosition(glmTableRows * glmHidden + 5 * 4);
      await file.writeFrom((ByteData(4)..setFloat32(0, 0.5, Endian.little)).buffer.asUint8List());
      await file.setPosition(glmTableRows * glmHidden + glmTableRows * 4 - 1);
      await file.writeByte(0);
      await file.close();
      final table = await GlmEmbeddings.open(path);
      final row = await table.row(5);
      expect(row.length, glmHidden);
      expect(row.sublist(0, 3), [-1.0, 5.0, 0.0]);
      expect(await table.row(5), same(row)); // (kept)
      await table.close();
    });
  });

  group('what is not writing', () {
    test('of a drawing the reader writes an empty block of markdown or dashes, or anything with little confidence: none of it is kept', () {
      expect(GlmOcrService.isWriting('```markdown\n\n```', 0.97), isFalse);
      expect(GlmOcrService.isWriting('---', 0.92), isFalse);
      expect(GlmOcrService.isWriting('Tricycle', 0.3), isFalse);
      expect(GlmOcrService.isWriting('', 1), isFalse);
    });

    test('writing is kept, a lone number too (an answer on its own line), and a sure reading of a sign', () {
      expect(GlmOcrService.isWriting('nach through rate', 0.98), isTrue);
      expect(GlmOcrService.isWriting(r'$ x=\frac{1}{2} $', 0.9), isTrue);
      expect(GlmOcrService.isWriting('4', 0.9), isTrue);
      expect(GlmOcrService.isWriting('★', 0.68), isTrue);
    });
  });

  group('the reader', () {
    test('a line of ink becomes a picture of the sizes the model wants', () async {
      final line = [
        _stroke(10, 10, 110, 60),
        _stroke(120, 10, 300, 50),
      ];
      for (final rows in [6, 8, 10]) {
        final picture = await renderInkForGlmOcr(line, rows: rows);
        expect(picture.gridHeight, rows);
        expect(picture.gridWidth.isEven, isTrue);
        expect(picture.gridWidth * glmPatch * picture.gridHeight * glmPatch, greaterThanOrEqualTo(glmMinPixels));
        expect(picture.patches.length, picture.count * 1176);
        expect(picture.patches.any((v) => v < -1.5), isTrue); // (there is ink)
        expect(picture.patches.any((v) => v > 1.8), isTrue); // (and paper)
      }
      // a very long line is made smaller, not wider than the position table of the network
      final long = await renderInkForGlmOcr([_stroke(0, 0, 200000, 40)]);
      expect(long.gridWidth, lessThanOrEqualTo(glmMaxPatchesPerSide));
      // a short word is still as big a picture as the model's smallest
      final dot = await renderInkForGlmOcr([_stroke(0, 0, 4, 4)]);
      expect(dot.gridWidth * dot.gridHeight * 196, greaterThanOrEqualTo(glmMinPixels));
    });

    test('chunks of a line are put together up to a width, and not beyond', () {
      InkChunk chunk(double left, double right) =>
          InkChunk([_stroke(left, 0, right, 20)], Rect.fromLTRB(left, 0, right, 20));
      final pieces = GlmOcrService.joinChunks([chunk(0, 200), chunk(210, 400), chunk(410, 600), chunk(610, 640)]);
      expect(pieces.length, 2); // (24 x the height of 20 is 480)
      expect(pieces[0].length, 2);
      expect(pieces[1].length, 2);
      expect(GlmOcrService.joinChunks([]), isEmpty);
    });

    testWidgets('the service reads each line as a picture and writes the words (stand-in networks here), and the reader and the quality can be chosen', (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('glm_ocr');
        addTearDown(() => dir.delete(recursive: true));
        final seen = <GlmPicture>[];
        final settings = <String, String>{};
        final glm = GlmOcrService(
          modelDirectory: () async => dir,
          loadVocab: () async => 'He\nllo\nĠworld\n!\n',
          checksums: const {},
          read: (vision, text, embeddings, pictures) async {
            seen.addAll(pictures);
            return [for (var i = 0; i < pictures.length; i++) i.isEven ? [0, 1, 2, 59253] : [0, 3]];
          },
          download: (url, path, progress) async {
            File(path).writeAsStringSync('x');
            progress(1);
          },
        );
        final hw = HandwritingService(
          glm: glm,
          readSetting: (k) async => settings[k],
          writeSetting: (k, v) async => settings[k] = v,
          removeOldFiles: () async {},
        );
        await hw.load();
        expect(hw.reader, HandwritingReader.glm); // (the standard)
        expect(hw.quality, GlmQuality.standard);
        expect(hw.installed, isFalse);
        expect(hw.sizeMb, 815);
        expect(() => hw.recognize([_stroke(0, 0, 40, 40)]), throwsStateError);

        await hw.install();
        expect(hw.installed, isTrue);
        final text = await hw.recognize([_stroke(0, 0, 40, 40), _stroke(0, 200, 40, 240)]);
        expect(text, 'Hello world\nHe!');
        expect(seen.length, 2);
        expect(seen.first.gridHeight, 10);

        await hw.setQuality(GlmQuality.quick);
        expect(settings[HandwritingService.qualityKey], 'quick');
        seen.clear();
        await hw.recognize([_stroke(0, 0, 40, 40)]);
        expect(seen.single.gridHeight, 8);

        await hw.setQuality(GlmQuality.light);
        expect(settings[HandwritingService.qualityKey], 'light');
        seen.clear();
        await hw.recognize([_stroke(0, 0, 40, 40)]);
        expect(seen.single.gridHeight, 6);

        final again = HandwritingService(
          glm: glm,
          readSetting: (k) async => settings[k],
          removeOldFiles: () async {},
        );
        await again.load();
        expect(again.reader, HandwritingReader.glm);
        expect(again.quality, GlmQuality.light);
        expect(again.installed, isTrue);
      });
    });

    testWidgets('a download that is not the published file is thrown away', (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('glm_ocr_sum');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
        final glm = GlmOcrService(
          modelDirectory: () async => dir,
          checksums: const {'vision.onnx': 'not-the-sum'},
          download: (url, path, progress) async {
            File(path).writeAsStringSync('x');
            progress(1);
          },
        );
        await glm.load();
        await glm.install();
        expect(glm.installed, isFalse);
        expect(glm.error, contains('checksum'));
        expect(await dir.exists(), isFalse);
      });
    });
  });
}

DrawingStroke _stroke(double left, double top, double right, double bottom) =>
    DrawingStroke(color: const Color(0xFF000000), width: 3, points: [Offset(left, top), Offset((left + right) / 2, bottom), Offset(right, top)]);

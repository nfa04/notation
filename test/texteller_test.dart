import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride, kIsWeb;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/ink_prefetcher.dart';
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/ink/math_decoder.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/ink/texteller_decoder.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke pen(List<Offset> points, {String? id}) => DrawingStroke(id: id, color: const Color(0xFF000000), width: 3, points: points);

/// A line of "writing" [w] wide and [h] tall, left edge at [x]: a zigzag.
DrawingStroke zigzag(double x, double y, double w, double h, {String? id}) =>
    pen([for (var i = 0; i < 10; i++) Offset(x + w * i / 9, y + (i.isEven ? 0 : h))], id: id);

class FakeTeller implements TexTellerModel {
  FakeTeller(this.says);
  List<int> says;
  final seen = <int>[]; // the length of every picture
  int running = 0, mostAtOnce = 0;
  bool closed = false;
  Duration delay = Duration.zero;

  @override
  Future<List<int>> read(Float32List pixels, {int maxTokens = texTellerMaxTokens}) async {
    seen.add(pixels.length);
    running++;
    if (running > mostAtOnce) mostAtOnce = running;
    await Future<void>.delayed(delay);
    running--;
    return says;
  }

  @override
  Future<void> close() async => closed = true;
}

/// The old reader: says E=mc^{2}.
class FakePix2Text implements MathOcrModel {
  @override
  Future<Object> encode(Float32List pixels) async => 'encoded';
  int _i = 0;
  static const _says = [41, 270, 305, 318, 265, 262, 269, 261, mathEosToken];
  @override
  Future<int> nextToken(Object encoded, List<int> ids) async => _says[_i++ % _says.length];
  @override
  Future<void> release(Object encoded) async {}
  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vocab = MathVocab.parse(File('assets/texteller/vocab.txt').readAsStringSync());

  group('reading what TexTeller wrote', () {
    // the ids the real TexTeller files gave for handwritten formulas (onnxruntime, 8-bit)
    test('a fraction: the space that ends a command stays', () {
      expect(
        texTellerLatex(vocab, [0, 280, 288, 279, 381, 563, 423, 381, 64, 403, 378, 288, 95, 21, 300, 22, 263, 389, 262, 22, 263, 288, 279, 381, 262, 22, 97, 89, 423, 381, 502, 262, 22, 472, 2]),
        r'\frac{\partial u}{\partial\tau}=\frac{1}{2}\sigma^{2}\frac{\partial^{2}u}{\partial x^{2}}',
      );
    });

    test('the fence around the formula goes, and so do the tokens that only mark the start and the end', () {
      expect(texTellerLatex(vocab, [0, 265, 92, 64, 272, 1170, 22, 848, 20, 18, 25, 647, 2]), r'x\in[-2,-0.5]');
    });

    test('a stray space inside braces is kept as one space', () {
      expect(texTellerLatex(vocab, [0, 280, 301, 12, 73, 261, 283, 366, 312, 73, 261, 283, 459, 528, 283, 301, 261, 1513, 291, 2]),
          r'\eta(e_{ \mu},e_{ \nu})= \eta_{uv}');
    });

    test('the vocabulary is the whole 15000', () {
      expect(vocab.tokens.length, 15000);
      expect(vocab.tokens[0], '<s>');
      expect(vocab.tokens[2], '</s>');
    });

    test('the fence', () {
      expect(withoutDisplayFence(r'\[ x^{2} \]'), 'x^{2}');
      expect(withoutDisplayFence(r'$$ a=b $$'), 'a=b');
      expect(withoutDisplayFence(r'$$'), r'$$');
      expect(withoutDisplayFence('a+b'), 'a+b');
      expect(withoutDisplayFence(''), '');
    });

    test('the next token is the largest score of the last position', () {
      // two positions of a vocabulary of four: only the last counts
      expect(lastArgMax([9.0, 0, 0, 0, 0.1, 0.7, 0.2, 0.0], 4), 1);
      expect(lastArgMax([1, 5, 2], 3), 1);
    });

    test('the cache has the names the decoder file uses', () {
      final names = texTellerCacheNames().toList();
      expect(names.length, 48);
      expect(names.first.past, 'past_key_values.0.decoder.key');
      expect(names.first.present, 'present.0.decoder.key');
      expect(names.where((n) => n.decoder).length, 24);
      expect(names.last.past, 'past_key_values.11.encoder.value');
    });
  });

  group('the picture TexTeller gets', () {
    const white = (1 - 0.9545467) / 0.15394445;

    test('wide writing keeps its proportions, fills the width and is thin; the rest is padding', () async {
      final strokes = [zigzag(0, 0, 400, 40), zigzag(0, 0, 400, 40)];
      final px = await renderInkForTexTeller(strokes);
      expect(px.length, texTellerImageSize * texTellerImageSize);
      // 400 x 40 -> 444 x 44 + 2 px around: the rows below the picture are the padding (0, not white)
      expect(px[200 * texTellerImageSize + 10], 0.0);
      expect(px[(texTellerImageSize - 1) * texTellerImageSize + 447], 0.0);
      // inside the picture the paper is white (most of it: the ink is thin)
      var paper = 0, inside = 0;
      for (var y = 0; y < 44; y++) {
        for (var x = 0; x < 440; x++) {
          inside++;
          if ((px[y * texTellerImageSize + x] - white).abs() < 0.05) paper++;
        }
      }
      expect(paper / inside, greaterThan(0.85));
      // there is ink in the right part: it spans the width
      var inkRight = 0;
      for (var y = 0; y < 60; y++) {
        for (var x = 420; x < 448; x++) {
          if (px[y * texTellerImageSize + x] < -1) inkRight++;
        }
      }
      expect(inkRight, greaterThan(3));
    });

    test('tall writing is fitted by its height; the columns on the right are padding', () async {
      final px = await renderInkForTexTeller([zigzag(0, 0, 20, 300)]);
      expect(px[10 * texTellerImageSize + 300], 0.0);
      expect(px[440 * texTellerImageSize + 5], isNot(0.0)); // (the picture goes down to the bottom)
    });

    test('the pen is thin: far less ink than the pen drawn on the page would give', () async {
      final strokes = [zigzag(0, 0, 300, 120)];
      final thin = await renderInkForTexTeller(strokes);
      final thick = await renderInkForTexTeller(strokes, penScale: 8);
      int ink(Float32List p) => p.where((v) => v < -1).length;
      expect(ink(thin), greaterThan(0));
      expect(ink(thick), greaterThan(ink(thin) * 3));
      // anti-aliased, not a dither of black and white
      expect(thin.where((v) => v < white - 0.5 && v > -5).length, greaterThan(0));
    });

    test('a single tiny dot-like stroke does not break it', () async {
      final px = await renderInkForTexTeller([pen([const Offset(5, 5), const Offset(5.2, 5.1)])]);
      expect(px.length, texTellerImageSize * texTellerImageSize);
    });
  });

  group('the service with TexTeller', () {
    late Directory dir;
    late FakeTeller teller;
    late Map<String, String> settings;
    late List<String> downloads;

    MathService make({FormulaModel? defaultModel, Map<String, String>? store, Map<String, String> checksums = const {}}) => MathService(
          defaultModel: defaultModel ?? FormulaModel.texteller,
          checksums: checksums,
          modelDirectory: () async => Directory('${dir.path}/p2t'),
          tellerDirectory: () async => Directory('${dir.path}/tt'),
          loadVocab: () async => File('assets/math/vocab.txt').readAsStringSync(),
          loadTellerVocab: () async => File('assets/texteller/vocab.txt').readAsStringSync(),
          open: (_, _) async => FakePix2Text(),
          openTeller: (_, _) async => teller,
          readSetting: (k) async => (store ?? settings)[k],
          writeSetting: (k, v) async => (store ?? settings)[k] = v,
          download: (url, path, progress) async {
            downloads.add(url);
            File(path).writeAsBytesSync([1]);
          },
        );

    void put(String folder, List<String> names) {
      Directory('${dir.path}/$folder').createSync(recursive: true);
      for (final n in names) {
        File('${dir.path}/$folder/$n').writeAsBytesSync([1, 2, 3]);
      }
    }

    void putTeller() => put('tt', ['encoder.onnx', 'decoder.onnx']);
    void putPix2Text() => put('p2t', ['encoder_model.onnx', 'decoder_model.onnx']);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('teller_');
      teller = FakeTeller([0, 265, 92, 64, 272, 1170, 22, 848, 20, 18, 25, 647, 2]);
      settings = {};
      downloads = [];
    });
    tearDown(() => dir.delete(recursive: true));

    final ink = [zigzag(0, 0, 100, 30)];

    test('TexTeller is the default on every kind of device', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final service = MathService(tellerDirectory: () async => Directory('${dir.path}/tt'));
          expect(service.model, FormulaModel.texteller, reason: '$platform');
          expect(service.sizeMb, 88 + 229, reason: '$platform');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test('reads with TexTeller when nobody chose and it is there', () async {
      putTeller();
      final service = make();
      await service.load();
      expect(service.model, FormulaModel.texteller);
      expect(service.chosen, isFalse);
      expect(service.status, HandwritingStatus.installed);
      expect(await service.recognize(ink), r'x\in[-2,-0.5]');
      expect(teller.seen, [texTellerImageSize * texTellerImageSize]);
    });

    test('a person who only has the old model keeps reading with it', () async {
      putPix2Text();
      final service = make();
      await service.load();
      expect(service.model, FormulaModel.pix2text);
      expect(service.chosen, isFalse);
      expect(service.status, HandwritingStatus.installed);
      expect(await service.recognize(ink), 'E=mc^{2}');
      expect(teller.seen, isEmpty);
    });

    test('with both there, the default wins; with the default missing and none there, nothing is installed', () async {
      putPix2Text();
      putTeller();
      expect((await (() async => make()..load())()).model, FormulaModel.texteller);
      final none = MathService(
        defaultModel: FormulaModel.texteller,
        modelDirectory: () async => Directory('${dir.path}/nothing-a'),
        tellerDirectory: () async => Directory('${dir.path}/nothing-b'),
      );
      await none.load();
      expect(none.status, HandwritingStatus.notInstalled);
      expect(none.model, FormulaModel.texteller);
      expect(none.sizeMb, 88 + 229);
    });

    test('the choice is remembered, switches the files, and lets go of the reader', () async {
      putTeller();
      putPix2Text();
      final service = make();
      await service.load();
      expect(await service.recognize(ink), isNotEmpty);

      await service.choose(FormulaModel.pix2text);
      expect(settings[MathService.settingKey], 'pix2text');
      expect(service.model, FormulaModel.pix2text);
      expect(service.chosen, isTrue);
      expect(service.sizeMb, 88 + 32);
      expect(teller.closed, isTrue);
      expect(await service.recognize(ink), 'E=mc^{2}');

      // another start of the app: the choice is still there, even though the default is the other model
      final again = make();
      await again.load();
      expect(again.model, FormulaModel.pix2text);
      expect(again.chosen, isTrue);

      await again.choose(FormulaModel.texteller);
      expect(settings[MathService.settingKey], 'texteller');
      expect(again.status, HandwritingStatus.installed);
    });

    test('a chosen model that is not on the device is not installed, whatever else is there', () async {
      putPix2Text();
      final service = make(store: {MathService.settingKey: 'texteller'});
      await service.load();
      expect(service.model, FormulaModel.texteller);
      expect(service.status, HandwritingStatus.notInstalled);
      expect(() => service.recognize(ink), throwsStateError);
      expect(await service.hasFilesOf(FormulaModel.pix2text), isTrue);
      expect(await service.hasFilesOf(FormulaModel.texteller), isFalse);
    });

    test('formulas asked for at once are read one after the other', () async {
      putTeller();
      teller.delay = const Duration(milliseconds: 20);
      final service = make();
      await service.load();
      final all = await Future.wait([for (var i = 0; i < 4; i++) service.recognize(ink)]);
      expect(all.toSet().length, 1);
      expect(teller.mostAtOnce, 1);
      expect(teller.seen.length, 4);
    });

    test('a reading that fails does not block the ones after it', () async {
      putTeller();
      final service = make();
      await service.load();
      teller.says = [0, 2]; // nothing at all
      expect(await service.recognize(ink), '');
      teller.says = [0, 265, 92, 2];
      expect(await service.recognize(ink), 'x');
    });

    test('the highlighter and a dot are not read', () async {
      putTeller();
      final service = make();
      await service.load();
      expect(await service.recognize([DrawingStroke(color: const Color(0x66FFEB3B), width: 12, points: [const Offset(0, 0), const Offset(50, 0)])]), '');
      expect(teller.seen, isEmpty);
    });

    test('the TexTeller files come from the published release (Hugging Face on the web, GitHub elsewhere)', () {
      expect(MathService.tellerFiles['encoder.onnx']!.url, startsWith('https://'));
      if (MathService.tellerRepo != MathService.defaultTellerRepo) return; // (a build with an address of its own)
      expect(MathService.defaultTellerRepo, kIsWeb ? MathService.hubTellerRepo : MathService.githubTellerRepo);
      expect(MathService.hubTellerRepo, 'https://huggingface.co/nfa04/texteller-onnx-8bit/resolve/main');
      expect(MathService.tellerFiles['encoder.onnx']!.url, '${MathService.defaultTellerRepo}/encoder.onnx');
      expect(MathService.tellerFiles['decoder.onnx']!.url, '${MathService.defaultTellerRepo}/decoder.onnx');
      expect(MathService.tellerChecksums.keys.toSet(), MathService.tellerFiles.keys.toSet());
      expect(MathService.tellerChecksums.values.every((h) => RegExp(r'^[0-9a-f]{64}$').hasMatch(h)), isTrue);
    });

    test('TexTeller downloads both files into its own folder, and a checksum that matches keeps them', () async {
      final good = sha256.convert([1]).toString(); // (the fake download writes one byte)
      final service = make(checksums: {'encoder.onnx': good, 'decoder.onnx': good});
      await service.load();
      expect(service.status, HandwritingStatus.notInstalled);
      await service.install();
      expect(service.error, isNull);
      expect(service.status, HandwritingStatus.installed);
      expect(downloads.length, 2);
      expect(downloads.every((u) => u.endsWith('/encoder.onnx') || u.endsWith('/decoder.onnx')), isTrue);
      expect(Directory('${dir.path}/tt').listSync().map((f) => f.path.split('/').last).toList()..sort(), ['decoder.onnx', 'encoder.onnx']);
      expect(Directory('${dir.path}/p2t').existsSync(), isFalse);
    });

    test('a download that is not the published file is thrown away', () async {
      final service = make(checksums: {'encoder.onnx': sha256.convert([1]).toString(), 'decoder.onnx': 'f' * 64});
      await service.load();
      await service.install();
      expect(service.status, HandwritingStatus.notInstalled);
      expect(service.error, allOf(contains('decoder.onnx'), contains('checksum')));
      expect(Directory('${dir.path}/tt').existsSync(), isFalse, reason: 'nothing of it is kept');
    });

    test('the other model downloads from its own place into its own folder', () async {
      final service = make(store: {MathService.settingKey: 'pix2text'});
      await service.load();
      await service.install();
      expect(service.error, isNull);
      expect(downloads.length, 2);
      expect(downloads.every((u) => u.contains('pix2text-mfr-1.5')), isTrue);
      expect(Directory('${dir.path}/p2t').listSync().length, 2);
      expect(Directory('${dir.path}/tt').existsSync(), isFalse);
    });
  });

  group('readings of the one before are dropped when the model is switched', () {
    test('the background reader reads the formula again with the new model', () async {
      final dir = await Directory.systemTemp.createTemp('teller_pf_');
      addTearDown(() => dir.delete(recursive: true));
      for (final f in ['tt/encoder.onnx', 'tt/decoder.onnx', 'p2t/encoder_model.onnx', 'p2t/decoder_model.onnx']) {
        File('${dir.path}/$f')
          ..createSync(recursive: true)
          ..writeAsBytesSync([1]);
      }
      final teller = FakeTeller([0, 265, 92, 2]); // x
      final service = MathService(
        defaultModel: FormulaModel.texteller,
        modelDirectory: () async => Directory('${dir.path}/p2t'),
        tellerDirectory: () async => Directory('${dir.path}/tt'),
        loadVocab: () async => File('assets/math/vocab.txt').readAsStringSync(),
        loadTellerVocab: () async => File('assets/texteller/vocab.txt').readAsStringSync(),
        open: (_, _) async => FakePix2Text(),
        openTeller: (_, _) async => teller,
      );
      await service.load();

      final strokes = [for (var i = 0; i < 4; i++) zigzag(100.0 + i * 20, 100, 14, 22, id: 's$i')];
      final reader = InkPrefetcher(strokes: () => {0: strokes}, idle: const Duration(milliseconds: 20));
      addTearDown(reader.dispose);
      reader.configure(math: service);
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 300 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      await until(() => reader.readings().any((r) => r.latex != null));
      expect(reader.readings().single.latex, 'x');

      await service.choose(FormulaModel.pix2text);
      await until(() => reader.readings().any((r) => r.latex == 'E=mc^{2}'));
      expect(reader.readings().single.latex, 'E=mc^{2}');
    });
  });

  test('the thin pen does not touch what the page shows (the picture for the other reader is not changed)', () async {
    // the formula reader of Pix2Text is still fed the picture it always was: 384 x 384 RGB, a pen of 4.5
    final px = await renderInkForModel([zigzag(0, 0, 100, 50)]);
    expect(px.length, 384 * 384 * 3);
    expect(px.where((v) => v < 0.1).length, greaterThan(500));
    expect(Colors.black.toARGB32(), 0xFF000000);
  });
}

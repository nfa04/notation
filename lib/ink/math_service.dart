import 'dart:async';
import '../web/web_files.dart';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../llm/model_files.dart';
import '../models/canvas_models.dart';
import 'ink_image.dart';
import 'ink_recognizer.dart';
import 'math_decoder.dart';
import 'onnx_math_model.dart';
import 'onnx_texteller_model.dart';
import 'texteller_decoder.dart';

/// Which model reads the handwritten formulas.
enum FormulaModel {
  /// TexTeller 3.0 (Apache-2.0), trained on handwriting: reads far more formulas right (about 3 in 4 of the formulas of a
  /// test set against 1 in 8), and its two files are about 320 MB. It is the default.
  texteller,

  /// Pix2Text-MFR (MIT licence), made for printed formulas: lighter (about 120 MB) and quick, for a device that is short of
  /// memory or speed, but it reads handwriting poorly.
  pix2text,
}

/// Reads handwritten formulas as LaTeX, by the model the person chose (see [FormulaModel]), run by ONNX Runtime. The model
/// files are not part of the app: they are downloaded on request.
class MathService extends ModelFilesService implements InkRecognizer {
  static const _repo = 'https://huggingface.co/breezedeus/pix2text-mfr-1.5/resolve/main';
  static const modelFiles = {
    'encoder_model.onnx': (url: '$_repo/encoder_model.onnx', megabytes: 88),
    'decoder_model.onnx': (url: '$_repo/decoder_model.onnx', megabytes: 32),
  };

  /// Where the two TexTeller files are downloaded from (the folder that holds `encoder.onnx` and `decoder.onnx`): the 8-bit versions
  /// that `tool/texteller_models.py` makes from the published ones (TexTeller 3.0, Apache-2.0), kept in
  /// https://github.com/nfa04/texteller-onnx-8bit (a release: fast downloads) and https://huggingface.co/nfa04/texteller-onnx-8bit
  /// (the same two files). The web build takes the second, because a browser may only read a file from another site when that site
  /// allows it, and GitHub's release downloads do not (Hugging Face's do); every other build takes the first. Another place can be
  /// set with `--dart-define=TEXTELLER_REPO=https://...`; its files are not checked against [tellerChecksums] (they may be built
  /// differently), only the files of the two places above are.
  static const githubTellerRepo = 'https://github.com/nfa04/texteller-onnx-8bit/releases/download/onnx-files';
  static const hubTellerRepo = 'https://huggingface.co/nfa04/texteller-onnx-8bit/resolve/main';
  static const defaultTellerRepo = kIsWeb ? hubTellerRepo : githubTellerRepo;
  static const tellerRepo = String.fromEnvironment('TEXTELLER_REPO', defaultValue: defaultTellerRepo);
  static const tellerFiles = {
    'encoder.onnx': (url: '$tellerRepo/encoder.onnx', megabytes: 88),
    'decoder.onnx': (url: '$tellerRepo/decoder.onnx', megabytes: 229),
  };

  /// SHA-256 of the two files (the same on GitHub and on Hugging Face): a download that does not match (cut short, or not the file that was published) is
  /// thrown away instead of being run.
  static const tellerChecksums = {
    'encoder.onnx': '8ea8a061533b7fd8fbb746b0bd9ddd8d26d324fe07647dcf9059ddd07c2d77c4',
    'decoder.onnx': 'ba01e6781c1acf48781e838433c185e71feccae11f40d84ee2a46ecca7ec5ad9',
  };

  /// The setting that remembers the choice.
  static const settingKey = 'math_model';

  /// Where the person's choice of [SecondLook] is kept.
  static const secondLookKey = 'math_second_look';

  /// What is used when nobody chose: TexTeller on every device (it reads handwriting far better and, on a 2020 mid-range tablet with
  /// 4 GB of memory, takes a few seconds a formula). A device that is too slow or short of memory can switch to the lighter reader
  /// in the settings; a person who only has that reader's files on the device keeps it until they download TexTeller.
  static const standardModel = FormulaModel.texteller;

  final Future<MathOcrModel> Function(String encoderPath, String decoderPath) _open;
  final Future<TexTellerModel> Function(String encoderPath, String decoderPath) _openTeller;
  final Future<String> Function() _loadVocab;
  final Future<String> Function() _loadTellerVocab;
  final Future<Directory> Function() _tellerDirectory;
  final Future<String?> Function(String key)? _readSetting;
  final Future<void> Function(String key, String value)? _writeSetting;
  final FormulaModel _fallbackModel;
  final Map<String, String> _checksums;

  MathService({
    Future<MathOcrModel> Function(String, String)? open,
    Future<TexTellerModel> Function(String, String)? openTeller,
    Future<String> Function()? loadVocab,
    Future<String> Function()? loadTellerVocab,
    Future<Directory> Function()? tellerDirectory,
    Future<String?> Function(String key)? readSetting,
    Future<void> Function(String key, String value)? writeSetting,
    FormulaModel? defaultModel,
    Map<String, String>? checksums,
    super.modelDirectory,
    super.download,
  })  : _open = open ?? OnnxMathModel.open,
        _openTeller = openTeller ?? ((e, d) => OnnxTexTeller.open(e, d, keepOpen: _keepOpen)),
        _loadVocab = loadVocab ?? (() => rootBundle.loadString('assets/math/vocab.txt')),
        _loadTellerVocab = loadTellerVocab ?? (() => rootBundle.loadString('assets/texteller/vocab.txt')),
        _tellerDirectory = tellerDirectory ?? (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'models', 'texteller'))),
        _readSetting = readSetting,
        _writeSetting = writeSetting,
        _fallbackModel = defaultModel ?? standardModel,
        _checksums = checksums ?? (tellerRepo == defaultTellerRepo ? tellerChecksums : const {}),
        super(files: (defaultModel ?? standardModel) == FormulaModel.texteller ? tellerFiles : modelFiles, folderName: 'math');

  /// How long the sessions of TexTeller stay open after a formula was read (the next one is often asked for at once): longer
  /// on a computer than on a tablet, which has less memory to spare.
  static Duration get _keepOpen => switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS => const Duration(seconds: 6),
        _ => const Duration(seconds: 30),
      };

  FormulaModel _model = FormulaModel.pix2text;
  bool _modelKnown = false;
  FormulaModel? _chosen; // what the person chose (null: nobody did)
  MathVocab? _vocab;
  MathVocab? _tellerVocab;
  TexTellerModel? _teller;
  SecondLook? _secondLook;
  Future<void> _turn = Future.value();

  /// The model that reads now.
  FormulaModel get model => _modelKnown ? _model : (_chosen ?? _fallbackModel);

  /// How readily a doubtful line is read again with other pens (the default until the setting has been read).
  SecondLook get secondLook => _secondLook ?? texTellerSecondLook;

  Future<SecondLook> _readSecondLook() async {
    if (_secondLook != null) return _secondLook!;
    SecondLook? stored;
    try {
      final name = await _readSetting?.call(secondLookKey);
      stored = SecondLook.values.where((l) => l.id == name).firstOrNull;
    } catch (_) {}
    return _secondLook ??= stored ?? texTellerSecondLook;
  }

  /// Sets how readily a doubtful line is read again (and remembers it).
  Future<void> chooseSecondLook(SecondLook l) async {
    _secondLook = l;
    try {
      await _writeSetting?.call(secondLookKey, l.id);
    } catch (_) {}
    notifyListeners();
  }

  /// Whether the person chose the model (else it is the default for this device).
  bool get chosen => _chosen != null;

  Map<String, ({String url, int megabytes})> _filesOf(FormulaModel m) => m == FormulaModel.texteller ? tellerFiles : modelFiles;

  Future<Directory> _directoryOf(FormulaModel m) => m == FormulaModel.texteller ? _tellerDirectory() : super.directory();

  @override
  Future<Directory> directory() => _directoryOf(model);

  Future<bool> _hasFilesOf(FormulaModel m) async {
    try {
      final dir = await _directoryOf(m);
      for (final name in _filesOf(m).keys) {
        if (!await File(p.join(dir.path, name)).exists()) return false;
      }
      return true;
    } catch (_) {
      return false; // (no folder to look in, so nothing there)
    }
  }

  void _use(FormulaModel m) {
    _model = m;
    _modelKnown = true;
    files = _filesOf(m);
  }

  /// Works out which model to use: the one the person chose, else the default for this device, unless only the other one is
  /// on the device (a person who had the formula reader before TexTeller came keeps it until they download the new one).
  Future<void> _settle() async {
    if (_modelKnown) return;
    FormulaModel? stored;
    try {
      final name = await _readSetting?.call(settingKey);
      stored = FormulaModel.values.where((m) => m.name == name).firstOrNull;
    } catch (_) {}
    _chosen = stored;
    var m = stored ?? _fallbackModel;
    if (stored == null) {
      final other = m == FormulaModel.texteller ? FormulaModel.pix2text : FormulaModel.texteller;
      if (!await _hasFilesOf(m) && await _hasFilesOf(other)) m = other;
    }
    _use(m);
  }

  @override
  Future<void> load() async {
    await _settle();
    await super.load();
  }

  /// Switches to [m] (and remembers the choice). Whatever was loaded is let go of; the other model's files stay where they are.
  Future<void> choose(FormulaModel m) async {
    if (status == HandwritingStatus.downloading) return;
    await _settle();
    _chosen = m;
    try {
      await _writeSetting?.call(settingKey, m.name);
    } catch (_) {}
    if (m != _model) {
      await unload();
      _use(m);
    }
    await super.load();
  }

  /// Whether the files of [m] are on the device (the settings show it for both).
  Future<bool> hasFilesOf(FormulaModel m) => _hasFilesOf(m);

  @override
  Future<void> install() async {
    await _settle();
    if (model == FormulaModel.texteller && tellerRepo.isEmpty) {
      error = 'There is no download address for the TexTeller files in this build (see tool/texteller_models.py).';
      notifyListeners();
      return;
    }
    await super.install();
    if (model == FormulaModel.texteller && installed) await _checkDownload();
  }

  /// Compares the downloaded TexTeller files with [tellerChecksums]; a file that differs is not kept.
  Future<void> _checkDownload() async {
    for (final entry in _checksums.entries) {
      final f = await file(entry.key);
      await ensureWebFile(f.path); // (in a browser a model's file may be left empty until it is needed)
      final got = await f.exists() ? (await sha256.bind(f.openRead()).first).toString() : '';
      if (got == entry.value) continue;
      await remove();
      error = 'The downloaded file ${entry.key} is not the one that was published (its checksum differs). Try again.';
      notifyListeners();
      return;
    }
  }

  @override
  Future<void> unload() async {
    // (the formula reader of Pix2Text is opened for each formula and closed after it; TexTeller keeps its sessions for a while)
    final teller = _teller;
    _teller = null;
    await teller?.close();
  }

  /// The LaTeX for the formula in [strokes], read as a whole.
  @override
  Future<String> recognize(List<DrawingStroke> strokes) async {
    await _settle();
    if (!installed) throw StateError('The formula model is not installed.');
    final ink = [for (final s in strokes) if (s.color.a > 0.9 && Brushes.writes(s.brush) && s.points.length >= 2) s]; // not the highlighter
    if (ink.isEmpty) return '';
    return model == FormulaModel.texteller ? _recognizeWithTexTeller(ink) : _recognizeWithPix2Text(ink);
  }

  Future<String> _recognizeWithPix2Text(List<DrawingStroke> ink) async {
    final pixels = toModelInput(await renderInkForModel(ink));
    final model = await _open((await file('encoder_model.onnx')).path, (await file('decoder_model.onnx')).path);
    final List<int> ids;
    try {
      ids = await greedyDecodeMath(model, pixels);
    } finally {
      await model.close();
    }
    final vocab = _vocab ??= MathVocab.parse(await _loadVocab());
    return vocab.decode(ids);
  }

  /// The pens (as a part of the usual one) that the other readings are made with: see [recognizeAgain].
  static const otherPens = <double>[0.7, 1.4];

  /// What the writing reads as with a thinner and a thicker pen than usual: the picture of the ink is what TexTeller is most sensitive to, so
  /// a character that it only gets right with one of them shows up as a difference. Only TexTeller does this (the other reader gets a picture of one
  /// thickness only). The readings are not compared with the usual one here; that is for who asks (they may be the same).
  @override
  Future<List<String>> recognizeAgain(List<DrawingStroke> strokes) async {
    await _settle();
    if (!installed || model != FormulaModel.texteller) return const [];
    final ink = [for (final s in strokes) if (s.color.a > 0.9 && Brushes.writes(s.brush) && s.points.length >= 2) s];
    if (ink.isEmpty) return const [];
    final out = <String>[];
    for (final pen in otherPens) {
      final again = (await _recognizeWithTexTeller(ink, penScale: pen, again: false)).trim();
      if (again.isNotEmpty && !out.contains(again)) out.add(again);
    }
    return out;
  }

  Future<String> _recognizeWithTexTeller(List<DrawingStroke> ink, {double penScale = 1, bool again = true}) {
    // (one formula at a time: the model keeps its sessions between formulas)
    final result = _turn.then((_) async {
      final teller = _teller ??= await _openTeller((await file('encoder.onnx')).path, (await file('decoder.onnx')).path);
      final vocab = _tellerVocab ??= MathVocab.parse(await _loadTellerVocab());
      Future<TexTellerReading> look(double pen) async {
        final pixels = await renderInkForTexTeller(ink, penScale: pen);
        return teller is ScoredTexTeller ? teller.readScored(pixels) : TexTellerReading(await teller.read(pixels), 0);
      }

      final doubt = (await _readSecondLook()).doubtBelow;
      var best = await look(penScale);
      // a line the model is unsure of is read with a thinner and a thicker pen as well, and the surest reading is kept
      if (again && best.logProb < doubt) {
        for (final pen in otherPens) {
          final other = await look(penScale * pen);
          if (other.logProb > best.logProb) best = other;
        }
      }
      return texTellerLatex(vocab, best.ids);
    });
    _turn = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

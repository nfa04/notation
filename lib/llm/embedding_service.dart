import 'dart:async';
import 'onnx_session.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/settings_repository.dart';
import '../ink/ink_recognizer.dart' show HandwritingStatus;
import 'model_files.dart';
import 'unigram_tokenizer.dart';
import 'wordpiece_tokenizer.dart';

/// Something that turns text into a vector in which texts about the same thing
/// lie close together. The vectors have length 1.
abstract class TextEmbedder {
  /// Names the model; vectors of different models cannot be compared.
  String get modelId;

  Future<Float32List> embed(String text);
}

/// How alike two vectors of length 1 are: 1 for the same direction, near 0 for unrelated texts.
double cosine(List<double> a, List<double> b) {
  var sum = 0.0;
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

/// One of the sentence-embedding models on offer.
class EmbeddingModelSpec {
  final String id, label, description, folder;
  final String model, tokenizer;
  final int modelMb, tokenizerMb;

  /// The model wants an input of token types (all zeros) besides the ids.
  final bool tokenTypes;
  final bool unigram;

  const EmbeddingModelSpec({
    required this.id,
    required this.label,
    required this.description,
    required this.folder,
    required this.model,
    required this.tokenizer,
    required this.modelMb,
    required this.tokenizerMb,
    this.tokenTypes = true,
    this.unigram = false,
  });

  Map<String, ({String url, int megabytes})> get files => {
        'model.onnx': (url: model, megabytes: modelMb),
        'tokenizer.json': (url: tokenizer, megabytes: tokenizerMb),
      };

  /// More than 50 languages, German among them (Apache-2.0 licence).
  static const multilingual = EmbeddingModelSpec(
    id: 'multilingual-minilm',
    label: 'Many languages',
    description: 'paraphrase-multilingual-MiniLM-L12-v2: more than 50 languages, German and English mixed.',
    folder: 'embed_multilingual',
    model: 'https://huggingface.co/Xenova/paraphrase-multilingual-MiniLM-L12-v2/resolve/main/onnx/model_quantized.onnx',
    tokenizer: 'https://huggingface.co/Xenova/paraphrase-multilingual-MiniLM-L12-v2/resolve/main/tokenizer.json',
    modelMb: 118,
    tokenizerMb: 17,
    unigram: true,
  );

  /// English only, but a fifth of the size and faster (Apache-2.0 licence).
  static const english = EmbeddingModelSpec(
    id: 'minilm-l6',
    label: 'English, small',
    description: 'all-MiniLM-L6-v2: English only, small and fast.',
    folder: 'embed_english',
    model: 'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/onnx/model_quantized.onnx',
    tokenizer: 'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/tokenizer.json',
    modelMb: 23,
    tokenizerMb: 1,
  );

  static const all = [multilingual, english];
}

/// What runs the model: the ids of one window of text in, the model's output for each token out
/// (as `tokens x width` numbers in one list). Tests pass a fake.
typedef EmbedRun = Future<List<double>> Function(String modelPath, List<int> ids, bool tokenTypes, int width);

/// A sentence-embedding transformer on the device, run by ONNX Runtime. The model
/// is downloaded when wanted and kept; it is freed a little while after its last use.
class EmbeddingService extends ModelFilesService implements TextEmbedder {
  static const _modelKey = 'embedding_model';

  final SettingsRepository? _settings;
  final Future<Directory> Function() _modelsRoot;
  final EmbedRun _run;
  final Duration keepLoaded;

  EmbeddingService({
    SettingsRepository? settings,
    Future<Directory> Function()? modelsRoot,
    EmbedRun? run,
    super.download,
    this.keepLoaded = const Duration(seconds: 60),
  })  : _settings = settings,
        _modelsRoot = modelsRoot ?? (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'models'))),
        _run = run ?? _runOnnx,
        super(files: EmbeddingModelSpec.multilingual.files, folderName: 'embed');

  EmbeddingModelSpec _spec = EmbeddingModelSpec.multilingual;
  EmbeddingModelSpec get spec => _spec;

  /// The models there are to choose from.
  List<EmbeddingModelSpec> get specs => EmbeddingModelSpec.all;

  @override
  String get modelId => _spec.id;

  @override
  Future<Directory> directory() async => Directory(p.join((await _modelsRoot()).path, _spec.folder));

  @override
  Future<void> load() async {
    final saved = await _settings?.get(_modelKey);
    _spec = specs.where((s) => s.id == saved).firstOrNull ?? _spec;
    files = _spec.files;
    await super.load();
  }

  Future<void> select(EmbeddingModelSpec next) async {
    if (next.id == _spec.id || status == HandwritingStatus.downloading) return;
    await unload();
    _spec = next;
    files = next.files;
    await _settings?.set(_modelKey, next.id);
    await super.load();
  }

  dynamic _tokenizer;
  String? _tokenizerFor;
  Timer? _unloadTimer;
  Future<void> _queue = Future.value();

  @override
  Future<void> unload() async {
    _unloadTimer?.cancel();
    _tokenizer = null;
    _tokenizerFor = null;
    await _closeSession();
  }

  @override
  Future<Float32List> embed(String text) {
    final result = _queue.then((_) => _embed(text));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static const _width = 384;

  Future<Float32List> _embed(String text) async {
    if (!installed) throw StateError('The sentence model is not downloaded yet.');
    _unloadTimer?.cancel();
    try {
      final spec = _spec;
      if (_tokenizerFor != spec.id) {
        final source = await (await file('tokenizer.json')).readAsString();
        _tokenizer = spec.unigram ? UnigramTokenizer.parse(source) : WordPieceTokenizer.parse(source);
        _tokenizerFor = spec.id;
      }
      final windows = (spec.unigram ? (_tokenizer as UnigramTokenizer).windows(text) : (_tokenizer as WordPieceTokenizer).windows(text));
      final total = Float32List(_width);
      final path = (await file('model.onnx')).path;
      for (final ids in windows) {
        final out = await _run(path, ids, spec.tokenTypes, _width);
        // the mean of the tokens is the vector of the window
        final mean = Float32List(_width);
        final tokens = out.length ~/ _width;
        for (var t = 0; t < tokens; t++) {
          for (var d = 0; d < _width; d++) {
            mean[d] += out[t * _width + d] / tokens;
          }
        }
        _normalize(mean);
        for (var d = 0; d < _width; d++) {
          total[d] += mean[d];
        }
      }
      _normalize(total);
      return total;
    } catch (e) {
      await unload(); // start from scratch next time
      rethrow;
    } finally {
      _unloadTimer = Timer(keepLoaded, unload);
    }
  }

  static void _normalize(Float32List v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return;
    for (var i = 0; i < v.length; i++) {
      v[i] /= norm;
    }
  }

  @override
  void dispose() {
    _unloadTimer?.cancel();
    super.dispose();
  }
}

OrtSession? _session;
String? _sessionPath;

Future<void> _closeSession() async {
  final s = _session;
  _session = null;
  _sessionPath = null;
  await s?.close();
}

Future<List<double>> _runOnnx(String path, List<int> ids, bool tokenTypes, int width) async {
  if (_sessionPath != path) {
    await _closeSession();
    _session = await openOnnxSession(path, options: OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1));
    _sessionPath = path;
  }
  final session = _session!;
  final shape = [1, ids.length];
  final inputs = <String, OrtValue>{
    'input_ids': await int64Value(ids, shape),
    'attention_mask': await int64Value(List.filled(ids.length, 1), shape),
    if (tokenTypes && session.inputNames.contains('token_type_ids'))
      'token_type_ids': await int64Value(List.filled(ids.length, 0), shape),
  };
  try {
    final out = await session.run(inputs);
    final hidden = out['last_hidden_state'] ?? out.values.first;
    final values = (await hidden.asFlattenedList()).map((e) => (e as num).toDouble()).toList();
    for (final v in out.values) {
      await v.dispose();
    }
    return values;
  } finally {
    for (final v in inputs.values) {
      await v.dispose();
    }
  }
}

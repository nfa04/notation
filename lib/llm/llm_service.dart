import 'dart:async';

import 'causal_lm.dart';
import 'model_files.dart';
import 'onnx_qwen.dart';
import 'qwen_tokenizer.dart';

/// A small language model on the device (Qwen3-0.6B, Apache-2.0 licence, run by
/// ONNX Runtime) that writes short titles. The model (about 630 MB) is
/// downloaded on request; nothing is sent away.
class LlmService extends ModelFilesService {
  static const _repo = 'https://huggingface.co/onnx-community/Qwen3-0.6B-ONNX/resolve/main';
  static const modelFiles = {
    'model_int8.onnx': (url: '$_repo/onnx/model_int8.onnx', megabytes: 618),
    'tokenizer.json': (url: '$_repo/tokenizer.json', megabytes: 9),
  };

  /// How long the model stays in memory after its last use.
  final Duration keepLoaded;

  final Future<CausalLm> Function(String modelPath) _open;

  LlmService({
    Future<CausalLm> Function(String)? open,
    super.modelDirectory,
    super.download,
    this.keepLoaded = const Duration(seconds: 30),
  })  : _open = open ?? ((path) async => OnnxQwen(path)),
        super(files: modelFiles, folderName: 'llm');

  QwenTokenizer? _tokenizer;
  CausalLm? _model;
  Timer? _unload;
  Future<void> _queue = Future.value();

  @override
  Future<void> unload() => _unloadNow();

  Future<void> _unloadNow() async {
    _unload?.cancel();
    final model = _model;
    _model = null;
    _tokenizer = null;
    await model?.close();
  }

  static const _system = 'Turn the text into a short task title of at most 6 words, in the same language. '
      'Keep the subject and any place or room. Do not add anything. Answer with the title only.';

  static const _examples = [
    ('Midterm exam, room B12', 'Midterm exam (room B12)'),
    ('Abgabe Projektbericht', 'Projektbericht abgeben'),
    ('Lab report 3 due', 'Hand in lab report 3'),
    ("Prof. Müller's office hours, next on in HG E 3.2", 'Office hours, Prof. Müller (HG E 3.2)'),
    ('Registration deadline for the exam session', 'Register for the exam session'),
  ];

  /// The chat prompt in two parts: the instructions and examples, the same every
  /// time, and the question (Qwen's format, with thinking switched off).
  static (String, String) promptParts(String text) {
    final b = StringBuffer('<|im_start|>system\n$_system<|im_end|>\n');
    for (final (q, a) in _examples) {
      b.write('<|im_start|>user\n$q<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n$a<|im_end|>\n');
    }
    return (b.toString(), '<|im_start|>user\n$text<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n');
  }

  static String promptFor(String text) {
    final (fixed, question) = promptParts(text);
    return fixed + question;
  }

  /// A short title for [text], or null when there is no model or it came up
  /// with something that is not about [text] (a small model sometimes invents).
  /// One request at a time; the model is freed a little after the last one.
  Future<String?> shortTitle(String text) {
    final result = _queue.then((_) => _shortTitle(text));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _shortTitle(String text) async {
    final input = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!installed || input.isEmpty) return null;
    // a line of a few words is a title already, and a title takes seconds to write
    if (input.split(' ').length <= 3) return null;
    _unload?.cancel();
    try {
      final tokenizer = _tokenizer ??= QwenTokenizer.parse(await (await file('tokenizer.json')).readAsString());
      final model = _model ??= await _open((await file('model_int8.onnx')).path);
      // the part before the question is cut at a special token, so the two
      // halves are tokenized exactly as the whole would be
      final (fixed, question) = promptParts(input);
      final start = tokenizer.encode(fixed);
      final ids = await model.generate(
        [...start, ...tokenizer.encode(question)],
        sharedPrefix: start.length,
        maxNewTokens: 24,
        stop: {tokenizer.idOf('<|im_end|>')!, tokenizer.idOf('<|endoftext|>')!},
      );
      return acceptTitle(tokenizer.decode(ids), input);
    } catch (e) {
      await _unloadNow(); // start from scratch next time
      return null;
    } finally {
      _unload = Timer(keepLoaded, _unloadNow);
    }
  }

  @override
  void dispose() {
    _unload?.cancel();
    super.dispose();
  }
}

/// [answer] tidied up, if it reads as a title of [input]: mostly the input's own
/// words, short, and not a repeat of a date. Null otherwise.
String? acceptTitle(String answer, String input) {
  var t = answer.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
  t = t.replaceAll(RegExp(r'^["“„«\s]+|["”“»\s]+$'), '').replaceAll(RegExp(r'[.,;:\s]+$'), '').trim();
  if (t.isEmpty || t.length > 80) return null;
  if (t.contains(RegExp(r'\d{1,2}[./]\d{1,2}[./]\d{2,4}|\d{4}-\d{2}-\d{2}'))) return null;

  List<String> words(String s) =>
      RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(s.toLowerCase()).map((m) => m.group(0)!).toList();
  final have = words(input).toSet();
  final mine = words(t);
  if (mine.isEmpty) return null;
  // a word counts as known if it is in the input, or shares most of its start with one
  // that is (register / registration); a few new words are fine, a different subject is not
  bool known(String w) => have.contains(w) || have.any((h) => _commonStart(w, h) >= 6 && _commonStart(w, h) >= 0.7 * (w.length < h.length ? w.length : h.length));
  if (mine.where(known).length / mine.length < 0.7) return null;
  return t[0].toUpperCase() + t.substring(1);
}

int _commonStart(String a, String b) {
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return i;
}

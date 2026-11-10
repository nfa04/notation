import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/ai_prompt.dart';
import '../ai/device_memory.dart';
import '../ai/text_provider.dart';
import '../data/settings_repository.dart';
import '../ink/ink_recognizer.dart' show HandwritingStatus;
import 'causal_lm.dart';
import 'chat_models.dart';
import 'model_files.dart';
import 'onnx_qwen.dart';
import 'qwen_tokenizer.dart';
import '../l10n/language.dart';

/// A Qwen language model on the device (Apache-2.0 licence, 8-bit weights, run by
/// ONNX Runtime) for answers that take more than a few words. Several sizes
/// are on offer ([ChatModelSpec.all]); each is downloaded when chosen and kept,
/// and each is only offered on devices with the memory it needs. The model is
/// freed soon after each answer.
class OnnxChatProvider extends ModelFilesService implements TextModelProvider, SelectableModels, ContextSized {
  static const _modelKey = 'ai_on_device_model';

  final SettingsRepository? _settings;
  final Future<int?> Function() _ram;
  final Future<CausalLm> Function(String modelPath, ChatModelSpec spec) _open;
  final Future<Directory> Function() _modelsRoot;

  /// How long the model stays in memory after an answer.
  final Duration keepLoaded;

  /// The models there are to choose from.
  final List<ChatModelSpec> specs;

  OnnxChatProvider({
    SettingsRepository? settings,
    Future<int?> Function()? ram,
    Future<CausalLm> Function(String, ChatModelSpec)? open,
    Future<Directory> Function()? modelsRoot,
    super.download,
    this.keepLoaded = const Duration(seconds: 30),
    this.specs = ChatModelSpec.all,
  })  : _settings = settings,
        _ram = ram ?? totalRamMb,
        _open = open ?? ((path, spec) async => OnnxQwen(path, layers: spec.layers, kvHeads: spec.kvHeads, headDim: spec.headDim, threads: onnxThreads)),
        _modelsRoot = modelsRoot ?? (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'models'))),
        super(files: ChatModelSpec.qwen3Large.files, folderName: 'llm_large');

  late ChatModelSpec _spec = specs.first;
  int? _ramMb;
  bool _ramKnown = false;
  final Set<String> _installed = {};

  ChatModelSpec get spec => _spec;

  @override
  Future<Directory> directory() async => Directory(p.join((await _modelsRoot()).path, _spec.folder));

  /// In a browser the whole model is in the memory of one tab, several times over while it is opened (the file, the address
  /// the runtime reads it from, its own copy): only the small ones can work there.
  bool _fits(ChatModelSpec s) => (!kIsWeb || s.downloadMb <= 1000) && (!_ramKnown || _ramMb == null || _ramMb! >= s.minRamMb);

  /// Reads the memory of the device and which models are there; call once at the start.
  @override
  Future<void> load() async {
    _ramMb = await _ram();
    _ramKnown = true;
    final saved = await _settings?.get(_modelKey);
    // without a choice: the biggest model that fits and is not a huge download, so that a
    // small device still gets an answer and nobody is sent off to fetch 10 GB
    _spec = specs.where((s) => s.id == saved).firstOrNull ??
        specs.lastWhere((s) => _fits(s) && s.downloadMb <= 2200, orElse: () => specs.first);
    files = _spec.files;
    await _refreshInstalled();
    await super.load();
  }

  Future<void> _refreshInstalled() async {
    final found = <String>{};
    final root = await _modelsRoot();
    for (final s in specs) {
      var all = true;
      for (final name in s.files.keys) {
        all = all && await File(p.join(root.path, s.folder, name)).exists();
      }
      if (all) found.add(s.id);
    }
    _installed
      ..clear()
      ..addAll(found); // (not one by one: the list never shows half of an answer)
  }

  @override
  Future<void> install() async {
    await super.install();
    await _refreshInstalled();
    notifyListeners();
  }

  @override
  Future<void> remove() async {
    await super.remove();
    await _refreshInstalled();
    notifyListeners();
  }

  // ---- the choice of model

  @override
  String get selectedModelId => _spec.id;

  @override
  List<ModelOption> get modelOptions => [
        for (final s in specs)
          ModelOption(
            id: s.id,
            label: s.label,
            detail: tr('{size} GB download, needs a device with {need} GB or more', {'size': (s.downloadMb / 1000).toStringAsFixed(1), 'need': s.neededGb}),
            installed: _installed.contains(s.id),
            supported: _fits(s),
            reason: _reasonFor(s),
          ),
      ];

  String? _reasonFor(ChatModelSpec s) => _fits(s)
      ? null
      : tr('This needs a device with at least {need} GB of memory; this one has {have} GB.',
          {'need': s.neededGb, 'have': ((_ramMb ?? 0) / 1000).toStringAsFixed(1)});

  @override
  Future<void> selectModel(String id) async {
    final next = specs.where((s) => s.id == id).firstOrNull;
    if (next == null || next.id == _spec.id || status == HandwritingStatus.downloading) return;
    await unload();
    _spec = next;
    files = next.files;
    await _settings?.set(_modelKey, next.id);
    await super.load(); // is it there?
  }

  // ---- the provider

  /// False when the chosen model needs more memory than the device has. A
  /// device that cannot be asked is given the benefit of the doubt.
  bool get supported => _fits(_spec);

  @override
  String get id => 'on-device';

  @override
  String get label => 'On this device';

  @override
  String get description =>
      'A Qwen model (Apache-2.0 licence) runs on this device; nothing is sent away. Bigger ones write better '
      'summaries and are slower; they use memory about the size of their download while they work.';

  @override
  ProviderState get state {
    if (!supported) return ProviderState.unavailable;
    if (installed) return ProviderState.ready;
    return status == HandwritingStatus.downloading ? ProviderState.downloading : ProviderState.needsDownload;
  }

  @override
  String? get reason => _reasonFor(_spec);

  @override
  Future<void> prepare() => install();

  QwenTokenizer? _tokenizer;
  CausalLm? _model;
  ChatModelSpec? _loadedSpec;
  Timer? _unloadTimer;
  Future<void> _queue = Future.value();

  @override
  Future<void> unload() async {
    _unloadTimer?.cancel();
    final model = _model;
    _model = null;
    _tokenizer = null;
    _loadedSpec = null;
    await model?.close();
  }

  /// How much text it is sensible to give this model: small ones are slow
  /// and have little room, bigger ones read more.
  @override
  int get contextChars => _spec.downloadMb < 1000 ? 3500 : (_spec.downloadMb < 2500 ? 6000 : 10000);

  /// Qwen's chat format; [thinking] adds the empty thinking block Qwen3 expects.
  /// What was said before comes between the standing instructions and the question.
  static ({String fixed, String question}) chat(AiPrompt prompt, {bool thinking = true}) => (
        fixed: '<|im_start|>system\n${prompt.system}<|im_end|>\n',
        question: [
          for (final t in prompt.history) '<|im_start|>${t.fromUser ? 'user' : 'assistant'}\n${t.text}<|im_end|>\n',
          '<|im_start|>user\n${prompt.user}<|im_end|>\n<|im_start|>assistant\n${thinking ? '<think>\n\n</think>\n\n' : ''}',
        ].join(),
      );

  @override
  Future<String> complete(
    AiPrompt prompt, {
    int maxTokens = 256,
    void Function(String partial)? onPartial,
    AiCancel? cancel,
  }) {
    final result = _queue.then((_) => _complete(prompt, maxTokens, onPartial, cancel));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _complete(AiPrompt prompt, int maxTokens, void Function(String)? onPartial, AiCancel? cancel) async {
    if (!supported) throw StateError(reason!);
    if (!installed) throw StateError('The language model is not downloaded yet.');
    if (cancel?.cancelled ?? false) return '';
    _unloadTimer?.cancel();
    final spec = _spec;
    try {
      if (_loadedSpec != null && _loadedSpec!.id != spec.id) await unload(); // another model was chosen meanwhile
      final tokenizer = _tokenizer ??= QwenTokenizer.parse(await (await file('tokenizer.json')).readAsString());
      final model = _model ??= await _open((await file(spec.modelFile)).path, spec);
      _loadedSpec = spec;
      final parts = chat(prompt, thinking: spec.thinking);
      final start = tokenizer.encode(parts.fixed);
      var shown = 0;
      final ids = await model.generate(
        [...start, ...tokenizer.encode(parts.question)],
        sharedPrefix: start.length,
        maxNewTokens: maxTokens,
        stop: {tokenizer.idOf('<|im_end|>')!, tokenizer.idOf('<|endoftext|>')!},
        repetitionPenalty: prompt.exact ? 1 : 1.1,
        shouldStop: () => cancel?.cancelled ?? false,
        onProgress: onPartial == null
            ? null
            : (tokens) {
                // a few tokens at a time: decoding the whole answer for each is wasteful
                if (tokens.length - shown >= 3) {
                  shown = tokens.length;
                  onPartial(tokenizer.decode(tokens));
                }
              },
      );
      return tokenizer.decode(ids).trim();
    } catch (e) {
      await unload(); // start from scratch next time
      rethrow;
    } finally {
      _unloadTimer = Timer(keepLoaded, unload);
    }
  }

  @override
  void dispose() {
    _unloadTimer?.cancel();
    super.dispose();
  }
}

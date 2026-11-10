/// A Qwen model that can be run on the device for chat-like requests: the ONNX
/// export by onnx-community, with 4-bit weights (MatMulNBits, which ONNX Runtime
/// computes on all cores: about ten times faster per token than the 8-bit export,
/// which runs on one) and a cache of 32-bit numbers.
class ChatModelSpec {
  final String id;
  final String family;
  final String size;

  /// Name of the repository at onnx-community on Hugging Face.
  final String repo;

  /// Where the files go, under the models folder. The first two are shared with
  /// other features that use the same files, or with downloads of earlier versions.
  final String folder;
  final int modelMb;
  final int tokenizerMb;

  /// The model's file name, and where in the repository it and the tokenizer are.
  final String modelFile;
  final String modelDir;

  /// Big models keep their weights in files next to the model file (name, size).
  final List<({String name, int megabytes})> dataFiles;

  /// The memory in the text shown to the user, when "minRamMb / 1000" would mislead.
  final int? ramGb;

  /// Memory a device must report to be offered it (a "4 GB" phone says about 3.7).
  final int minRamMb;

  /// The shape of the attention cache.
  final int layers, kvHeads, headDim;

  /// Whether the chat format wants an empty thinking block before the answer
  /// (Qwen3); Qwen2.5 has none.
  final bool thinking;

  const ChatModelSpec({
    required this.id,
    required this.family,
    required this.size,
    required this.repo,
    required this.folder,
    required this.modelMb,
    required this.tokenizerMb,
    required this.minRamMb,
    required this.layers,
    required this.kvHeads,
    required this.headDim,
    required this.thinking,
    this.modelFile = 'model_int8.onnx',
    this.modelDir = 'onnx',
    this.tokenizerDir = '',
    this.dataFiles = const [],
    this.ramGb,
  });

  /// Where the tokenizer is in the repository ('' is the top).
  final String tokenizerDir;

  int get neededGb => ramGb ?? (minRamMb / 1000).round();

  String get label => '$family $size';

  int get downloadMb => modelMb + tokenizerMb;

  Map<String, ({String url, int megabytes})> get files {
    final base = 'https://huggingface.co/onnx-community/$repo/resolve/main';
    String at(String dir, String name) => dir.isEmpty ? '$base/$name' : '$base/$dir/$name';
    final dataMb = dataFiles.fold<int>(0, (sum, f) => sum + f.megabytes);
    return {
      modelFile: (url: at(modelDir, modelFile), megabytes: modelMb - dataMb),
      for (final f in dataFiles) f.name: (url: at(modelDir, f.name), megabytes: f.megabytes),
      'tokenizer.json': (url: at(tokenizerDir, 'tokenizer.json'), megabytes: tokenizerMb),
    };
  }

  static const qwen3Small = ChatModelSpec(
    id: 'qwen3-0.6b',
    family: 'Qwen3',
    size: '0.6B',
    repo: 'Qwen3-0.6B-ONNX',
    folder: 'llm', // (the model that writes titles)
    modelMb: 919,
    tokenizerMb: 9,
    minRamMb: 2500,
    layers: 28,
    kvHeads: 8,
    headDim: 128,
    thinking: true,
    modelFile: 'model_q4.onnx',
  );

  static const qwen3Large = ChatModelSpec(
    id: 'qwen3-1.7b',
    family: 'Qwen3',
    size: '1.7B',
    repo: 'Qwen3-1.7B-ONNX',
    folder: 'llm_large',
    modelMb: 2147,
    tokenizerMb: 9,
    minRamMb: 4000,
    layers: 28,
    kvHeads: 8,
    headDim: 128,
    thinking: true,
    modelFile: 'model_q4.onnx',
  );

  static const qwen25Small = ChatModelSpec(
    id: 'qwen2.5-0.5b',
    family: 'Qwen2.5',
    size: '0.5B',
    repo: 'Qwen2.5-0.5B-Instruct',
    folder: 'llm_qwen25_05b',
    modelMb: 786,
    tokenizerMb: 7,
    minRamMb: 2500,
    layers: 24,
    kvHeads: 2,
    headDim: 64,
    thinking: false,
    modelFile: 'model_q4.onnx',
  );

  static const qwen25Large = ChatModelSpec(
    id: 'qwen2.5-1.5b',
    family: 'Qwen2.5',
    size: '1.5B',
    repo: 'Qwen2.5-1.5B-Instruct',
    folder: 'llm_qwen25_15b',
    modelMb: 1787,
    tokenizerMb: 7,
    minRamMb: 4000,
    layers: 28,
    kvHeads: 2,
    headDim: 128,
    thinking: false,
    modelFile: 'model_q4.onnx',
  );

  /// 4-bit weights in three files; the instruct version has no thinking block.
  static const qwen3Mid = ChatModelSpec(
    id: 'qwen3-4b-2507',
    family: 'Qwen3 (2507)',
    size: '4B',
    repo: 'Qwen3-4B-Instruct-2507-ONNX',
    folder: 'llm_qwen3_4b',
    modelMb: 3962,
    tokenizerMb: 9,
    minRamMb: 7000,
    ramGb: 8,
    layers: 36,
    kvHeads: 8,
    headDim: 128,
    thinking: false,
    modelFile: 'model_q4.onnx',
    dataFiles: [(name: 'model_q4.onnx_data', megabytes: 2086), (name: 'model_q4.onnx_data_1', megabytes: 1876)],
  );

  /// The exports for ONNX Runtime GenAI, 4-bit, the variant for CPUs.
  static const _genai = 'onnxruntime/cpu_and_mobile/cpu-int4-kld-block-128';

  static const qwen3Big = ChatModelSpec(
    id: 'qwen3-8b',
    family: 'Qwen3',
    size: '8B',
    repo: 'Qwen3-8B-ONNX',
    folder: 'llm_qwen3_8b',
    modelMb: 6077,
    tokenizerMb: 11,
    minRamMb: 11000,
    ramGb: 12,
    layers: 36,
    kvHeads: 8,
    headDim: 128,
    thinking: true,
    modelFile: 'model.onnx',
    modelDir: _genai,
    tokenizerDir: _genai,
    dataFiles: [(name: 'model.onnx.data', megabytes: 6076)],
  );

  static const qwen3Huge = ChatModelSpec(
    id: 'qwen3-14b',
    family: 'Qwen3',
    size: '14B',
    repo: 'Qwen3-14B-ONNX',
    folder: 'llm_qwen3_14b',
    modelMb: 9982,
    tokenizerMb: 11,
    minRamMb: 22000,
    ramGb: 24,
    layers: 40,
    kvHeads: 8,
    headDim: 128,
    thinking: true,
    modelFile: 'model.onnx',
    modelDir: _genai,
    tokenizerDir: _genai,
    dataFiles: [(name: 'model.onnx.data', megabytes: 9981)],
  );

  /// Smallest first.
  static const all = [qwen25Small, qwen3Small, qwen25Large, qwen3Large, qwen3Mid, qwen3Big, qwen3Huge];
}

import 'package:flutter/foundation.dart';

import 'ai_prompt.dart';

/// Lets the person who asked stop a request that is taking long.
class AiCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Why a provider cannot be used right now.
enum ProviderState {
  /// Ready to answer.
  ready,

  /// Would work after a download (a model on the device).
  needsDownload,

  /// Being downloaded.
  downloading,

  /// Will not work here (too little memory, no key, ...); see [TextModelProvider.reason].
  unavailable,
}

/// Something that answers a prompt with text: a model on the device now, a
/// cloud service later. Everything that asks (summaries, and what else may
/// come) goes through this, and builds its prompt as an [AiPrompt], so a new
/// provider needs nothing else.
abstract class TextModelProvider implements Listenable {
  /// Stable name, stored in the settings.
  String get id;

  /// What the person sees ("On this device").
  String get label;

  /// One sentence for the settings.
  String get description;

  ProviderState get state;

  /// For [ProviderState.unavailable]: why, in words.
  String? get reason;

  /// Makes the provider ready (downloads a model); a no-op where nothing is needed.
  Future<void> prepare();

  /// The answer to [prompt]. [onPartial] gets the text so far as it grows; once
  /// [cancel] is cancelled the answer so far is returned. Throws if the
  /// provider cannot answer.
  Future<String> complete(
    AiPrompt prompt, {
    int maxTokens = 256,
    void Function(String partial)? onPartial,
    AiCancel? cancel,
  });
}


/// A provider whose service takes tools (functions) with the request and answers with calls to them, so that no model has to write
/// a call as text.
abstract class ToolCalling {
  /// The answer to [prompt] when the model may call [tools]. Throws [ToolsNotSupported] when this service or model cannot.
  Future<AiToolReply> completeWithTools(
    AiPrompt prompt,
    List<AiToolSpec> tools, {
    int maxTokens = 256,
    void Function(String partial)? onPartial,
    AiCancel? cancel,
  });
}

/// The service does not take tools (many models of a server of your own do not).
class ToolsNotSupported implements Exception {
  final String message;
  ToolsNotSupported(this.message);
  @override
  String toString() => message;
}

/// A provider that can say how much text it is sensible to hand it at once
/// (in characters): a small model on a phone reads a few pages, a cloud model
/// a whole book.
abstract class ContextSized {
  int get contextChars;
}

/// One choice in a provider that offers several models.
class ModelOption {
  final String id;
  final String label;

  /// Size and the like, for the list.
  final String detail;
  final bool installed;

  /// False when this device cannot run it; [reason] says why.
  final bool supported;
  final String? reason;

  const ModelOption({
    required this.id,
    required this.label,
    required this.detail,
    required this.installed,
    required this.supported,
    this.reason,
  });
}

/// A provider with a choice of models (different sizes of the same kind).
abstract class SelectableModels {
  List<ModelOption> get modelOptions;
  String get selectedModelId;
  Future<void> selectModel(String id);
}

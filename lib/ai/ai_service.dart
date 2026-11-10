import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import 'ai_prompt.dart';
import 'flashcards.dart';
import 'text_provider.dart';
import '../l10n/language.dart';

/// The AI features of the app: which provider answers, what the prompts say, and
/// the features themselves (summaries for now). A feature builds an [AiPrompt]
/// and hands it to the chosen [TextModelProvider]; it never knows which one
/// answers, so a cloud provider is a new entry in [providers] and nothing else.
class AiService extends ChangeNotifier {
  static const _providerKey = 'ai_provider';
  static const _summaryKey = 'ai_summary_config';

  final SettingsRepository? _settings;
  final List<TextModelProvider> providers;

  AiService({SettingsRepository? settings, required this.providers}) : _settings = settings {
    for (final p in providers) {
      p.addListener(notifyListeners);
    }
  }

  String? _providerId;
  SummaryConfig _summary = SummaryConfig.defaults;
  final Map<AiTask, PromptTemplate> _templates = {for (final t in AiTask.values) t: PromptTemplate.defaults(t)};

  SummaryConfig get summaryConfig => _summary;

  /// The prompt of "Tell me more" and "Ask a question", as set in the Settings.
  PromptTemplate template(AiTask task) => _templates[task]!;

  /// The provider that answers: the one chosen, else the first.
  TextModelProvider? get provider {
    if (providers.isEmpty) return null;
    return providers.where((p) => p.id == _providerId).firstOrNull ?? providers.first;
  }

  Future<void> load() async {
    _providerId = await _settings?.get(_providerKey);
    _summary = SummaryConfig.decode(await _settings?.get(_summaryKey));
    for (final t in AiTask.values) {
      _templates[t] = PromptTemplate.decode(t, await _settings?.get(t.settingsKey));
    }
    notifyListeners();
  }

  Future<void> chooseProvider(String id) async {
    _providerId = id;
    notifyListeners();
    await _settings?.set(_providerKey, id);
  }

  Future<void> setSummaryConfig(SummaryConfig config) async {
    _summary = config;
    notifyListeners();
    await _settings?.set(_summaryKey, config.encode());
  }

  Future<void> setTemplate(PromptTemplate template) async {
    _templates[template.task] = template;
    notifyListeners();
    await _settings?.set(template.task.settingsKey, template.encode());
  }

  /// Whether summaries can be offered at all (a provider that can work here).
  bool get canSummarize => provider != null && provider!.state != ProviderState.unavailable;

  /// A summary of [text], written by the provider with the prompt of the settings.
  Future<String> summarize(
    String text, {
    void Function(String partial)? onPartial,
    AiCancel? cancel,
    int maxTokens = 220,
  }) {
    final p = provider;
    if (p == null) throw StateError(tr('No AI provider is set up.'));
    return p.complete(_summary.promptFor(text), maxTokens: maxTokens, onPartial: onPartial, cancel: cancel);
  }

  /// How much text (characters) the chosen provider should be given at once.
  int get contextChars {
    final p = provider;
    return p is ContextSized ? (p as ContextSized).contextChars : 6000;
  }

  /// The answer to [question] in a conversation about a document: [excerpts]
  /// are the passages that matter for it, [history] what was said before.
  Future<String> converse(
    String excerpts,
    String question, {
    List<AiTurn> history = const [],
    void Function(String partial)? onPartial,
    AiCancel? cancel,
    int maxTokens = 400,
  }) =>
      _need().complete(
        template(AiTask.assistant).promptFor(excerpts, question: question, history: history, maxText: contextChars + 2000),
        maxTokens: maxTokens,
        onPartial: onPartial,
        cancel: cancel,
      );

  /// The answer to [question] from [passages] taken from several of the user's notes, each marked [Note - Page].
  Future<String> converseNotes(
    String passages,
    String question, {
    List<AiTurn> history = const [],
    void Function(String partial)? onPartial,
    AiCancel? cancel,
    int maxTokens = 450,
  }) =>
      _need().complete(
        AiPrompt(
          system: notesAssistantSystem,
          user: 'Passages of the notes:\n${passages.trim().length > contextChars + 2000 ? passages.trim().substring(0, contextChars + 2000) : passages.trim()}\n\nQuestion: $question',
          history: history,
        ),
        maxTokens: maxTokens,
        onPartial: onPartial,
        cancel: cancel,
      );

  /// Flashcards: the model's answer to the request for [count] cards from [passages], for [parseFlashcards].
  Future<String> flashcards(
    String passages,
    int count, {
    void Function(String partial)? onPartial,
    AiCancel? cancel,
  }) =>
      _need().complete(flashcardPrompt(passages, count), maxTokens: 120 * count + 150, onPartial: onPartial, cancel: cancel);

  /// An explanation of [text] ("Tell me more").
  Future<String> explain(
    String text, {
    void Function(String partial)? onPartial,
    AiCancel? cancel,
    int maxTokens = 320,
  }) =>
      _need().complete(template(AiTask.explain).promptFor(text), maxTokens: maxTokens, onPartial: onPartial, cancel: cancel);

  /// The answer to [question] about [text].
  Future<String> ask(
    String text,
    String question, {
    void Function(String partial)? onPartial,
    AiCancel? cancel,
    int maxTokens = 320,
  }) =>
      _need().complete(template(AiTask.ask).promptFor(text, question: question), maxTokens: maxTokens, onPartial: onPartial, cancel: cancel);

  /// The answer to a prompt that is not one of the usual tasks (what the extension maker asks for).
  Future<String> generate(
    AiPrompt prompt, {
    void Function(String partial)? onPartial,
    AiCancel? cancel,
    int maxTokens = 1800,
  }) =>
      _need().complete(prompt, maxTokens: maxTokens, onPartial: onPartial, cancel: cancel);

  /// Whether the model can be given tools with the request (and so does not have to write its calls as text).
  bool get canCallTools => provider is ToolCalling;

  /// The answer to [prompt] when the model may call [tools].
  Future<AiToolReply> generateWithTools(
    AiPrompt prompt,
    List<AiToolSpec> tools, {
    void Function(String partial)? onPartial,
    AiCancel? cancel,
    int maxTokens = 1800,
  }) {
    final p = _need();
    if (p is! ToolCalling) throw ToolsNotSupported(tr('This model cannot call tools.'));
    return (p as ToolCalling).completeWithTools(prompt, tools, maxTokens: maxTokens, onPartial: onPartial, cancel: cancel);
  }

  TextModelProvider _need() {
    final p = provider;
    if (p == null) throw StateError(tr('No AI provider is set up.'));
    return p;
  }

  @override
  void dispose() {
    for (final p in providers) {
      p.removeListener(notifyListeners);
    }
    super.dispose();
  }
}

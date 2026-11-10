import 'dart:convert';

/// What to ask a text model: the standing instructions and the request. Written
/// without anything particular to one model, so a model on the device and one
/// in the cloud can both be given it.
class AiPrompt {
  final String system;
  final String user;

  /// What was said before [user], oldest first, for a conversation.
  final List<AiTurn> history;

  /// The answer has a form that is read by a program (lines of a table, say): a model on the device then writes it without the
  /// penalty for repeated words that keeps prose from going round in circles but breaks such a form.
  final bool exact;

  const AiPrompt({required this.system, required this.user, this.history = const [], this.exact = false});
}

/// One earlier message of a conversation.
class AiTurn {
  /// True for what the person wrote, false for what the assistant answered.
  final bool fromUser;
  final String text;

  /// For a message of the assistant that asked for tools: what it asked for.
  final List<AiToolCall> calls;

  /// For what a tool answered: the id of the call it answers (the [text] is the answer).
  final String? resultOf;

  const AiTurn(this.fromUser, this.text, {this.calls = const [], this.resultOf});
}

/// A tool a model may call (a function of the API of the service): [parameters] is a JSON schema of its arguments, null for none.
class AiToolSpec {
  final String name, description;
  final Map<String, Object?>? parameters;
  const AiToolSpec(this.name, this.description, [this.parameters]);
}

/// A call a model made: which tool, with what arguments. [id] pairs it with its answer; [extra] is what the service wants back
/// with it (Gemini's thought signature), untouched.
class AiToolCall {
  final String id, name;
  final Map<String, Object?> args;

  /// Set when the arguments were not JSON that could be read.
  final String? error;
  final Object? extra;
  const AiToolCall(this.id, this.name, this.args, {this.error, this.extra});
}

/// What a model answered when it could call tools: text, and the calls it made.
class AiToolReply {
  final String text;
  final List<AiToolCall> calls;
  const AiToolReply(this.text, [this.calls = const []]);
}

/// What the assistant is told when it answers from all of the user's notes.
const notesAssistantSystem = 'You are an assistant in a note-taking app, answering questions from all of the user\'s notes. '
    'You are given the passages of the notes that matter most for the question, each marked with its note and page, like '
    '[Biology 101 - Page 3]. Answer from them and name where it comes from in brackets, like (Biology 101, p. 3). If they '
    'do not contain the answer, say so plainly, then add what you know, marked as coming from you. Be concise and answer in '
    'the language of the question.';

/// How long a summary should be.
enum SummaryLength {
  brief('One or two sentences', 'one or two sentences'),
  paragraph('A short paragraph', 'a short paragraph'),
  bullets('A bullet list', 'a short bullet list of the main points');

  final String label;

  /// How the instruction names it.
  final String phrase;

  const SummaryLength(this.label, this.phrase);
}

/// What the user can set about summaries (Settings): both texts of the prompt,
/// and the length. [instruction] takes `{text}` (the selected text) and
/// `{length}` (the length, in words).
class SummaryConfig {
  final String system;
  final String instruction;
  final SummaryLength length;

  const SummaryConfig({this.system = defaultSystem, this.instruction = defaultInstruction, this.length = SummaryLength.paragraph});

  static const defaultSystem = 'You summarize text for a note-taking app. Stay faithful to the text: '
      'do not add facts, opinions or advice. Write in the language of the text.';

  static const defaultInstruction = 'Summarize the following text in {length}.\n\n{text}';

  static const defaults = SummaryConfig();

  bool get isDefault => system == defaultSystem && instruction == defaultInstruction && length == SummaryLength.paragraph;

  SummaryConfig copyWith({String? system, String? instruction, SummaryLength? length}) => SummaryConfig(
        system: system ?? this.system,
        instruction: instruction ?? this.instruction,
        length: length ?? this.length,
      );

  Map<String, Object> toJson() => {'system': system, 'instruction': instruction, 'length': length.name};

  static SummaryConfig decode(String? source) {
    if (source == null) return defaults;
    try {
      final m = jsonDecode(source) as Map;
      String text(String key, String fallback) => m[key] is String && (m[key] as String).trim().isNotEmpty ? m[key] as String : fallback;
      return SummaryConfig(
        system: text('system', defaultSystem),
        instruction: text('instruction', defaultInstruction),
        length: SummaryLength.values.where((l) => l.name == m['length']).firstOrNull ?? SummaryLength.paragraph,
      );
    } catch (_) {
      return defaults;
    }
  }

  String encode() => jsonEncode(toJson());

  /// The longest text handed to a model; more is cut (a model on the device
  /// reads about four characters in a token and slowly).
  static const maxTextLength = 8000;

  /// The prompt for summarizing [text]. A text that does not mention `{text}`
  /// in the instruction gets it added at the end, so that what the user
  /// selected is never left out.
  AiPrompt promptFor(String text) {
    final clipped = text.trim().length > maxTextLength ? '${text.trim().substring(0, maxTextLength)}...' : text.trim();
    var user = instruction.replaceAll('{length}', length.phrase);
    user = user.contains('{text}') ? user.replaceAll('{text}', clipped) : '$user\n\n$clipped';
    return AiPrompt(system: system, user: user);
  }
}

/// The other things the assistant does with highlighted text.
enum AiTask {
  /// "Tell me more": explains the text and adds background.
  explain(
    'Tell me more',
    'You help a student understand passages from their notes. Explain clearly and concisely, in the language '
        'of the passage. If you are not sure about something, say so; do not invent facts.',
    'Tell me more about the following: explain what it means and add useful background.\n\n{text}',
    'ai_explain_config',
  ),

  /// "Ask a question" about the text.
  ask(
    'Ask a question',
    'You answer questions about a passage from the user\'s notes. Use the passage first. If it does not contain '
        'the answer, say so, then add what you know, marked as coming from you. Be concise and answer in the '
        'language of the question.',
    'Passage:\n{text}\n\nQuestion: {question}',
    'ai_ask_config',
  ),

  /// The assistant beside the document: a conversation about all of it.
  assistant(
    'Assistant',
    'You are an assistant in a note-taking app, answering questions about the user\'s document. You are given '
        'the passages of the document that matter most for the question, each marked with where it is, like '
        '[Page 3]. Answer from them and name the page in brackets, like (p. 3). If they do not contain the '
        'answer, say so plainly, then add what you know, marked as coming from you. Be concise and answer in '
        'the language of the question.',
    'Passages of the document:\n{text}\n\nQuestion: {question}',
    'ai_assistant_config',
  );

  final String label;
  final String defaultSystem;
  final String defaultInstruction;

  /// Where the template is kept in the settings.
  final String settingsKey;

  const AiTask(this.label, this.defaultSystem, this.defaultInstruction, this.settingsKey);
}

/// The prompt of one [AiTask] as the user may have changed it: both texts.
/// [instruction] takes `{text}` (the selection) and, for questions, `{question}`.
class PromptTemplate {
  final AiTask task;
  final String system;
  final String instruction;

  const PromptTemplate(this.task, {required this.system, required this.instruction});

  factory PromptTemplate.defaults(AiTask task) =>
      PromptTemplate(task, system: task.defaultSystem, instruction: task.defaultInstruction);

  bool get isDefault => system == task.defaultSystem && instruction == task.defaultInstruction;

  PromptTemplate copyWith({String? system, String? instruction}) =>
      PromptTemplate(task, system: system ?? this.system, instruction: instruction ?? this.instruction);

  String encode() => jsonEncode({'system': system, 'instruction': instruction});

  static PromptTemplate decode(AiTask task, String? source) {
    final defaults = PromptTemplate.defaults(task);
    if (source == null) return defaults;
    try {
      final m = jsonDecode(source) as Map;
      String text(String key, String fallback) => m[key] is String && (m[key] as String).trim().isNotEmpty ? m[key] as String : fallback;
      return PromptTemplate(task, system: text('system', task.defaultSystem), instruction: text('instruction', task.defaultInstruction));
    } catch (_) {
      return defaults;
    }
  }

  /// The prompt for [text] (and [question]). A template that leaves out a
  /// placeholder gets that part added at the end, so nothing the user gave is lost.
  AiPrompt promptFor(String text, {String question = '', List<AiTurn> history = const [], int? maxText}) {
    final t = text.trim();
    final limit = maxText ?? SummaryConfig.maxTextLength;
    final clipped = t.length > limit ? '${t.substring(0, limit)}...' : t;
    var user = instruction;
    if (task == AiTask.ask || task == AiTask.assistant) {
      user = user.contains('{question}') ? user.replaceAll('{question}', question.trim()) : '$user\n\n${question.trim()}';
    }
    user = user.contains('{text}') ? user.replaceAll('{text}', clipped) : '$user\n\n$clipped';
    return AiPrompt(system: system, user: user, history: history);
  }
}

/// Whether a selection is long enough to summarize: more than two words.
bool worthSummarizing(String? text) {
  final t = text?.trim();
  return t != null && RegExp(r'\S+').allMatches(t).length > 2;
}

/// Whether there is any text to ask about or explain.
bool hasWords(String? text) => text != null && RegExp(r'\S').hasMatch(text);

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ai_prompt.dart';
import 'ai_service.dart';
import 'document_index.dart';
import 'note_agent.dart';
import 'note_knowledge.dart';
import 'flashcards.dart';
import 'text_provider.dart';
import '../extensions/extension_host.dart';
import '../extensions/extension_manifest.dart';
import '../l10n/language.dart';

/// One message of the conversation with the assistant.
class ChatMessage {
  final bool fromUser;
  String text;

  /// Pages (zero-based) the answer drew on, most relevant first.
  List<int> pages;

  /// For a conversation about all notes: the notes (and pages) the answer drew on.
  List<ChatSource> sources;

  /// What the assistant did, or wants to do, on the way to this answer.
  List<AgentStep> steps = const [];
  bool failed;

  ChatMessage(this.fromUser, this.text, {this.pages = const [], this.sources = const [], this.failed = false});
}

/// A note (and the page in it, zero-based) that an answer drew on.
class ChatSource {
  final String noteId;
  final String title;
  final int? page;
  const ChatSource(this.noteId, this.title, this.page);
}

/// A conversation with the assistant about one document. Each question is
/// answered from the passages of the document that matter for it (see
/// [DocumentIndex.select]), with what was said before as the history.
class AssistantChat extends ChangeNotifier {
  final AiService ai;

  /// The text of the document as it is now (read again for every question: the
  /// note may have changed).
  final Future<DocumentIndex> Function()? index;

  /// Set for a conversation about all notes: the passages come from here (the notes closest to the question), not from [index].
  final NoteKnowledge? knowledge;

  /// Where the flashcards are kept (with the note), so that they are made once: the cards as JSON, read, written and dropped.
  final Future<String?> Function()? loadCards;
  final Future<void> Function(String json)? saveCards;
  final Future<void> Function()? dropCards;

  /// What the assistant can act on; null: it can only answer.
  final NoteAgent? agent;

  AssistantChat({required this.ai, this.index, this.knowledge, this.loadCards, this.saveCards, this.dropCards, this.agent, bool acting = false, this.onActingChanged})
      : _acting = acting,
        assert(index != null || knowledge != null);

  /// Whether the assistant acts on the note ([agent]) instead of only answering. Nothing is done without asking.
  bool get acting => _acting && agent != null;
  bool _acting;
  set acting(bool on) {
    if (on == _acting) return;
    _acting = on;
    onActingChanged?.call(on);
    notifyListeners();
  }

  /// Told when the person switches between answering and acting, to keep the choice for the next note.
  final void Function(bool acting)? onActingChanged;

  /// Takes the flashcards that were kept from before, if there are any.
  Future<void> restoreCards() async {
    try {
      final json = await loadCards?.call();
      if (json == null || deck != null || _disposed) return;
      final cards = [
        for (final m in (jsonDecode(json) as List).whereType<Map>())
          Flashcard(m['q'] as String, m['a'] as String, page: (m['p'] as num?)?.toInt()),
      ];
      if (cards.isNotEmpty) {
        deck = FlashcardDeck(cards);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('reading the kept flashcards failed: $e');
    }
  }

  static String encodeFlashcards(List<Flashcard> cards) =>
      jsonEncode([for (final c in cards) {'q': c.front, 'a': c.back, if (c.page != null) 'p': c.page}]);

  final List<ChatMessage> messages = [];
  bool _busy = false;
  bool get busy => _busy;

  /// What the assistant is doing, for the person: reading the document, writing.
  String status = '';
  AiCancel? _cancel;
  bool _disposed = false;

  /// How many earlier messages are given along, and how long each may be.
  static const _historyMessages = 6;
  static const _historyLength = 700;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void stop() {
    _cancel?.cancel();
    _deny();
  }

  /// What was allowed for the whole conversation.
  final Set<ExtensionPermission> _allowed = {};

  /// Where the answer of the person to the question that is open goes.
  Completer<AgentChoice>? _choice;

  void _deny() => decide(AgentChoice.deny);

  /// The person's answer to the question that is open.
  void decide(AgentChoice choice) {
    final open = _choice;
    if (open == null || open.isCompleted) return;
    open.complete(choice);
  }

  void clear() {
    stop();
    _allowed.clear();
    messages.clear();
    notifyListeners();
  }

  /// Whether the flashcards show instead of the conversation.
  bool cardMode = false;

  /// The cards made from the document, being studied; null before any were made.
  FlashcardDeck? deck;

  /// Why the last try at making cards failed.
  String? cardError;

  void openFlashcards([bool open = true]) {
    cardMode = open;
    notifyListeners();
  }

  /// Drops the cards, back to the start of the flashcards.
  void discardCards() {
    deck?.dispose();
    deck = null;
    cardError = null;
    dropCards?.call();
    notifyListeners();
  }

  /// Makes about [count] flashcards from the whole document (an even spread of it when it is long).
  Future<void> makeFlashcards(int count) async {
    if (_busy) return;
    _busy = true;
    cardError = null;
    status = tr('Reading the document...');
    final cancel = _cancel = AiCancel();
    notifyListeners();
    try {
      final doc = await index!();
      if (doc.isEmpty) throw StateError(tr('The document has no text to make flashcards from.'));
      final excerpts = doc.select('', ai.contextChars);
      status = tr('Writing flashcards...');
      notifyListeners();
      var written = '';
      final answer = await ai.flashcards(excerpts.text, count, cancel: cancel, onPartial: (partial) {
        written = partial;
        final n = parseFlashcards(partial).length;
        status = n == 0 ? tr('Writing flashcards...') : tr('Writing flashcards... ({n} so far)', {'n': n});
        notifyListeners();
      });
      final cards = parseFlashcards(answer.isEmpty ? written : answer);
      if (cards.isEmpty) {
        throw StateError(cancel.cancelled ? tr('(stopped)') : tr('The model did not make any flashcards. Try again.'));
      }
      deck?.dispose();
      final kept = cards.length > count ? cards.sublist(0, count) : cards;
      deck = FlashcardDeck(kept);
      saveCards?.call(encodeFlashcards(kept));
    } catch (e) {
      cardError = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      _busy = false;
      status = '';
      notifyListeners();
    }
  }

  Future<void> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    final history = _history();
    final previous = messages.where((m) => m.fromUser).lastOrNull?.text ?? '';
    messages.add(ChatMessage(true, q));
    final answer = ChatMessage(false, '');
    messages.add(answer);
    _busy = true;
    status = tr('Reading the document...');
    final cancel = _cancel = AiCancel();
    notifyListeners();
    try {
      final knowledge = this.knowledge;
      final agent = this.agent;
      if (acting && agent != null) {
        await _act(agent, q, previous, history, answer, cancel);
        return;
      }
      if (knowledge != null) {
        await _askNotes(knowledge, q, previous, history, answer, cancel);
        return;
      }
      final doc = await index!();
      // a follow-up ("and the second one?") says little: the question before it helps find the passages
      final query = q.split(RegExp(r'\s+')).length < 5 ? '$previous $q' : q;
      final used = history.fold<int>(0, (sum, t) => sum + t.text.length);
      final budget = (ai.contextChars - used).clamp(1500, 1 << 30);
      final excerpts = doc.select(query, budget);
      answer.pages = excerpts.pages;
      status = tr('Writing...');
      notifyListeners();
      final text = await ai.converse(
        excerpts.text.isEmpty ? '(The document has no text.)' : excerpts.text,
        q,
        history: history,
        cancel: cancel,
        onPartial: (partial) {
          answer.text = partial;
          notifyListeners();
        },
      );
      answer.text = text.isEmpty && cancel.cancelled ? answer.text : text;
      if (answer.text.trim().isEmpty) {
        answer.text = cancel.cancelled ? tr('(stopped)') : tr('The model gave no answer.');
        answer.failed = !cancel.cancelled;
      }
    } catch (e) {
      answer.text = '$e'.replaceFirst('Bad state: ', '');
      answer.failed = true;
      answer.pages = const [];
    } finally {
      _busy = false;
      status = '';
      notifyListeners();
    }
  }

  /// How many times the model is asked for one request, and how many calls of one answer are looked at. (A model that goes round in
  /// circles must come to an end, and each call of a good one takes a moment of the person's attention.)
  static const _agentRounds = 8;
  static const _agentCalls = 5;

  /// Works on [request]: the model answers, and as long as that answer has calls in it, they are done (with leave) and it is told what
  /// came of them. The answer that has no calls is what the person reads.
  Future<void> _act(NoteAgent agent, String request, String previous, List<AiTurn> history, ChatMessage answer, AiCancel cancel) async {
    final doc = await index!();
    final query = request.split(RegExp(r'\s+')).length < 5 ? '$previous $request' : request;
    final system = agentSystem(agent.tools);
    final used = history.fold<int>(0, (sum, t) => sum + t.text.length) + system.length;
    final excerpts = doc.select(query, (ai.contextChars - used).clamp(1000, 1 << 30));
    answer.pages = excerpts.pages;
    var user = agentRequest(excerpts.text, request, agent.selected?.call()?.trim());
    final turns = [...history];
    final done = <String>{};
    for (var round = 0; round < _agentRounds; round++) {
      status = tr('Thinking...');
      notifyListeners();
      final native = !_textCalls && ai.canCallTools;
      final String reply;
      final List<AiToolCall> sent;
      final List<AgentCall> calls;
      try {
        if (native) {
          // the service takes the tools with the request and answers with calls: nothing for the model to write as text
          final r = await ai.generateWithTools(
            AiPrompt(system: agentSystemNative(), user: user, history: turns, exact: true),
            [for (final t in agent.tools) t.spec],
            maxTokens: 1200,
            cancel: cancel,
            onPartial: (partial) {
              answer.text = partial;
              notifyListeners();
            },
          );
          reply = r.text;
          sent = r.calls;
          calls = [
            for (final c in r.calls) AgentCall(agent.tools.where((t) => t.wire == c.name).firstOrNull?.name ?? c.name, c.args, id: c.id, error: c.error),
          ];
        } else {
          reply = await ai.generate(
            AiPrompt(system: system, user: user, history: turns, exact: true),
            maxTokens: 1200,
            cancel: cancel,
            onPartial: (partial) {
              answer.text = visibleAnswer(partial);
              notifyListeners();
            },
          );
          sent = const [];
          calls = parseToolCalls(reply);
        }
      } on ToolsNotSupported catch (e) {
        // this model or server takes no tools: from now on the calls are written as text (only at the start, before any call was made)
        if (!native || round > 0) rethrow;
        debugPrint('no tools with the request, calls as text instead: $e');
        _textCalls = true;
        round--;
        continue;
      }
      if (cancel.cancelled) {
        answer.text = tr('(stopped)');
        return;
      }
      if (calls.isEmpty) {
        answer.text = reply.trim();
        if (answer.text.isEmpty) {
          answer.text = answer.steps.isEmpty ? tr('The model gave no answer.') : tr('Done.');
          answer.failed = answer.steps.isEmpty;
        }
        return;
      }
      answer.text = '';
      final results = <String>[];
      for (final (i, call) in calls.indexed) {
        results.add(i < _agentCalls ? await _call(agent, call, answer, done) : '${call.name}: not done, there were too many calls at once.');
        if (cancel.cancelled) {
          answer.text = tr('(stopped)');
          return;
        }
      }
      if (native) {
        // every call is answered, each under its own id
        if (user.isNotEmpty) turns.add(AiTurn(true, user));
        turns.add(AiTurn(false, reply, calls: sent));
        for (final (i, c) in sent.indexed) {
          turns.add(AiTurn(false, results[i], resultOf: c.id));
        }
        user = '';
      } else {
        turns
          ..add(AiTurn(true, user))
          ..add(AiTurn(false, reply));
        user = agentResults(results);
      }
    }
    answer.text = tr('The assistant stopped after {n} rounds without finishing.', {'n': _agentRounds});
  }

  /// Set once the service has refused tools: the rest of the conversation writes its calls as text.
  bool _textCalls = false;

  /// Does [call], if the person lets it happen. What comes back is for the model.
  Future<String> _call(NoteAgent agent, AgentCall call, ChatMessage answer, Set<String> done) async {
    // (a call that cannot be done is shown too, with why: the person should not have to guess what went wrong)
    String failed(String summary, String why) {
      answer.steps = [...answer.steps, AgentStep(null, AgentAction(summary), AgentStepState.failed)..result = why];
      notifyListeners();
      return 'Error: $why';
    }

    if (call.error != null) return failed(tr('A call that could not be read'), call.error!);
    final tool = agent.tools.where((t) => t.name == call.name).firstOrNull;
    if (tool == null) return failed(call.name, 'there is no tool "${call.name}". There are: ${agent.tools.map((t) => t.name).join(', ')}.');
    // (asking the person the same thing twice is no use: the model is going round in circles)
    final key = jsonEncode([call.name, call.args]);
    if (done.contains(key)) return '${call.name}: this was done already, do not do it again.';
    final AgentAction action;
    try {
      action = tool.describe(call.args);
    } on ExtensionError catch (e) {
      return failed(call.name, '${call.name}: ${e.message}');
    }
    final permission = tool.permissionFor(call.args);
    final ask = permission != null && !_allowed.contains(permission);
    // what it would change is tried on copies first: the person looks at that when asked, and a change that cannot be done is not asked about
    AgentPreview? preview;
    final previewer = tool.preview, copies = agent.copies;
    if (ask && previewer != null && copies != null) {
      final scratch = copies();
      try {
        preview = previewer(scratch, call.args);
      } on ExtensionError catch (e) {
        return failed(action.summary, '${call.name}: ${e.message}');
      } finally {
        for (final c in scratch) {
          c.dispose();
        }
      }
    }
    final step = AgentStep(tool, action, ask ? AgentStepState.asking : AgentStepState.running, permission)..preview = preview;
    answer.steps = [...answer.steps, step];
    if (ask) {
      final choice = await _ask(step);
      if (choice == AgentChoice.deny) {
        step.state = AgentStepState.refused;
        notifyListeners();
        return '${call.name}: the user did not allow this.';
      }
      if (choice == AgentChoice.always) _allowed.add(permission);
      step.state = AgentStepState.running;
    }
    status = action.summary;
    notifyListeners();
    try {
      // (the note as it is, kept first: whatever the assistant does can be gone back from)
      if (tool.changesNote) await agent.beforeChange?.call(action.summary);
      final result = await tool.run(agent.api, call.args);
      if (tool.changesNote) await agent.afterChange?.call(action.summary);
      step.state = AgentStepState.done;
      done.add(key);
      // (what is read may be longer than the model can take in)
      final room = ai.contextChars;
      return '${call.name}: ${result.length > room ? '${result.substring(0, room)}...' : result}';
    } catch (e) {
      step
        ..state = AgentStepState.failed
        ..result = '$e'.replaceFirst('Bad state: ', '');
      return 'Error in ${call.name}: ${step.result}';
    } finally {
      notifyListeners();
    }
  }

  /// Waits for what the person says about [step].
  Future<AgentChoice> _ask(AgentStep step) async {
    final choice = _choice = Completer<AgentChoice>();
    status = tr('Waiting for your answer...');
    notifyListeners();
    final said = await choice.future;
    _choice = null;
    return said;
  }

  Future<void> _askNotes(NoteKnowledge knowledge, String q, String previous, List<AiTurn> history, ChatMessage answer, AiCancel cancel) async {
    final query = q.split(RegExp(r'\s+')).length < 5 ? '$previous $q' : q;
    final used = history.fold<int>(0, (sum, t) => sum + t.text.length);
    final budget = (ai.contextChars - used).clamp(1500, 1 << 30);
    final found = await knowledge.retrieve(query, status: (s) {
      status = s;
      notifyListeners();
    });
    answer.sources = [
      for (final p in found.passages) ChatSource(p.noteId, p.title, p.page),
    ].fold<List<ChatSource>>([], (list, s) => list.any((o) => o.noteId == s.noteId && o.page == s.page) ? list : (list..add(s)));
    status = tr('Writing...');
    notifyListeners();
    final text = await ai.converseNotes(
      found.passages.isEmpty ? '(No note has anything about this.)' : found.render(budget),
      q,
      history: history,
      cancel: cancel,
      onPartial: (partial) {
        answer.text = partial;
        notifyListeners();
      },
    );
    answer.text = text.isEmpty && cancel.cancelled ? answer.text : text;
    if (answer.text.trim().isEmpty) {
      answer.text = cancel.cancelled ? tr('(stopped)') : tr('The model gave no answer.');
      answer.failed = !cancel.cancelled;
    }
  }

  /// The earlier questions with their answers; a question whose answer failed or was stopped is left out.
  List<AiTurn> _history() {
    final turns = <AiTurn>[];
    for (var i = 0; i + 1 < messages.length; i += 2) {
      final q = messages[i], a = messages[i + 1];
      if (a.failed || a.text.trim().isEmpty || a.text == '(stopped)') continue;
      // (for what follows, the assistant has to know what it changed)
      final did = a.steps.where((s) => s.state == AgentStepState.done).map((s) => s.action.summary).join('; ');
      final said = a.text.length > _historyLength ? '${a.text.substring(0, _historyLength)}...' : a.text;
      turns
        ..add(AiTurn(true, q.text))
        ..add(AiTurn(false, did.isEmpty ? said : '$said\n(Actions taken: $did)'));
    }
    return turns.length > _historyMessages ? turns.sublist(turns.length - _historyMessages) : turns;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    deck?.dispose();
    super.dispose();
  }
}

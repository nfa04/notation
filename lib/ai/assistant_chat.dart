import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'ai_prompt.dart';
import 'ai_service.dart';
import 'document_index.dart';
import 'note_agent.dart';
import 'note_knowledge.dart';
import 'note_lookup.dart';
import 'flashcards.dart';
import 'text_provider.dart';
import '../extensions/extension_host.dart';
import 'citations.dart';
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

  /// For a question: the notes it refers to with `@Title`.
  List<NoteRef> refs = const [];

  /// The answer stopped at the most it could write: the rest can be asked for ([AssistantChat.continueAnswer]).
  bool cutOff = false;

  /// What the model was given to answer from (the note, the passages), for the person to look at.
  String given = '';

  /// The prompt this answer was written to (to ask for the rest of it).
  AiPrompt? prompt;

  /// The passages the model was given, as they were marked: what its citations can name.
  List<KnownMark> known = const [];

  AnswerCheck? _check;
  String? _checked;

  /// Which of those the answer names, and whether they say what it says (see [checkAnswer]); null until the answer is there.
  AnswerCheck? get check {
    if (fromUser || failed || known.isEmpty || text.isEmpty) return null;
    final key = '${text.length}:${given.length}:${known.length}:${text.hashCode}';
    if (_checked != key) {
      _checked = key;
      _check = checkAnswer(text, given, known);
    }
    return _check;
  }

  ChatMessage(this.fromUser, this.text, {this.pages = const [], this.sources = const [], this.failed = false});
}

/// Where the person is in the note when they ask (the page they look at, what they selected): told to the model with the passages, so
/// that "this page" and "explain this" mean something.
class NoteContext {
  final String title;

  /// Zero-based, null when not known.
  final int? page;
  final int pageCount;
  final String? selected;
  const NoteContext({this.title = '', this.page, this.pageCount = 0, this.selected});
}

/// What was read for a question: the passages and what is said about them.
class _Read {
  final Excerpts excerpts;

  /// The places the passages are marked with.
  final List<KnownMark> marks;

  /// What the model is given: a few lines about the note and what of it this is, then the passages.
  final String text;
  const _Read(this.excerpts, this.text, this.marks);
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

  /// Where the person is in the note when they ask; null: nothing is told about that.
  final NoteContext Function()? whereAmI;

  /// Reads a text with the sentence model (null when there is none), and the vectors kept for the passages of the note from before.
  final Future<Float32List?> Function(String text)? embed;
  final Future<Map<String, Float32List>> Function()? keptVectors;

  /// What [embed] made of the passages of the note, by their text: read once for the conversation.
  final Map<String, Float32List> _vectors = {};
  bool _keptLoaded = false;

  /// How many passages are read with the sentence model at most for one question (the rest, by their words, until a later question).
  static const _embedPerQuestion = 32;

  /// Where the conversation is kept between openings of the note (on this device only: it is not part of the note, which may be
  /// shared); null: it is not kept. [saveChat] with null forgets it.
  final Future<String?> Function()? loadChat;
  final Future<void> Function(String? json)? saveChat;

  /// How many messages are kept.
  static const _keptMessages = 30;

  /// What the assistant may do without asking, in every conversation: the assistant of all notes reads all notes for every question
  /// anyway, so reading one more by its id is not asked about.
  final Set<ExtensionPermission> granted;

  /// Finds and reads the notes a question may refer to with `@`; null: no mentions.
  final NoteLookup? lookup;

  /// What the notes of the question being answered say (see [ask]); read for that question only.
  String _mention = '';

  /// Told after a tool changed something (a note was made or filed, a task added), so that what is on screen shows it.
  final void Function()? onChanged;

  AssistantChat({required this.ai, this.index, this.knowledge, this.loadCards, this.saveCards, this.dropCards, this.agent, bool acting = false, this.onActingChanged, this.whereAmI, this.embed, this.keptVectors, this.loadChat, this.saveChat, this.granted = const {}, this.onChanged, this.lookup})
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

  /// Takes the conversation that was kept from before, if there is one and nothing was asked yet.
  Future<void> restoreChat() async {
    try {
      final json = await loadChat?.call();
      if (json == null || messages.isNotEmpty || _disposed) return;
      for (final m in (jsonDecode(json) as List).whereType<Map>()) {
        messages.add(ChatMessage(m['u'] == true, '${m['t'] ?? ''}', pages: [for (final p in (m['p'] as List? ?? const [])) if (p is num) p.toInt()], failed: m['f'] == true));
      }
      // (a question without its answer cannot be gone on from)
      if (messages.isNotEmpty && messages.last.fromUser) messages.removeLast();
      notifyListeners();
    } catch (e) {
      debugPrint('reading the kept conversation failed: $e');
    }
  }

  void _keepChat() {
    final save = saveChat;
    if (save == null) return;
    final kept = messages.length > _keptMessages ? messages.sublist(messages.length - _keptMessages) : messages;
    // (from a question on, so that questions and answers stay in pairs)
    final from = kept.isNotEmpty && !kept.first.fromUser ? 1 : 0;
    save(kept.length <= from
        ? null
        : jsonEncode([
            for (final m in kept.skip(from)) {'u': m.fromUser, 't': m.text, if (m.pages.isNotEmpty) 'p': m.pages, if (m.failed) 'f': true},
          ]));
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
  static const _historyMessages = 10;
  static const _historyLength = 700;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void stop() {
    _cancel?.cancel();
    _deny();
  }

  /// What was allowed for the whole conversation (and [granted]).
  late final Set<ExtensionPermission> _allowed = {...granted};

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
    _allowed
      ..clear()
      ..addAll(granted);
    messages.clear();
    saveChat?.call(null);
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

  Future<void> ask(String question, {List<NoteRef> refs = const []}) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    final history = _history();
    final previous = messages.where((m) => m.fromUser).lastOrNull?.text ?? '';
    messages.add(ChatMessage(true, q)..refs = refs);
    final answer = ChatMessage(false, '');
    messages.add(answer);
    _busy = true;
    status = tr('Reading the document...');
    final cancel = _cancel = AiCancel();
    notifyListeners();
    try {
      _mention = await _mentions(refs);
      final knowledge = this.knowledge;
      final agent = this.agent;
      if (acting && agent != null) {
        await _act(agent, q, previous, history, answer, cancel);
        return;
      }
      // a model that takes tools and has room for what they give back may read more of the note than the passages it is given
      if (agent != null && ai.canCallTools && !_textCalls && ai.contextChars >= 20000) {
        await _act(agent, q, previous, history, answer, cancel, readOnly: true);
        return;
      }
      if (knowledge != null) {
        await _askNotes(knowledge, q, previous, history, answer, cancel);
        return;
      }
      final used = history.fold<int>(0, (sum, t) => sum + t.text.length);
      final budget = (ai.contextChars - used).clamp(1500, 1 << 30);
      final read = await _read(q, previous, budget);
      answer.pages = read.excerpts.pages;
      answer.given = read.text;
      answer.known = read.marks;
      status = tr('Writing...');
      notifyListeners();
      final prompt = answer.prompt = ai.conversePrompt(read.excerpts.text.isEmpty ? '${read.text}\n(The document has no text.)' : read.text, q, history: history);
      final text = await ai.generate(prompt, maxTokens: ai.answerTokens, cancel: cancel, onPartial: (partial) {
        answer.text = partial;
        notifyListeners();
      });
      answer.text = text.isEmpty && cancel.cancelled ? answer.text : text;
      answer.cutOff = cancel.cutOff && !cancel.cancelled;
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
      if (!_disposed) _keepChat();
      notifyListeners();
    }
  }

  /// How many times the model is asked for one request, and how many calls of one answer are looked at. (A model that goes round in
  /// circles must come to an end, and each call of a good one takes a moment of the person's attention.)
  static const _agentRounds = 8;
  static const _agentCalls = 5;

  /// The tools that read the open note itself, from what the assistant reads anyway ([index]): whole pages, and a search in it (with the
  /// sentence model when there is one). They need no asking.
  List<AgentTool> _noteTools() => [
        AgentTool(
          name: 'note.pages',
          usage: 'note.pages {"from", "to"?} : the whole text of pages "from" to "to" (numbers from 1) of the note: written text, text boxes, handwriting and PDF text, each under its page.',
          parameters: {
            'type': 'object',
            'properties': {
              'from': {'type': 'integer', 'description': 'The first page, from 1.'},
              'to': {'type': 'integer', 'description': 'The last page (the same as "from" by default).'},
            },
            'required': ['from'],
          },
          describe: (args) => AgentAction(tr('Read pages of the note')),
          run: (api, args) async {
            int? number(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}'.trim());
            final from = number(args['from'] ?? args['page']);
            if (from == null || from < 1) throw ExtensionError('"from" has to be a page number from 1.');
            final to = number(args['to']) ?? from;
            final doc = await index!();
            final pages = [for (var p = from - 1; p < math.min(to, from + 19); p++) p];
            final e = doc.select('', math.max(2000, ai.contextChars ~/ 2), focus: QuestionFocus(QuestionScope.pages, pages));
            final there = doc.pageCount;
            if (from > there) return 'The note has only $there pages.';
            return e.text.isEmpty ? 'Nothing is written on page${pages.length > 1 ? 's $from to $to' : ' $from'}.' : e.text;
          },
        ),
        AgentTool(
          name: 'note.find',
          usage: 'note.find {"query"} : the passages of this note that fit "query" best (words or what they mean), each under its page.',
          parameters: {
            'type': 'object',
            'properties': {'query': {'type': 'string', 'description': 'What to look for.'}},
            'required': ['query'],
          },
          describe: (args) => AgentAction(tr('Look for "{text}" in the note', {'text': '${args['query'] ?? ''}'})),
          run: (api, args) async {
            final query = '${args['query'] ?? args.values.firstOrNull ?? ''}'.trim();
            if (query.isEmpty) throw ExtensionError('"query" has to be text.');
            var doc = await index!();
            final embed = this.embed;
            final asked = embed == null ? null : await embed(query);
            if (asked != null) doc = doc.withVectors(await _vectorsOf(doc, query, embed!));
            final e = doc.select(query, math.max(1500, ai.contextChars ~/ 4), queryVector: asked);
            return e.pages.isEmpty && asked == null ? 'Nothing in the note has these words.' : e.text;
          },
        ),
      ];

  /// The tool that opens a group of [agentToolGroups]: what it answers is how to use the tools in it.
  AgentTool _moreTool(List<AgentTool> all, Set<String> open) => AgentTool(
        name: 'tools.more',
        usage: 'tools.more {"group"} : makes the tools of a group usable and says how to use them. Groups: ${agentToolGroups.keys.join(', ')}.',
        parameters: {
          'type': 'object',
          'properties': {'group': {'type': 'string', 'enum': agentToolGroups.keys.toList()}},
          'required': ['group'],
        },
        describe: (args) => AgentAction(tr('Look at more tools')),
        run: (api, args) async {
          final group = '${args['group'] ?? args.values.firstOrNull ?? ''}'.trim();
          final tools = agentToolGroups[group];
          if (tools == null) throw ExtensionError('There is no group "$group". There are: ${agentToolGroups.keys.join(', ')}.');
          open.add(group);
          return 'These tools can be used now:\n${[for (final t in all) if (tools.$2.contains(t.name)) '- ${t.usage}'].join('\n')}';
        },
      );

  /// Works on [request]: the model answers, and as long as that answer has calls in it, they are done (with leave) and it is told what
  /// came of them. The answer that has no calls is what the person reads. With [readOnly] (the Ask mode) it only answers, and may
  /// read more of the note on the way; nothing is asked of the person and nothing is changed.
  Future<void> _act(NoteAgent agent, String request, String previous, List<AiTurn> history, ChatMessage answer, AiCancel cancel, {bool readOnly = false}) async {
    // (the assistant of all notes has no open note: none of the tools that work inside one)
    final knowledge = this.knowledge;
    final allNotes = knowledge != null;
    final all = allNotes ? [for (final t in agent.tools) if (notesAgentTools.contains(t.name)) t] : [...agent.tools, if (index != null) ..._noteTools()];
    final names = {for (final t in all) t.name};
    String? groupOf(String name) => allNotes && notesAgentCore.contains(name) ? null : agentGroupOf(name);
    final open = <String>{};
    bool closed(String group) => !open.contains(group) && agentToolGroups[group]!.$2.any(names.contains);
    final more = _moreTool(all, open);
    // (only reading: the tools that need no more than what the assistant reads anyway)
    bool reads(AgentTool t) => !t.changesNote && (t.permission == null || t.permission == ExtensionPermission.noteRead || granted.contains(t.permission));
    List<AgentTool> usable() => readOnly
        ? [for (final t in all) if (reads(t) && groupOf(t.name) == null) t]
        : [for (final t in all) if (groupOf(t.name) == null || open.contains(groupOf(t.name))) t, if (agentToolGroups.keys.any(closed)) more];
    String moreText() => readOnly ? '' : agentMoreTools(open, only: names);
    final userSystem = ai.template(AiTask.assistant).system;
    String systemFor(bool native) => readOnly
        ? askSystem(allNotes ? notesAssistantSystem : userSystem, textTools: native ? null : usable(), allNotes: allNotes)
        : allNotes
            ? notesAgentSystem(tools: native ? null : usable(), more: moreText())
            : (native ? agentSystemNative(more: moreText()) : agentSystem(usable(), more: moreText()));

    final used = history.fold<int>(0, (sum, t) => sum + t.text.length) + systemFor(_textCalls || !ai.canCallTools).length;
    final budget = (ai.contextChars - used).clamp(1000, 1 << 30);
    final String user0;
    if (allNotes) {
      final given = await _readNotes(knowledge, request, previous, budget, answer);
      user0 = readOnly ? ai.converseNotesPrompt(given, request).user : notesAgentRequest(given, request);
      if (readOnly) answer.prompt = ai.converseNotesPrompt(given, request, history: history);
    } else {
      final read = await _read(request, previous, budget);
      answer.pages = read.excerpts.pages;
      answer.given = read.text;
      answer.known = read.marks;
      // (what is selected is in what was read, when there is a [whereAmI] to say it)
      user0 = readOnly ? ai.conversePrompt(read.text, request).user : agentRequest(read.text, request, whereAmI == null ? agent.selected?.call()?.trim() : null);
      if (readOnly) answer.prompt = ai.conversePrompt(read.text, request, history: history);
    }
    var user = user0;
    final turns = [...history];
    final done = <String>{};
    for (var round = 0; round < _agentRounds; round++) {
      status = tr('Thinking...');
      notifyListeners();
      final native = !_textCalls && ai.canCallTools;
      // (a call of a tool that is not at hand is still known by its name: one of a group opens the group, one that would change the note
      // while answering is told why it cannot)
      final tools = [...usable(), for (final t in all) if (!usable().contains(t)) t];
      final String reply;
      final List<AiToolCall> sent;
      final List<AgentCall> calls;
      try {
        if (native) {
          // the service takes the tools with the request and answers with calls: nothing for the model to write as text
          final r = await ai.generateWithTools(
            AiPrompt(system: systemFor(true), user: user, history: turns, exact: true),
            [for (final t in usable()) t.spec],
            maxTokens: math.max(1200, ai.answerTokens),
            cancel: cancel,
            onPartial: (partial) {
              answer.text = partial;
              notifyListeners();
            },
          );
          reply = r.text;
          sent = r.calls;
          calls = [
            for (final c in r.calls) AgentCall(tools.where((t) => t.wire == c.name).firstOrNull?.name ?? c.name, c.args, id: c.id, error: c.error),
          ];
        } else {
          reply = await ai.generate(
            AiPrompt(system: systemFor(false), user: user, history: turns, exact: true),
            maxTokens: math.max(1200, ai.answerTokens),
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
        // (the rest is asked for from the passages and the question; what the tools read on the way is not given again)
        if (readOnly) answer.cutOff = cancel.cutOff;
        if (answer.text.isEmpty) {
          answer.text = answer.steps.isEmpty ? tr('The model gave no answer.') : tr('Done.');
          answer.failed = answer.steps.isEmpty;
        }
        return;
      }
      answer.text = '';
      final results = <String>[];
      for (final (i, call) in calls.indexed) {
        results.add(i < _agentCalls ? await _call(agent, tools, call, answer, done, readOnly: readOnly, open: open, groupOf: groupOf) : '${call.name}: not done, there were too many calls at once.');
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
        user = readOnly ? 'Results:\n${results.join('\n')}\n\nRead more if you need to, otherwise answer the question.' : agentResults(results);
      }
    }
    answer.text = tr('The assistant stopped after {n} rounds without finishing.', {'n': _agentRounds});
  }

  /// Set once the service has refused tools: the rest of the conversation writes its calls as text.
  bool _textCalls = false;

  /// Does [call], if the person lets it happen. What comes back is for the model.
  Future<String> _call(NoteAgent agent, List<AgentTool> tools, AgentCall call, ChatMessage answer, Set<String> done, {bool readOnly = false, Set<String>? open, String? Function(String name)? groupOf}) async {
    // (a call that cannot be done is shown too, with why: the person should not have to guess what went wrong)
    String failed(String summary, String why) {
      answer.steps = [...answer.steps, AgentStep(null, AgentAction(summary), AgentStepState.failed)..result = why];
      notifyListeners();
      return 'Error: $why';
    }

    if (call.error != null) return failed(tr('A call that could not be read'), call.error!);
    final tool = tools.where((t) => t.name == call.name).firstOrNull;
    if (tool == null) return failed(call.name, 'there is no tool "${call.name}". There are: ${tools.map((t) => t.name).join(', ')}.');
    // (a tool of a group that was not opened, called by its name: it is meant, and the group is open from now on)
    final group = (groupOf ?? agentGroupOf)(tool.name);
    if (group != null) open?.add(group);
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
    if (readOnly && (tool.changesNote || (permission != null && permission != ExtensionPermission.noteRead && !granted.contains(permission)))) {
      return failed(action.summary, '${call.name}: only reading is possible when answering a question. Answer from what you read.');
    }
    final ask = permission != null && !_allowed.contains(permission) && !(readOnly && permission == ExtensionPermission.noteRead);
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
      // (something that needed leave changed something: the lists on screen are to show it)
      if (permission != null && !(readOnly || permission == ExtensionPermission.noteRead || permission == ExtensionPermission.notesReadAll)) onChanged?.call();
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

  /// Finds what the notes say about [q] (with the [previous] question, for a follow-up that says little) in [budget] characters: the
  /// passages, marked with their notes, after the date of today. [answer] gets the notes they come from.
  Future<String> _readNotes(NoteKnowledge knowledge, String q, String previous, int budget, ChatMessage answer) async {
    final query = q.split(RegExp(r'\s+')).length < 5 ? '$previous $q' : q;
    // (the more room the model has, the more passages it is given: a cloud model reads many notes, one on the device a few)
    final passages = ((budget - _mention.length) ~/ 800).clamp(8, 40);
    final found = await knowledge.retrieve(query, notes: (passages ~/ 3).clamp(4, 12), passages: passages, status: (s) {
      status = s;
      notifyListeners();
    });
    answer.sources = [
      for (final p in found.passages) ChatSource(p.noteId, p.title, p.page),
    ].fold<List<ChatSource>>([], (list, s) => list.any((o) => o.noteId == s.noteId && o.page == s.page) ? list : (list..add(s)));
    // (each note with its id, so that the model can read the rest of one, or file it)
    final seenMarks = <String>{};
    answer.known = [
      for (final p in found.passages)
        if (seenMarks.add('${p.noteId}|${p.label}')) KnownMark('${p.title} - ${p.label}', title: p.title, page: p.page, noteId: p.noteId),
    ];
    final ids = {for (final p in found.passages) p.title: p.noteId};
    final notes = ids.isEmpty ? '' : '\n\nThe notes, with their ids: ${ids.entries.map((e) => '"${e.key}" (id ${e.value})').join('; ')}.';
    final mention = _mention.isEmpty ? '' : '\n\n$_mention';
    return answer.given = '${_today()}$notes$mention\n\n${found.passages.isEmpty ? '(No note has anything about this.)' : found.render((budget - _mention.length).clamp(800, 1 << 30))}';
  }

  Future<void> _askNotes(NoteKnowledge knowledge, String q, String previous, List<AiTurn> history, ChatMessage answer, AiCancel cancel) async {
    final used = history.fold<int>(0, (sum, t) => sum + t.text.length);
    final budget = (ai.contextChars - used).clamp(1500, 1 << 30);
    final given = await _readNotes(knowledge, q, previous, budget, answer);
    status = tr('Writing...');
    notifyListeners();
    final prompt = answer.prompt = ai.converseNotesPrompt(given, q, history: history);
    final text = await ai.generate(prompt, maxTokens: ai.answerTokens, cancel: cancel, onPartial: (partial) {
      answer.text = partial;
      notifyListeners();
    });
    answer.text = text.isEmpty && cancel.cancelled ? answer.text : text;
    answer.cutOff = cancel.cutOff && !cancel.cancelled;
    if (answer.text.trim().isEmpty) {
      answer.text = cancel.cancelled ? tr('(stopped)') : tr('The model gave no answer.');
      answer.failed = !cancel.cancelled;
    }
  }

  /// The earlier questions with their answers (of the first [upTo] messages), newest last; a question whose answer failed or was
  /// stopped is left out. The newest answers are given whole as far as a quarter of the room of the model allows ("the second point
  /// of your list" must find it), older ones shortened; at most [_historyMessages] turns.
  List<AiTurn> _history([int? upTo]) {
    final end = upTo ?? messages.length;
    final pairs = <(String, String)>[];
    for (var i = 0; i + 1 < end; i += 2) {
      final q = messages[i], a = messages[i + 1];
      if (a.failed || a.text.trim().isEmpty || a.text == '(stopped)') continue;
      // (for what follows, the assistant has to know what it changed)
      final did = a.steps.where((s) => s.state == AgentStepState.done).map((s) => s.action.summary).join('; ');
      pairs.add((q.text, did.isEmpty ? a.text : '${a.text}\n(Actions taken: $did)'));
    }
    var room = ai.contextChars ~/ 4;
    final turns = <AiTurn>[];
    for (final (q, a) in pairs.reversed.take(_historyMessages ~/ 2)) {
      final long = math.max(_historyLength, math.min(a.length, room - q.length));
      final said = a.length > long ? '${a.substring(0, long)}...' : a;
      room -= q.length + said.length;
      turns.insertAll(0, [AiTurn(true, q), AiTurn(false, said)]);
    }
    return turns;
  }

  /// Asks for the rest of the last answer, which stopped at the most it could write: it is written on, in the same message.
  Future<void> continueAnswer() async {
    if (_busy || messages.length < 2) return;
    final answer = messages.last;
    final sent = answer.prompt;
    if (answer.fromUser || !answer.cutOff || sent == null) return;
    _busy = true;
    status = tr('Writing...');
    final cancel = _cancel = AiCancel();
    final before = answer.text;
    answer.cutOff = false;
    notifyListeners();
    try {
      final prompt = AiPrompt(
        system: sent.system,
        history: [...sent.history, AiTurn(true, sent.user), AiTurn(false, before)],
        user: 'Your answer was cut off. Go on exactly where it stopped, without repeating anything.',
      );
      final more = await ai.generate(prompt, maxTokens: ai.answerTokens, cancel: cancel, onPartial: (partial) {
        answer.text = _joined(before, partial);
        notifyListeners();
      });
      answer.text = _joined(before, more);
      answer.cutOff = cancel.cutOff && !cancel.cancelled;
      // (asked again from here, the whole of it is the answer)
      answer.prompt = AiPrompt(system: sent.system, history: sent.history, user: sent.user);
    } catch (e) {
      answer.text = before;
      answer.cutOff = true;
      debugPrint('the rest of the answer could not be written: $e');
    } finally {
      _busy = false;
      status = '';
      if (!_disposed) _keepChat();
      notifyListeners();
    }
  }

  /// [before] and what came after it: a space between (the providers trim the answer, so the space the model wrote first is gone),
  /// unless one of them has the break already or the rest starts with punctuation.
  static String _joined(String before, String more) {
    final m = more.trimRight();
    if (m.isEmpty) return before;
    if (RegExp(r'\s$').hasMatch(before) || RegExp(r'^\s').hasMatch(m) || RegExp(r'^[.,;:!?)\]}]').hasMatch(m) || before.endsWith('-')) return '$before$m';
    return '$before $m';
  }

  /// Asks the last question again (the answer to it is dropped).
  Future<void> retry() async {
    if (_busy || messages.length < 2 || messages.last.fromUser) return;
    final question = messages[messages.length - 2];
    if (!question.fromUser) return;
    messages.removeRange(messages.length - 2, messages.length);
    await ask(question.text, refs: question.refs);
  }

  /// The date of today, for the model: "the latest", "this week" and "the exam next Monday" need it.
  static String _today() {
    final now = DateTime.now();
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return 'Today is ${days[now.weekday - 1]}, ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.';
  }

  /// The text of the notes a question refers to, each whole as far as it fits (together at most half of what the model can take in),
  /// with its id so that the model can use the tools on it.
  Future<String> _mentions(List<NoteRef> refs) async {
    final read = lookup?.read;
    if (read == null || refs.isEmpty) return '';
    final each = (ai.contextChars ~/ 2 ~/ refs.length).clamp(500, 1 << 30);
    final parts = <String>[];
    for (final r in refs) {
      try {
        final text = (await read(r.id, each + 1)).trim();
        parts.add('[${r.title} (id ${r.id})]\n${text.length > each ? '${text.substring(0, each)}...\n(The note goes on: read the rest with notes.read.)' : (text.isEmpty ? '(The note has no text.)' : text)}');
      } catch (e) {
        debugPrint('a mentioned note could not be read: $e');
      }
    }
    return parts.isEmpty ? '' : 'Notes the user refers to by name (read these first):\n\n${parts.join('\n\n')}';
  }

  /// Reads the note for [question] (with the [previous] question, for a follow-up that says little) in [budget] characters: the whole
  /// of it for a question about all of it, the pages it names, or the passages that fit; with the sentence model when there is one.
  Future<_Read> _read(String question, String previous, int budget) async {
    var doc = await index!();
    final where = whereAmI?.call();
    final pageCount = math.max(doc.pageCount, where?.pageCount ?? 0);
    final short = question.split(RegExp(r'\s+')).length < 5;
    final query = short ? '$previous $question' : question;
    var focus = focusOf(question, currentPage: where?.page, pageCount: pageCount);
    if (focus.scope == QuestionScope.passages && short && previous.isNotEmpty) focus = focusOf(previous, currentPage: where?.page, pageCount: pageCount);
    Float32List? asked;
    final embed = this.embed;
    if (embed != null && focus.scope != QuestionScope.whole && doc.totalChars > budget) {
      asked = await embed(query);
      if (asked != null) doc = doc.withVectors(await _vectorsOf(doc, query, embed));
    }
    final excerpts = doc.select(query, (budget - _mention.length).clamp(800, 1 << 30), focus: focus, queryVector: asked);
    final about = <String>[
      if (where != null && where.title.isNotEmpty) 'The note is called "${where.title}"${pageCount > 1 ? ' and has $pageCount pages' : ''}.'
      else if (pageCount > 1) 'The note has $pageCount pages.',
      if (where?.page != null && pageCount > 1) 'The user is looking at page ${where!.page! + 1}.',
      _today(),
      if (excerpts.complete)
        'You are given all of its text.'
      else if (focus.scope == QuestionScope.whole)
        'It is too long to give whole: you are given the telling sentences of every page, not every detail.'
      else if (focus.scope == QuestionScope.pages)
        'You are given ${focus.pages.length == 1 ? 'page ${focus.pages.first + 1}' : 'pages ${focus.pages.map((p) => p + 1).join(', ')}'} and passages chosen for the question; the other pages may say more.'
      else
        'You are given only the passages that fit the question best; the rest of the note may say more.',
    ];
    final selected = where?.selected?.trim() ?? '';
    final text = [
      about.join(' '),
      if (_mention.isNotEmpty) _mention,
      if (selected.isNotEmpty) 'Selected by the user:\n${selected.length > 3000 ? '${selected.substring(0, 3000)}...' : selected}',
      if (excerpts.text.isNotEmpty) excerpts.text,
    ].join('\n\n');
    final seen = <String>{};
    final marks = [
      for (final c in doc.chunks)
        if (seen.add(c.where)) KnownMark(c.where, page: c.page),
    ];
    return _Read(excerpts, text, marks);
  }

  /// The vector of each chunk of [doc] that is known: those kept from before, those read earlier in the conversation, and up to
  /// [_embedPerQuestion] more now (first those that share words with [query]).
  Future<List<Float32List?>> _vectorsOf(DocumentIndex doc, String query, Future<Float32List?> Function(String) embed) async {
    if (!_keptLoaded) {
      _keptLoaded = true;
      try {
        _vectors.addAll(await keptVectors?.call() ?? const {});
      } catch (e) {
        debugPrint('the kept vectors could not be read: $e');
      }
    }
    final terms = searchTerms(query).toSet();
    final missing = <String>{for (final c in doc.chunks) if (!_vectors.containsKey(c.text)) c.text}.toList()
      ..sort((a, b) => searchTerms(b).where(terms.contains).length.compareTo(searchTerms(a).where(terms.contains).length));
    if (missing.isNotEmpty) {
      status = tr('Reading the note...');
      notifyListeners();
    }
    for (final text in missing.take(_embedPerQuestion)) {
      final v = await embed(text);
      if (v == null) break;
      _vectors[text] = v;
    }
    return [for (final c in doc.chunks) _vectors[c.text]];
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    deck?.dispose();
    super.dispose();
  }
}

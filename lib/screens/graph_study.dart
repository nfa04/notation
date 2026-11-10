import 'package:flutter/material.dart' hide Text;

import '../ai/ai_prompt.dart';
import '../ai/flashcards.dart';
import '../data/card_repository.dart';
import '../ai/text_provider.dart';
import '../graph/graph_service.dart';
import '../graph/study.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'flashcard_view.dart';

/// Which study tool opens first.
enum StudyTool { cards, quiz, ask }

/// The study tools for the facts of a topic (or of the whole graph): flashcards, a quiz that grades the answers, and questions that
/// are answered from the facts alone.
Future<void> showGraphStudy(BuildContext context, {required GraphService service, required String title, required List<StudyFact> facts, StudyTool tool = StudyTool.cards, CardRepository? cards}) =>
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
          child: GraphStudy(service: service, title: title, facts: facts, initial: tool, cards: cards),
        ),
      ),
    );

class GraphStudy extends StatelessWidget {
  final GraphService service;
  final String title;
  final List<StudyFact> facts;
  final StudyTool initial;
  final CardRepository? cards;

  const GraphStudy({super.key, required this.service, required this.title, required this.facts, this.initial = StudyTool.cards, this.cards});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 3,
      initialIndex: initial.index,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
          child: Row(children: [
            Expanded(
              child: Text.verbatim(tr('Study: {topic}', {'topic': title}), style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Text.verbatim(trCount(facts.length, '{n} fact', '{n} facts'), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            IconButton(tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          ]),
        ),
        TabBar(tabs: [Tab(text: tr('Flashcards')), Tab(text: tr('Quiz')), Tab(text: tr('Ask'))]),
        Expanded(
          child: facts.isEmpty
              ? Center(child: Text('There are no facts here to study.'))
              : !service.canStudy
                  ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text.verbatim(tr('Studying needs an AI model: set one up in the Settings (on this device, or a service).'))))
                  : TabBarView(physics: const NeverScrollableScrollPhysics(), children: [
                      _CardsTab(service: service, facts: facts, cards: cards),
                      _QuizTab(service: service, facts: facts),
                      _AskTab(service: service, facts: facts),
                    ]),
        ),
      ]),
    );
  }
}

/// What the AI wrote, for the facts in batches: the answers of each batch, in order, without a card twice.
Future<List<Flashcard>> _writeCards(GraphService service, List<StudyFact> facts, int count, AiPrompt Function(List<StudyFact>, int) prompt, AiCancel cancel) async {
  final out = <Flashcard>[];
  final batches = <List<StudyFact>>[for (var i = 0; i < facts.length; i += studyBatch) facts.sublist(i, i + studyBatch > facts.length ? facts.length : i + studyBatch)];
  final per = (count / batches.length).ceil().clamp(1, 12);
  for (final b in batches) {
    if (cancel.cancelled || out.length >= count) break;
    final answer = await service.studyComplete(prompt(b, per), maxTokens: 140 * per + 150, cancel: cancel);
    for (final c in parseFlashcards(answer)) {
      if (!out.any((o) => o.front == c.front)) out.add(c);
    }
  }
  return out.take(count).toList();
}

class _CardsTab extends StatefulWidget {
  final GraphService service;
  final List<StudyFact> facts;
  final CardRepository? cards;
  const _CardsTab({required this.service, required this.facts, this.cards});

  @override
  State<_CardsTab> createState() => _CardsTabState();
}

class _CardsTabState extends State<_CardsTab> with AutomaticKeepAliveClientMixin {
  FlashcardDeck? _deck;
  bool _busy = false;
  String? _error;
  int _count = 10;
  AiCancel? _cancel;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _make() async {
    final cancel = _cancel = AiCancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cards = await _writeCards(widget.service, widget.facts, _count, cardsFromFactsPrompt, cancel);
      if (!mounted || cancel.cancelled) return;
      setState(() {
        _busy = false;
        if (cards.isEmpty) {
          _error = tr('The AI did not write any usable cards. Try again.');
        } else {
          _deck = FlashcardDeck(cards);
        }
      });
    } catch (e) {
      if (mounted && !cancel.cancelled) {
        setState(() {
          _busy = false;
          _error = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_busy) {
      return _Working(onStop: () {
        _cancel?.cancel();
        setState(() => _busy = false);
      });
    }
    final deck = _deck;
    if (deck != null) return DeckView(deck: deck, onNew: () => setState(() => _deck = null), onKeep: widget.cards == null ? null : (cards) => widget.cards!.addAll(CardRepository.graphSource, cards));
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('The AI writes cards from the facts: a short question on the front, the answer from the facts on the back.', style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 14),
      Wrap(spacing: 8, children: [
        for (final n in const [5, 10, 15, 20]) ChoiceChip(key: ValueKey('study-count-$n'), label: Text.verbatim('$n'), selected: _count == n, onSelected: (_) => setState(() => _count = n)),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text.verbatim(_error!, key: const ValueKey('study-error'), style: TextStyle(color: scheme.error))),
      const SizedBox(height: 14),
      Align(alignment: Alignment.centerLeft, child: FilledButton.icon(key: const ValueKey('study-cards-make'), onPressed: _make, icon: const Icon(Icons.auto_awesome, size: 18), label: const Text('Make flashcards'))),
    ]);
  }
}

class _Working extends StatelessWidget {
  final VoidCallback onStop;
  const _Working({required this.onStop});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator.adaptive(),
          const SizedBox(height: 14),
          Text('The AI is writing...', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          OutlinedButton(key: const ValueKey('study-stop'), onPressed: onStop, child: const Text('Stop')),
        ]),
      );
}

class _QuizTab extends StatefulWidget {
  final GraphService service;
  final List<StudyFact> facts;
  const _QuizTab({required this.service, required this.facts});

  @override
  State<_QuizTab> createState() => _QuizTabState();
}

class _QuizTabState extends State<_QuizTab> with AutomaticKeepAliveClientMixin {
  QuizSession? _quiz;
  bool _busy = false;
  String? _error;
  int _count = 8;
  AiCancel? _cancel;
  final _answer = TextEditingController();
  Grade? _grade;
  bool _grading = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _cancel?.cancel();
    _answer.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    final cancel = _cancel = AiCancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await _writeCards(widget.service, widget.facts, _count, quizPrompt, cancel);
      if (!mounted || cancel.cancelled) return;
      setState(() {
        _busy = false;
        if (made.isEmpty) {
          _error = tr('The AI did not write any usable questions. Try again.');
        } else {
          _quiz = QuizSession(made);
          _grade = null;
        }
      });
    } catch (e) {
      if (mounted && !cancel.cancelled) {
        setState(() {
          _busy = false;
          _error = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _submit() async {
    final quiz = _quiz, q = quiz?.current;
    if (quiz == null || q == null || _answer.text.trim().isEmpty) return;
    setState(() {
      _grading = true;
      _error = null;
    });
    try {
      Grade? g;
      for (var i = 0; i < 2 && g == null; i++) {
        g = parseGrade(await widget.service.studyComplete(gradePrompt(q.question, q.expected, _answer.text.trim()), maxTokens: 300));
      }
      if (!mounted) return;
      if (g == null) {
        setState(() {
          _grading = false;
          _error = tr('The AI did not give a grade. Try sending the answer again.');
        });
        return;
      }
      quiz.record(q, g);
      setState(() {
        _grading = false;
        _grade = g;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _grading = false;
          _error = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  void _next() {
    _quiz!.advance();
    _answer.clear();
    setState(() => _grade = null);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_busy) {
      return _Working(onStop: () {
        _cancel?.cancel();
        setState(() => _busy = false);
      });
    }
    final quiz = _quiz;
    if (quiz == null) {
      return ListView(padding: const EdgeInsets.all(20), children: [
        Text('The AI writes questions about the facts. You answer in your own words, the AI grades the answer, and questions you know less well come back first.', style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 14),
        Wrap(spacing: 8, children: [
          for (final n in const [5, 8, 12]) ChoiceChip(key: ValueKey('quiz-count-$n'), label: Text.verbatim('$n'), selected: _count == n, onSelected: (_) => setState(() => _count = n)),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text.verbatim(_error!, key: const ValueKey('study-error'), style: TextStyle(color: scheme.error))),
        const SizedBox(height: 14),
        Align(alignment: Alignment.centerLeft, child: FilledButton.icon(key: const ValueKey('quiz-make'), onPressed: _make, icon: const Icon(Icons.quiz_outlined, size: 18), label: const Text('Make a quiz'))),
      ]);
    }
    final q = quiz.current;
    final g = _grade;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        Expanded(child: LinearProgressIndicator(value: quiz.overall, key: const ValueKey('quiz-progress'))),
        const SizedBox(width: 12),
        Text.verbatim(tr('{done} of {total} mastered', {'done': quiz.masteredCount, 'total': quiz.questions.length}), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 16),
      if (q == null || (quiz.done && g == null)) ...[
        Icon(Icons.emoji_events_outlined, size: 40, color: scheme.primary),
        const SizedBox(height: 8),
        Text('You have mastered every question.', key: const ValueKey('quiz-done')),
      ] else ...[
        Text.verbatim(q.question, key: const ValueKey('quiz-question'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('quiz-answer'),
          controller: _answer,
          enabled: g == null && !_grading,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr('Your answer')),
        ),
        const SizedBox(height: 10),
        if (g == null)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(key: const ValueKey('quiz-send'), onPressed: _grading ? null : _submit, child: _grading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)) : const Text('Check my answer')),
          )
        else ...[
          Row(children: [
            Icon(g.correct ? Icons.check_circle : Icons.cancel_outlined, color: g.correct ? Colors.green : scheme.error),
            const SizedBox(width: 8),
            Text.verbatim(tr('Score {n} of 10', {'n': g.score}), key: const ValueKey('quiz-score'), style: Theme.of(context).textTheme.titleSmall),
          ]),
          if (g.feedback.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text.verbatim(g.feedback, key: const ValueKey('quiz-feedback'))),
          const SizedBox(height: 8),
          Text.verbatim('${tr('Expected answer')}: ${q.expected}', key: const ValueKey('quiz-expected'), style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: FilledButton(key: const ValueKey('quiz-next'), onPressed: _next, child: const Text('Next question'))),
        ],
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text.verbatim(_error!, key: const ValueKey('study-error'), style: TextStyle(color: scheme.error))),
      const SizedBox(height: 14),
      TextButton.icon(onPressed: () => setState(() => _quiz = null), icon: const Icon(Icons.refresh, size: 18), label: const Text('Make a new quiz')),
    ]);
  }
}

class _AskTab extends StatefulWidget {
  final GraphService service;
  final List<StudyFact> facts;
  const _AskTab({required this.service, required this.facts});

  @override
  State<_AskTab> createState() => _AskTabState();
}

class _AskTabState extends State<_AskTab> with AutomaticKeepAliveClientMixin {
  final _question = TextEditingController();
  String? _reply;
  String? _error;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final q = _question.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final facts = closestFacts(q, widget.facts);
      final answer = await widget.service.studyComplete(askFactsPrompt(q, facts.isEmpty ? widget.facts.take(studyBatch).toList() : facts), maxTokens: 700);
      if (mounted) {
        setState(() {
          _busy = false;
          _reply = answer.trim();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('Ask something about these facts. The answer rests on the facts alone; when they do not say, the AI tells you so.', style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('ask-question'),
        controller: _question,
        minLines: 1,
        maxLines: 4,
        onSubmitted: (_) => _ask(),
        decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr('Your question')),
      ),
      const SizedBox(height: 10),
      Align(alignment: Alignment.centerLeft, child: FilledButton(key: const ValueKey('ask-send'), onPressed: _busy ? null : _ask, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2)) : const Text('Ask'))),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text.verbatim(_error!, key: const ValueKey('study-error'), style: TextStyle(color: scheme.error))),
      if (_reply != null) Padding(padding: const EdgeInsets.only(top: 14), child: SelectableText(_reply!, key: const ValueKey('ask-reply'))),
    ]);
  }
}

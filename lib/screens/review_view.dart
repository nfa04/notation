import 'package:material_symbols_icons/symbols.dart';
import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import '../style/motion.dart';

import '../ai/spaced_repetition.dart';
import '../data/card_repository.dart';
import '../data/note_repository.dart';
import '../review/study_planner.dart';
import 'review_export.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// The button on the dashboard that opens the review of the cards that are due, with their number on it.
class ReviewButton extends StatefulWidget {
  final CardRepository cards;

  /// The plans for exams (a button in the review); null: not offered. [repository] gives the names of the notes the cards are from.
  final StudyPlanner? planner;
  final NoteRepository? repository;

  const ReviewButton({super.key, required this.cards, this.planner, this.repository});

  @override
  State<ReviewButton> createState() => _ReviewButtonState();
}

class _ReviewButtonState extends State<ReviewButton> {
  var _due = 0, _total = 0;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.cards.changes.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final due = await widget.cards.dueCount(), total = await widget.cards.count();
    if (mounted) {
      setState(() {
        _due = due;
        _total = total;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // nothing kept yet: nothing to review, so no button
    if (_total == 0) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('review-cards'),
      tooltip: _due == 0 ? tr('Review cards: none are due') : trCount(_due, 'Review cards: {n} is due', 'Review cards: {n} are due'),
      icon: Badge(
        isLabelVisible: _due > 0,
        label: Text.verbatim('$_due'),
        child: const Icon(Symbols.event_repeat),
      ),
      onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReviewScreen(cards: widget.cards, planner: widget.planner, repository: widget.repository))),
    );
  }
}

/// A round of review: the cards that are due, one at a time. After the answer is shown the person says how well it was
/// remembered, and the card comes back when its schedule says. A card answered "again" comes back in this round too.
class ReviewScreen extends StatefulWidget {
  final CardRepository cards;

  /// Reviews only the cards of this source (a note); null: all of them.
  final String? source;

  /// Reviews only the cards of these sources (a study plan's notes); null: as [source] says.
  final Set<String>? sources;

  /// Tells what time it is (tests move it); null: the clock.
  final DateTime Function()? clock;

  /// The plans for exams: a button in the bar opens them; null: not offered.
  final StudyPlanner? planner;
  final NoteRepository? repository;

  /// Opens a note at a page (from the study plans); null: the plans cannot open notes.
  final void Function(String noteId, int? page)? onOpenNoteAt;

  const ReviewScreen({super.key, required this.cards, this.source, this.sources, this.clock, this.planner, this.repository, this.onOpenNoteAt});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  DateTime _now() => (widget.clock ?? DateTime.now)();

  List<ReviewCard>? _queue;
  int _total = 0, _done = 0;
  bool _flipped = false;

  /// Counts every change of the card in front, and which way it went (1 forward, -1 back): the next one comes in from that side.
  int _turn = 0, _dir = 1;
  final _focus = FocusNode(debugLabel: 'review');
  final _answers = <Recall, int>{for (final r in Recall.values) r: 0};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources = widget.sources;
    final due = sources == null
        ? await widget.cards.due(now: _now(), source: widget.source)
        : [for (final s in sources) ...await widget.cards.due(now: _now(), source: s)];
    if (sources != null) {
      // as from one source: the longest due first, and in the order they were made where they are due at once
      final order = {for (final (i, c) in due.indexed) c.id: i};
      due.sort((a, b) {
        final byDue = a.schedule.due!.compareTo(b.schedule.due!);
        return byDue != 0 ? byDue : order[a.id]!.compareTo(order[b.id]!);
      });
    }
    if (!mounted) return;
    setState(() {
      _queue = [...due];
      _total = due.length;
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Space turns the card over and back, the arrows go to the next and the one before (without answering), 1-4 answer.
  KeyEventResult _key(FocusNode node, KeyEvent e) {
    final queue = _queue;
    if (e is! KeyDownEvent || queue == null || queue.isEmpty) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      setState(() => _flipped = !_flipped);
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowLeft) {
      if (queue.length < 2) return KeyEventResult.handled;
      final forward = key == LogicalKeyboardKey.arrowRight;
      setState(() {
        forward ? queue.add(queue.removeAt(0)) : queue.insert(0, queue.removeLast());
        _flipped = false;
        _turn++;
        _dir = forward ? 1 : -1;
      });
    } else {
      final keys = {
        LogicalKeyboardKey.digit1: 0, LogicalKeyboardKey.numpad1: 0,
        LogicalKeyboardKey.digit2: 1, LogicalKeyboardKey.numpad2: 1,
        LogicalKeyboardKey.digit3: 2, LogicalKeyboardKey.numpad3: 2,
        LogicalKeyboardKey.digit4: 3, LogicalKeyboardKey.numpad4: 3,
      };
      final i = keys[key];
      if (i == null) return KeyEventResult.ignored;
      // (a rating is only given once the answer has been seen)
      if (_flipped && i < Recall.values.length) _answer(Recall.values[i]);
    }
    return KeyEventResult.handled;
  }

  Future<void> _answer(Recall recall) async {
    final queue = _queue!, card = queue.first;
    final next = await widget.cards.review(card, recall, now: _now());
    if (!mounted) return;
    setState(() {
      queue.removeAt(0);
      _answers[recall] = _answers[recall]! + 1;
      if (recall == Recall.again) {
        // seen again before the round ends
        queue.add(ReviewCard(id: card.id, source: card.source, card: card.card, schedule: next));
        _total++;
      }
      _done++;
      _flipped = false;
      _turn++;
      _dir = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review cards'),
        actions: [
          IconButton(
            key: const ValueKey('import-anki'),
            tooltip: tr('Import from Anki'),
            icon: const Icon(Symbols.file_download),
            onPressed: () async {
              if (await importCardsFromAnki(context, widget.cards) != null && mounted) _load();
            },
          ),
          IconButton(
            key: const ValueKey('export-anki'),
            tooltip: tr('Export to Anki'),
            icon: const Icon(Symbols.ios_share),
            onPressed: () => exportCardsToAnki(context, widget.cards, repository: widget.repository, source: widget.source),
          ),
        ],
      ),
      body: SafeArea(
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          child: queue == null
            ? const Center(child: CircularProgressIndicator.adaptive())
            : queue.isEmpty
                ? _finished(context)
                : _card(context, queue.first),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, ReviewCard review) {
    final scheme = Theme.of(context).colorScheme;
    final card = review.card;
    final now = _now();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text.verbatim(tr('{n} left', {'n': _queue!.length}), key: const ValueKey('review-left'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(tween: Tween(end: _total == 0 ? 0 : _done / _total), duration: Motion.of(context, Motion.medium), curve: Motion.curveIn, builder: (context, v, _) => LinearProgressIndicator(value: v)),
        const SizedBox(height: 12),
        Expanded(
          child: GestureDetector(
            onTap: () {
              _focus.requestFocus();
              setState(() => _flipped = !_flipped);
            },
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.medium),
              switchInCurve: Motion.curveIn,
              switchOutCurve: Motion.curveOut,
              transitionBuilder: (child, animation) {
                final arriving = child.key == ValueKey(_turn);
                final side = (arriving ? 0.12 : -0.12) * _dir;
                return FadeTransition(opacity: animation, child: SlideTransition(position: Tween(begin: Offset(side, 0), end: Offset.zero).animate(animation), child: child));
              },
              child: FlipCard(
                key: ValueKey(_turn),
                front: !_flipped,
                face: (front) => Container(
                  key: ValueKey('review-card-$_done-${!front}'),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: front ? scheme.primaryContainer : scheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(front ? 'Question' : 'Answer', style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: scheme.onSurfaceVariant)),
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text.verbatim(card.front, key: const ValueKey('review-front'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20)),
                            if (!front) ...[
                              const Divider(height: 32),
                              Text.verbatim(card.back, key: const ValueKey('review-back'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20)),
                            ],
                          ]),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (!_flipped)
          FilledButton(key: const ValueKey('review-show'), onPressed: () => setState(() => _flipped = true), child: const Text('Show the answer'))
        else
          Row(children: [
            for (final r in Recall.values) ...[
              if (r != Recall.again) const SizedBox(width: 8),
              Expanded(
                child: (r == Recall.good ? FilledButton.new : OutlinedButton.new)(
                  key: ValueKey('review-${r.name}'),
                  onPressed: () => _answer(r),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(r.label),
                    Text.verbatim(review.schedule.previewLabel(r, now), style: const TextStyle(fontSize: 11)),
                  ]),
                ),
              ),
            ],
          ]),
      ]),
    );
  }

  Widget _finished(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Icon(Symbols.task_alt, size: 28, color: scheme.onSurfaceVariant),
      const SizedBox(height: 12),
      Text(_done == 0 ? 'No cards are due.' : 'All done for now.', key: const ValueKey('review-done'), style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      if (_done > 0)
        Text.verbatim(
          tr('{n} reviewed: {again} again, {hard} hard, {good} good, {easy} easy', {
            'n': _done,
            'again': _answers[Recall.again]!,
            'hard': _answers[Recall.hard]!,
            'good': _answers[Recall.good]!,
            'easy': _answers[Recall.easy]!,
          }),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      const SizedBox(height: 16),
      Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))),
    ]);
  }
}

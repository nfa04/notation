import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../ai/spaced_repetition.dart';
import '../data/card_repository.dart';
import '../data/note_repository.dart';
import '../review/study_planner.dart';
import 'review_export.dart';
import 'study_plan_screen.dart';
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
        child: const Icon(Icons.event_repeat),
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

  /// Tells what time it is (tests move it); null: the clock.
  final DateTime Function()? clock;

  /// The plans for exams: a button in the bar opens them; null: not offered.
  final StudyPlanner? planner;
  final NoteRepository? repository;

  const ReviewScreen({super.key, required this.cards, this.source, this.clock, this.planner, this.repository});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  DateTime _now() => (widget.clock ?? DateTime.now)();

  List<ReviewCard>? _queue;
  int _total = 0, _done = 0;
  bool _flipped = false;
  final _answers = <Recall, int>{for (final r in Recall.values) r: 0};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final due = await widget.cards.due(now: _now(), source: widget.source);
    if (!mounted) return;
    setState(() {
      _queue = [...due];
      _total = due.length;
    });
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
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () async {
              if (await importCardsFromAnki(context, widget.cards) != null && mounted) _load();
            },
          ),
          IconButton(
            key: const ValueKey('export-anki'),
            tooltip: tr('Export to Anki'),
            icon: const Icon(Icons.ios_share_outlined),
            onPressed: () => exportCardsToAnki(context, widget.cards, repository: widget.repository, source: widget.source),
          ),
          if (widget.planner != null && widget.repository != null)
            IconButton(
              key: const ValueKey('study-plans'),
              tooltip: tr('Plan for an exam'),
              icon: const Icon(Icons.event_available_outlined),
              onPressed: () {
                final planner = widget.planner!, repository = widget.repository!, clock = widget.clock;
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudyPlanScreen(planner: planner, repository: repository, clock: clock)));
              },
            ),
        ],
      ),
      body: SafeArea(
        child: queue == null
            ? const Center(child: CircularProgressIndicator.adaptive())
            : queue.isEmpty
                ? _finished(context)
                : _card(context, queue.first),
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
        LinearProgressIndicator(value: _total == 0 ? 0 : _done / _total),
        const SizedBox(height: 12),
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _flipped = true),
            child: Container(
              key: ValueKey('review-card-$_done-$_flipped'),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: _flipped ? scheme.tertiaryContainer : scheme.primaryContainer, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_flipped ? 'Answer' : 'Question', style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: scheme.onSurfaceVariant)),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text.verbatim(card.front, key: const ValueKey('review-front'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20)),
                        if (_flipped) ...[
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
      Icon(Icons.task_alt, size: 48, color: scheme.primary),
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

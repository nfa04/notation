import 'package:material_symbols_icons/symbols.dart';
import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'study_card.dart';

import '../ai/spaced_repetition.dart';
import '../data/card_repository.dart';
import '../data/note_repository.dart';
import '../review/study_planner.dart';
import 'review_export.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

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

  /// Counts every change of the card in front.
  int _turn = 0;
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

  /// The arrows go to the next card and the one before, without answering.
  void _move(int dir) {
    final queue = _queue!;
    if (_answering || queue.length < 2) return;
    setState(() {
      dir > 0 ? queue.add(queue.removeAt(0)) : queue.insert(0, queue.removeLast());
      _flipped = false;
      _turn++;
    });
  }

  bool _answering = false; // (a rating is being saved: the keys wait, so the queue is the one that was answered)

  Future<void> _answer(Recall recall) async {
    if (_answering) return;
    final queue = _queue!;
    if (queue.isEmpty) return;
    final card = queue.first;
    _answering = true;
    final CardSchedule next;
    try {
      next = await widget.cards.review(card, recall, now: _now());
    } catch (_) {
      _answering = false;
      rethrow;
    }
    _answering = false;
    if (!mounted) return;
    setState(() {
      queue.remove(card);
      _answers[recall] = _answers[recall]! + 1;
      if (recall == Recall.again) {
        // seen again before the round ends
        queue.add(ReviewCard(id: card.id, source: card.source, card: card.card, schedule: next));
        _total++;
      }
      _done++;
      _flipped = false;
      _turn++;
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
    final now = _now();
    return StudyCard(
      cardKey: _turn,
      front: review.card.front,
      back: review.card.back,
      flipped: _flipped,
      onFlip: () => setState(() => _flipped = !_flipped),
      onMove: _move,
      ratings: [
        for (final r in Recall.values)
          StudyRating(key: ValueKey('review-${r.name}'), label: r.label, hint: review.schedule.previewLabel(r, now), primary: r == Recall.good),
      ],
      onRate: (i) => _answer(Recall.values[i]),
      progress: _total == 0 ? 0 : _done / _total,
      autofocus: true,
      header: Align(
        alignment: Alignment.centerLeft,
        child: Text.verbatim(tr('{n} left', {'n': _queue!.length}), key: const ValueKey('review-left'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ),
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

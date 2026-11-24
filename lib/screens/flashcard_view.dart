import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../ai/assistant_chat.dart';
import '../ai/flashcards.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../markdown/markdown_table.dart';
import '../style/motion.dart';

/// The flashcards of the assistant: choose how many, wait while they are made, then turn them over one
/// by one and say whether they were known. Missed cards can be studied again, or all of them put on the note.
class FlashcardView extends StatefulWidget {
  final AssistantChat chat;

  /// Whether cards can be made now (a provider that is ready).
  final bool ready;

  /// Takes the reader to a page (zero-based) a card is from.
  final ValueChanged<int>? onJumpToPage;

  /// Puts text (the cards as a table) on the note.
  final ValueChanged<String>? onAddToNote;

  /// Keeps the cards for spaced repetition; null: not offered.
  final Future<int> Function(List<Flashcard> cards)? onKeep;

  const FlashcardView({super.key, required this.chat, required this.ready, this.onJumpToPage, this.onAddToNote, this.onKeep});

  @override
  State<FlashcardView> createState() => _FlashcardViewState();
}

class _FlashcardViewState extends State<FlashcardView> {
  static const _counts = [5, 10, 15, 20];
  int _count = 10;

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    if (chat.busy) return _making(context, chat);
    final deck = chat.deck;
    if (deck == null) return _setup(context, chat);
    return DeckView(deck: deck, onNew: chat.discardCards, onJumpToPage: widget.onJumpToPage, onAddToNote: widget.onAddToNote, onKeep: widget.onKeep);
  }

  Widget _setup(BuildContext context, AssistantChat chat) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Icon(Symbols.style, size: 28, color: scheme.onSurfaceVariant),
      const SizedBox(height: 12),
      Text('Flashcards from this document', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text('The assistant reads the document and writes questions with answers to practise with. You turn each card over and say whether you knew it.',
          style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 16),
      Text('How many cards?', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        for (final n in _counts)
          ChoiceChip(
            key: ValueKey('flashcards-count-$n'),
            label: Text.verbatim('$n'),
            selected: _count == n,
            onSelected: (_) => setState(() => _count = n),
          ),
      ]),
      if (chat.cardError != null) ...[
        const SizedBox(height: 12),
        Text.verbatim(chat.cardError!, key: const ValueKey('flashcards-error'), style: TextStyle(color: scheme.error)),
      ],
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          key: const ValueKey('flashcards-make'),
          icon: const Icon(Symbols.auto_awesome, size: 18),
          label: const Text('Make flashcards'),
          onPressed: widget.ready ? () => chat.makeFlashcards(_count) : null,
        ),
      ),
    ]);
  }

  Widget _making(BuildContext context, AssistantChat chat) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator.adaptive(),
          const SizedBox(height: 16),
          Text.verbatim(chat.status, key: const ValueKey('flashcards-status'), style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          OutlinedButton(key: const ValueKey('flashcards-stop'), onPressed: chat.stop, child: const Text('Stop')),
        ]),
      ),
    );
  }
}

/// A deck being studied: the card, the buttons to say whether it was known, and the result of a round. Shared by the assistant
/// and the graph view.
class DeckView extends StatelessWidget {
  final FlashcardDeck deck;

  /// Asked for when the person wants new cards.
  final VoidCallback onNew;
  final ValueChanged<int>? onJumpToPage;
  final ValueChanged<String>? onAddToNote;

  /// Keeps the cards for spaced repetition (they come back on the days they are due); null: not offered.
  final Future<int> Function(List<Flashcard> cards)? onKeep;

  const DeckView({super.key, required this.deck, required this.onNew, this.onJumpToPage, this.onAddToNote, this.onKeep});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: deck, builder: (context, _) => deck.finished ? _finished(context) : _study(context));

  Widget _study(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = deck.current!;
    final front = !deck.flipped;
    final page = card.page;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text.verbatim(tr('Card {n} of {total}', {'n': deck.position + 1, 'total': deck.roundLength}),
              key: const ValueKey('flashcards-progress'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const Spacer(),
          if (onKeep != null) _KeepButton(cards: deck.cards, onKeep: onKeep!, compact: true),
          IconButton(
            key: const ValueKey('flashcards-shuffle'),
            tooltip: tr('Shuffle and start over'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.shuffle, size: 20),
            onPressed: () => deck.startOver(shuffle: true),
          ),
          IconButton(
            key: const ValueKey('flashcards-new'),
            tooltip: tr('Make new flashcards'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.refresh, size: 20),
            onPressed: onNew,
          ),
        ]),
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(
          tween: Tween(end: deck.position / deck.roundLength),
          duration: Motion.of(context, Motion.medium),
          curve: Motion.curveIn,
          builder: (context, v, _) => LinearProgressIndicator(value: v),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: GestureDetector(
            key: const ValueKey('flashcard'),
            onTap: deck.flip,
            // the next card comes in from the right while the one before leaves to the left; turning the same card over is the flip inside
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.medium),
              switchInCurve: Motion.curveIn,
              switchOutCurve: Motion.curveOut,
              transitionBuilder: (child, animation) {
                final arriving = child.key == ValueKey(deck.position);
                return FadeTransition(opacity: animation, child: SlideTransition(position: Tween(begin: Offset(arriving ? 0.12 : -0.12, 0), end: Offset.zero).animate(animation), child: child));
              },
              child: FlipCard(
                key: ValueKey(deck.position),
                front: front,
                face: (front) => Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: front ? scheme.primaryContainer : scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(front ? 'Question' : 'Answer',
                      style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: (front ? scheme.onPrimaryContainer : scheme.onTertiaryContainer).withValues(alpha: 0.7))),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: Text.verbatim(
                          front ? card.front : card.back,
                          key: ValueKey(front ? 'flashcard-front' : 'flashcard-back'),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 20, color: front ? scheme.onPrimaryContainer : scheme.onTertiaryContainer),
                        ),
                      ),
                    ),
                  ),
                  Row(children: [
                    if (page != null && onJumpToPage != null)
                      ActionChip(
                        key: const ValueKey('flashcard-page'),
                        label: Text.verbatim(tr('Page {n}', {'n': page + 1})),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onJumpToPage!(page),
                      ),
                    const Spacer(),
                    if (front) Text('Tap to see the answer', style: TextStyle(fontSize: 12, color: scheme.onPrimaryContainer.withValues(alpha: 0.7))),
                  ]),
                ]),
              ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (front)
          FilledButton(key: const ValueKey('flashcard-flip'), onPressed: deck.flip, child: const Text('Show the answer'))
        else
          Row(children: [
            Expanded(child: OutlinedButton(key: const ValueKey('flashcard-again'), onPressed: deck.again, child: const Text('Again'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(key: const ValueKey('flashcard-got'), onPressed: deck.gotIt, child: const Text('Got it'))),
          ]),
      ]),
    );
  }

  Widget _finished(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final missed = deck.missed.length;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Icon(missed == 0 ? Symbols.emoji_events : Symbols.check_circle_outline, size: 28, color: scheme.onSurfaceVariant),
      const SizedBox(height: 12),
      Text.verbatim(tr('{known} of {total} known', {'known': deck.knownCount, 'total': deck.roundLength}),
          key: const ValueKey('flashcards-result'), style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(missed == 0 ? 'You knew every card.' : 'The ones you missed can be practised again.', style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 16),
      if (missed > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: FilledButton.icon(
            key: const ValueKey('flashcards-missed'),
            icon: const Icon(Symbols.replay, size: 18),
            label: Text.verbatim(trCount(missed, 'Practise the missed card', 'Practise the {n} missed cards')),
            onPressed: deck.studyMissed,
          ),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: const ValueKey('flashcards-restart'),
          icon: const Icon(Symbols.shuffle, size: 18),
          label: const Text('Shuffle and start over'),
          onPressed: () => deck.startOver(shuffle: true),
        ),
        if (onAddToNote != null)
          OutlinedButton.icon(
            key: const ValueKey('flashcards-add'),
            icon: const Icon(Symbols.table_chart, size: 18),
            label: const Text('Add the cards to the note'),
            onPressed: () => onAddToNote!(cardsAsTable(deck.cards)),
          ),
        if (onKeep != null) _KeepButton(cards: deck.cards, onKeep: onKeep!),
        OutlinedButton.icon(
          key: const ValueKey('flashcards-copy'),
          icon: const Icon(Symbols.content_copy, size: 18),
          label: const Text('Copy'),
          onPressed: () => Clipboard.setData(ClipboardData(text: cardsAsText(deck.cards))),
        ),
        TextButton.icon(
          key: const ValueKey('flashcards-new'),
          icon: const Icon(Symbols.refresh, size: 18),
          label: const Text('Make new flashcards'),
          onPressed: onNew,
        ),
      ]),
    ]);
  }
}

/// The cards as a two-column table (question, answer), in the table form notes use.
String cardsAsTable(List<Flashcard> cards) => tableText([
      [tr('Question'), tr('Answer')],
      for (final c in cards) [c.front, c.back],
    ]);

/// The cards as plain text, a blank line between them.
String cardsAsText(List<Flashcard> cards) => cards.map((c) => 'Q: ${c.front}\nA: ${c.back}').join('\n\n');

/// "Keep for review": puts the cards in the spaced-repetition store and says how many were new.
class _KeepButton extends StatefulWidget {
  final List<Flashcard> cards;
  final Future<int> Function(List<Flashcard> cards) onKeep;
  final bool compact;

  const _KeepButton({required this.cards, required this.onKeep, this.compact = false});

  @override
  State<_KeepButton> createState() => _KeepButtonState();
}

class _KeepButtonState extends State<_KeepButton> {
  bool _kept = false;

  Future<void> _keep() async {
    final added = await widget.onKeep(widget.cards);
    if (!mounted) return;
    setState(() => _kept = true);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text.verbatim(added == 0 ? tr('These cards are kept for review already.') : trCount(added, '{n} card kept for review', '{n} cards kept for review')),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.compact
      ? IconButton(
          key: const ValueKey('flashcards-keep-icon'),
          tooltip: tr('Keep for review'),
          visualDensity: VisualDensity.compact,
          icon: Icon(_kept ? Symbols.event_available : Symbols.event_repeat, size: 20),
          onPressed: _kept ? null : _keep,
        )
      : OutlinedButton.icon(
          key: const ValueKey('flashcards-keep'),
          icon: Icon(_kept ? Symbols.event_available : Symbols.event_repeat, size: 18),
          label: const Text('Keep for review'),
          onPressed: _kept ? null : _keep,
        );
}


/// A card that turns over when [front] changes: it rotates about its vertical middle, and the other face is put in at the edge-on
/// moment, so the turn goes on in the same direction instead of mirroring. [face] builds one side.
class FlipCard extends StatefulWidget {
  final bool front;
  final Widget Function(bool front) face;

  const FlipCard({super.key, required this.front, required this.face});

  @override
  State<FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<FlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.slow, value: 1);
  late bool _from = widget.front;

  @override
  void didUpdateWidget(FlipCard old) {
    super.didUpdateWidget(old);
    if (widget.front == old.front) return;
    _from = old.front;
    _c.duration = Motion.of(context, Motion.slow);
    _c.forward(from: 0.0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          if (_c.isCompleted) return widget.face(widget.front);
          final turn = Curves.easeInOutCubic.transform(_c.value) * 3.141592653589793;
          final first = turn < 3.141592653589793 / 2;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY(first ? turn : turn - 3.141592653589793),
            child: widget.face(first ? _from : widget.front),
          );
        },
      );
}

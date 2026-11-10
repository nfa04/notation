import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../ai/assistant_chat.dart';
import '../ai/flashcards.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../markdown/markdown_table.dart';

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
      Icon(Icons.style_outlined, size: 40, color: scheme.primary),
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
          icon: const Icon(Icons.auto_awesome, size: 18),
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
            icon: const Icon(Icons.shuffle, size: 20),
            onPressed: () => deck.startOver(shuffle: true),
          ),
          IconButton(
            key: const ValueKey('flashcards-new'),
            tooltip: tr('Make new flashcards'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: onNew,
          ),
        ]),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: deck.position / deck.roundLength),
        const SizedBox(height: 12),
        Expanded(
          child: GestureDetector(
            key: const ValueKey('flashcard'),
            onTap: deck.flip,
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
              transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(animation), child: child)),
              child: Container(
                key: ValueKey('${deck.position}-$front'),
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: front ? scheme.primaryContainer : scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(16),
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
      Icon(missed == 0 ? Icons.emoji_events_outlined : Icons.check_circle_outline, size: 40, color: scheme.primary),
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
            icon: const Icon(Icons.replay, size: 18),
            label: Text.verbatim(trCount(missed, 'Practise the missed card', 'Practise the {n} missed cards')),
            onPressed: deck.studyMissed,
          ),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: const ValueKey('flashcards-restart'),
          icon: const Icon(Icons.shuffle, size: 18),
          label: const Text('Shuffle and start over'),
          onPressed: () => deck.startOver(shuffle: true),
        ),
        if (onAddToNote != null)
          OutlinedButton.icon(
            key: const ValueKey('flashcards-add'),
            icon: const Icon(Icons.table_chart_outlined, size: 18),
            label: const Text('Add the cards to the note'),
            onPressed: () => onAddToNote!(cardsAsTable(deck.cards)),
          ),
        if (onKeep != null) _KeepButton(cards: deck.cards, onKeep: onKeep!),
        OutlinedButton.icon(
          key: const ValueKey('flashcards-copy'),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
          onPressed: () => Clipboard.setData(ClipboardData(text: cardsAsText(deck.cards))),
        ),
        TextButton.icon(
          key: const ValueKey('flashcards-new'),
          icon: const Icon(Icons.refresh, size: 18),
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
          icon: Icon(_kept ? Icons.event_available : Icons.event_repeat, size: 20),
          onPressed: _kept ? null : _keep,
        )
      : OutlinedButton.icon(
          key: const ValueKey('flashcards-keep'),
          icon: Icon(_kept ? Icons.event_available : Icons.event_repeat, size: 18),
          label: const Text('Keep for review'),
          onPressed: _kept ? null : _keep,
        );
}

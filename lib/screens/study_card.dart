import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../l10n/text.dart';
import '../markdown/markdown_view.dart';
import '../models/rich_text.dart';
import '../style/motion.dart';

/// One way to answer a card: a button, and the key 1, 2, ... in the order of the list.
class StudyRating {
  final Key key;
  final String label;

  /// A line under the label (when the card comes back).
  final String? hint;

  /// Drawn filled: the answer that is expected most often.
  final bool primary;

  const StudyRating({required this.key, required this.label, this.hint, this.primary = false});
}

/// The one card of every study screen (the assistant's and the graph's decks, the spaced-repetition review): a bar of how far
/// the round is, the card that turns over and back, and the buttons to answer. The screens keep what is studied and what an
/// answer does; this keeps what is seen and the keys: space turns the card, the arrows put it off and bring it back, 1, 2, ...
/// answer once the answer is showing.
class StudyCard extends StatefulWidget {
  /// Changes with every card in front (also when a skipped card puts another at the same place); the next one slides in.
  final Object cardKey;
  final String front, back;
  final bool flipped;
  final VoidCallback onFlip;

  /// The arrows: 1 to put the card off, -1 to bring it back. Null: no arrows.
  final ValueChanged<int>? onMove;
  final List<StudyRating> ratings;
  final ValueChanged<int> onRate;

  /// How far the round is, 0 to 1.
  final double progress;

  /// The row above the bar.
  final Widget header;

  /// A chip in the corner of the card (the page it is from).
  final Widget? corner;

  /// A picture above the text of a side (true: the question); null: none.
  final Widget? Function(bool front)? picture;

  /// Takes the keyboard at once (the review does; beside a chat box the typing field keeps it until the card is clicked).
  final bool autofocus;

  const StudyCard({
    super.key,
    required this.cardKey,
    required this.front,
    required this.back,
    required this.flipped,
    required this.onFlip,
    required this.ratings,
    required this.onRate,
    required this.progress,
    required this.header,
    this.onMove,
    this.corner,
    this.picture,
    this.autofocus = false,
  });

  @override
  State<StudyCard> createState() => _StudyCardState();
}

class _StudyCardState extends State<StudyCard> {
  final _focus = FocusNode(debugLabel: 'study card');

  /// Which way the last change of card went: the next card comes in from that side.
  int _dir = 1;

  static const _digits = [
    [LogicalKeyboardKey.digit1, LogicalKeyboardKey.numpad1],
    [LogicalKeyboardKey.digit2, LogicalKeyboardKey.numpad2],
    [LogicalKeyboardKey.digit3, LogicalKeyboardKey.numpad3],
    [LogicalKeyboardKey.digit4, LogicalKeyboardKey.numpad4],
    [LogicalKeyboardKey.digit5, LogicalKeyboardKey.numpad5],
  ];

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (!node.hasPrimaryFocus) return KeyEventResult.ignored; // (a focused button takes the space itself)
      widget.onFlip();
    } else if (widget.onMove != null && (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowLeft)) {
      _dir = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
      widget.onMove!(_dir);
    } else {
      final i = _digits.indexWhere((d) => d.contains(key));
      if (i < 0 || i >= widget.ratings.length) return KeyEventResult.ignored;
      // (a rating is only given once the answer has been seen)
      if (widget.flipped) {
        _dir = 1;
        widget.onRate(i);
      }
    }
    return KeyEventResult.handled;
  }

  String _rateKeys() => widget.ratings.length < 2 ? '1' : '1-${widget.ratings.length}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final front = !widget.flipped;
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _key,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          widget.header,
          const SizedBox(height: 4),
          TweenAnimationBuilder<double>(
            tween: Tween(end: widget.progress),
            duration: Motion.of(context, Motion.medium),
            curve: Motion.curveIn,
            builder: (context, v, _) => LinearProgressIndicator(value: v),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GestureDetector(
              key: const ValueKey('flashcard'),
              onTap: () {
                _focus.requestFocus();
                widget.onFlip();
              },
              // the next card comes in from the right while the one before leaves to the left; turning the same card over is the flip inside
              child: AnimatedSwitcher(
                duration: Motion.of(context, Motion.medium),
                switchInCurve: Motion.curveIn,
                switchOutCurve: Motion.curveOut,
                transitionBuilder: (child, animation) {
                  final side = (child.key == ValueKey(widget.cardKey) ? 0.12 : -0.12) * _dir;
                  return FadeTransition(opacity: animation, child: SlideTransition(position: Tween(begin: Offset(side, 0), end: Offset.zero).animate(animation), child: child));
                },
                child: FlipCard(
                  key: ValueKey(widget.cardKey),
                  front: front,
                  face: (front) {
                    final on = front ? scheme.onPrimaryContainer : scheme.onTertiaryContainer;
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(color: front ? scheme.primaryContainer : scheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(front ? 'Question' : 'Answer', style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: on.withValues(alpha: 0.7))),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Center(
                            child: SingleChildScrollView(
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                if (widget.picture?.call(front) case final picture?) ...[
                                  ConstrainedBox(constraints: const BoxConstraints(maxHeight: 420), child: picture),
                                  if ((front ? widget.front : widget.back).trim().isNotEmpty) const SizedBox(height: 12),
                                ],
                                CardFaceText(
                                  front ? widget.front : widget.back,
                                  key: ValueKey(front ? 'flashcard-front' : 'flashcard-back'),
                                  color: on,
                                ),
                              ]),
                            ),
                          ),
                        ),
                        Row(children: [
                          if (widget.corner != null) widget.corner!,
                          const Spacer(),
                          if (front) Text('Tap to see the answer', style: TextStyle(fontSize: 12, color: on.withValues(alpha: 0.7))),
                        ]),
                      ]),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (front)
            FilledButton(
              key: const ValueKey('flashcard-flip'),
              onPressed: widget.onFlip,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Show the answer'),
                const SizedBox(width: 8),
                Text.verbatim('␣', style: TextStyle(fontSize: 12, color: scheme.onPrimary.withValues(alpha: 0.7))),
              ]),
            )
          else
            Row(children: [
              for (final (i, r) in widget.ratings.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: (r.primary ? FilledButton.new : OutlinedButton.new)(
                    key: r.key,
                    onPressed: () {
                      _dir = 1;
                      widget.onRate(i);
                    },
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // the key that gives this answer stands in front of its name
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Text.verbatim('${i + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 6),
                        Flexible(child: Text(r.label)),
                      ]),
                      if (r.hint != null) Text.verbatim(r.hint!, style: const TextStyle(fontSize: 11)),
                    ]),
                  ),
                ),
              ],
            ]),
          if (_keyboard)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                widget.onMove == null
                    ? 'Keys: space turns the card, ${_rateKeys()} rate'
                    : 'Keys: space turns the card, arrows go to the next card, ${_rateKeys()} rate',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
        ]),
      ),
    );
  }

  /// Only where there is a keyboard to press (not on a phone or tablet).
  bool get _keyboard => switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => false,
        _ => true,
      };
}

/// Whether [text] has anything that Markdown draws otherwise than as it is typed: formulas, bold, italics, code, lists, tables, headings.
bool looksLikeMarkdown(String text) =>
    text.contains(r'$') || RegExp(r'\*\*|__|`|(^|\n)\s*([-*+] |\d+[.)] |#{1,6} |\||> )|(^|\s)[*_][^\s*_]').hasMatch(text);

/// The text of a side of a card: plain text as it is, centred; Markdown (with formulas) drawn as in a note.
class CardFaceText extends StatefulWidget {
  final String text;
  final Color color;
  final double fontSize;

  const CardFaceText(this.text, {super.key, required this.color, this.fontSize = 20});

  @override
  State<CardFaceText> createState() => _CardFaceTextState();
}

class _CardFaceTextState extends State<CardFaceText> {
  RichInlineTextController? _controller;

  void _take() {
    if (!looksLikeMarkdown(widget.text)) {
      _controller?.dispose();
      _controller = null;
      return;
    }
    (_controller ??= RichInlineTextController()).text = widget.text;
  }

  @override
  void initState() {
    super.initState();
    _take();
  }

  @override
  void didUpdateWidget(CardFaceText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _take();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return Text.verbatim(widget.text, textAlign: TextAlign.center, style: TextStyle(fontSize: widget.fontSize, color: widget.color));
    return Semantics(label: widget.text, child: MarkdownView(controller: c, fontSize: widget.fontSize * 0.9, textColor: widget.color));
  }
}


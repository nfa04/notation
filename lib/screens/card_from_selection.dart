import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../ai/cloze.dart';
import '../ai/flashcards.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'card_picture.dart';

/// The ways to make cards of a part of a page.
enum CardDraftKind {
  /// The picture is the question (or, turned round, the answer) and a typed text the other side.
  picture,

  /// Parts of the picture are covered: a card for each cover.
  covers,

  /// Words of the text are hidden: a cloze card for each.
  words,
}

/// What the person chose in [showMakeCards].
class CardDraft {
  final CardDraftKind kind;

  /// The typed side of a picture card (the answer, or the question when [reverse]).
  final String text;
  final bool reverse;

  /// The covers (left, top, width, height as parts of the picture) and whether the others stay on while one is asked.
  final List<List<double>> masks;
  final bool hideAll;

  /// The text with words hidden (`{{c1::...}}`).
  final String clozeText;

  const CardDraft({required this.kind, this.text = '', this.reverse = false, this.masks = const [], this.hideAll = false, this.clozeText = ''});

  /// The cards of this draft for the picture [base] (with its note and page); a cloze card keeps only the page.
  List<Flashcard> cards(RegionCard base) => switch (kind) {
        CardDraftKind.picture => [
            RegionCard(picture: base.picture, width: base.width, height: base.height, note: base.note, page: base.page, area: base.area, reverse: reverse)
                .card(question: reverse ? text.trim() : '', answer: reverse ? '' : text.trim()),
          ],
        CardDraftKind.covers => RegionCard.coverCards(RegionCard(
            picture: base.picture,
            width: base.width,
            height: base.height,
            note: base.note,
            page: base.page,
            area: base.area,
            masks: masks,
            hideAll: hideAll,
          )),
        CardDraftKind.words => clozeCards(clozeText, page: base.page),
      };

  /// How many cards it makes.
  int get count => switch (kind) {
        CardDraftKind.picture => text.trim().isEmpty ? 0 : 1,
        CardDraftKind.covers => masks.length,
        CardDraftKind.words => clozeNumbers(clozeText).length,
      };
}

/// Asks how to make cards of the picture [png] ([width] x [height] pixels) of a selection; [readText] is what was read of it (typed
/// text, handwriting already read), offered as the answer and as the text to hide words in. Null: nothing is made.
Future<CardDraft?> showMakeCards(BuildContext context, {required Uint8List png, required int width, required int height, String readText = ''}) =>
    showDialog<CardDraft>(
      context: context,
      builder: (context) => _MakeCardsDialog(png: png, width: width, height: height, readText: readText),
    );

class _MakeCardsDialog extends StatefulWidget {
  final Uint8List png;
  final int width, height;
  final String readText;

  const _MakeCardsDialog({required this.png, required this.width, required this.height, required this.readText});

  @override
  State<_MakeCardsDialog> createState() => _MakeCardsDialogState();
}

class _MakeCardsDialogState extends State<_MakeCardsDialog> {
  var _kind = CardDraftKind.picture;
  late final _answer = TextEditingController(text: widget.readText);
  late final _words = TextEditingController(text: widget.readText);
  var _reverse = false, _hideAll = true;
  final _masks = <List<double>>[];
  Offset? _dragFrom, _dragTo;

  @override
  void dispose() {
    _answer.dispose();
    _words.dispose();
    super.dispose();
  }

  CardDraft get _draft => CardDraft(kind: _kind, text: _answer.text, reverse: _reverse, masks: [..._masks], hideAll: _hideAll, clozeText: _words.text);

  Widget _picture({Widget? over}) => AspectRatio(
        aspectRatio: widget.width / widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: Colors.white, child: Image.memory(widget.png, fit: BoxFit.fill, gaplessPlayback: true)),
            ?over,
          ]),
        ),
      );

  /// The picture to drag covers on, [w] wide (the width of the dialog's content: a dialog measures what it holds, which a layout
  /// builder cannot be).
  Widget _coverEditor(double w) {
        final h = w * widget.height / widget.width;
        Offset part(Offset p) => Offset((p.dx / w).clamp(0, 1), (p.dy / h).clamp(0, 1));
        return _picture(
          over: GestureDetector(
            key: const ValueKey('make-card-cover-area'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              // a tap on a cover takes it away
              final p = part(d.localPosition);
              final i = _masks.lastIndexWhere((r) => Rect.fromLTWH(r[0], r[1], r[2], r[3]).contains(p));
              if (i >= 0) setState(() => _masks.removeAt(i));
            },
            onPanStart: (d) => setState(() => _dragFrom = _dragTo = part(d.localPosition)),
            onPanUpdate: (d) => setState(() => _dragTo = part(d.localPosition)),
            onPanEnd: (_) {
              final a = _dragFrom, b = _dragTo;
              setState(() {
                _dragFrom = _dragTo = null;
                if (a == null || b == null) return;
                final r = Rect.fromPoints(a, b);
                // (too small to be meant: a slip of the pen)
                if (r.width * w < 8 || r.height * h < 8) return;
                _masks.add([r.left, r.top, r.width, r.height]);
              });
            },
            child: CustomPaint(painter: _DraftCoversPainter([..._masks, if (_dragFrom != null && _dragTo != null) _rectOf(_dragFrom!, _dragTo!)])),
          ),
        );
  }

  static List<double> _rectOf(Offset a, Offset b) {
    final r = Rect.fromPoints(a, b);
    return [r.left, r.top, r.width, r.height];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quiet = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    final size = MediaQuery.sizeOf(context);
    final draft = _draft;
    final width = math.min(560.0, size.width - 32);
    return AlertDialog(
      title: const Text('Make cards'),
      scrollable: true,
      content: SizedBox(
        width: width,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<CardDraftKind>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: CardDraftKind.picture, icon: const Icon(Symbols.image), label: Text('Picture', key: const ValueKey('make-card-mode-picture'))),
                ButtonSegment(value: CardDraftKind.covers, icon: const Icon(Symbols.select), label: Text('Cover parts', key: const ValueKey('make-card-mode-covers'))),
                ButtonSegment(value: CardDraftKind.words, icon: const Icon(Symbols.format_strikethrough), label: Text('Hide words', key: const ValueKey('make-card-mode-words'))),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.single),
            ),
          ),
          const SizedBox(height: 12),
          ...switch (_kind) {
            CardDraftKind.picture => [
                Text(_reverse ? 'The picture is the answer to the question you type.' : 'The picture is the question; type the answer.', style: quiet),
                const SizedBox(height: 8),
                ConstrainedBox(constraints: const BoxConstraints(maxHeight: 260), child: _picture()),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('make-card-answer'),
                  controller: _answer,
                  minLines: 1,
                  maxLines: 5,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: tr(_reverse ? 'Question' : 'Answer'), border: const OutlineInputBorder()),
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('make-card-reverse'),
                  contentPadding: EdgeInsets.zero,
                  value: _reverse,
                  onChanged: (v) => setState(() => _reverse = v),
                  title: const Text('The picture is the answer'),
                ),
              ],
            CardDraftKind.covers => [
                Text('Drag over each part to hide (a label, a name, a step). Each cover becomes a card. Tap a cover to take it away.', style: quiet),
                const SizedBox(height: 8),
                _coverEditor(width),
                SwitchListTile.adaptive(
                  key: const ValueKey('make-card-hide-all'),
                  contentPadding: EdgeInsets.zero,
                  value: _hideAll,
                  onChanged: (v) => setState(() => _hideAll = v),
                  title: const Text('Keep the other covers on'),
                  subtitle: Text(_hideAll ? 'All parts are hidden and one is asked: harder, nothing gives the answer away.' : 'Only the part asked is hidden.', style: quiet),
                ),
              ],
            CardDraftKind.words => [
                Text('Choose words in the text and hide them. Each hidden part becomes a card that asks for it.', style: quiet),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('make-card-words'),
                  controller: _words,
                  minLines: 3,
                  maxLines: 8,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(hintText: tr('Type or paste the text'), border: const OutlineInputBorder()),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('make-card-hide-words'),
                    icon: const Icon(Symbols.visibility_off),
                    label: const Text('Hide the chosen words'),
                    onPressed: () {
                      final s = _words.selection;
                      if (!s.isValid || s.isCollapsed) return;
                      final hidden = hideAsCloze(_words.text, s.start, s.end);
                      setState(() => _words.value = TextEditingValue(text: hidden, selection: TextSelection.collapsed(offset: hidden.length)));
                    },
                  ),
                ),
              ],
          },
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('make-card-save'),
          onPressed: draft.count == 0 ? null : () => Navigator.pop(context, draft),
          child: Text.verbatim(draft.count <= 1 ? tr('Make the card') : tr('Make {n} cards', {'n': draft.count})),
        ),
      ],
    );
  }
}

class _DraftCoversPainter extends CustomPainter {
  final List<List<double>> masks;

  _DraftCoversPainter(this.masks);

  @override
  void paint(Canvas canvas, Size size) {
    for (final (i, r) in masks.indexed) {
      final rect = Rect.fromLTWH(r[0] * size.width, r[1] * size.height, r[2] * size.width, r[3] * size.height);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), Paint()..color = askedCoverColor.withValues(alpha: 0.85));
      final label = TextPainter(
        text: TextSpan(text: '${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, rect.center - Offset(label.width / 2, label.height / 2));
      label.dispose();
    }
  }

  @override
  bool shouldRepaint(_DraftCoversPainter old) => true;
}

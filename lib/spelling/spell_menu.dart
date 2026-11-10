import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../l10n/language.dart';
import '../models/rich_text.dart';
import 'spell_service.dart';

/// The entries for the menu of a text field when the cursor (or the highlight) is on a misspelled word: what it may have been
/// meant to be, and to add the word to the person's own dictionary or leave it alone. Nothing for a word that is right.
List<ContextMenuButtonItem> spellMenuItems(RichInlineTextController controller, SpellService service, TextSelection selection, VoidCallback hide) {
  if (!selection.isValid) return const [];
  final at = controller.misspelled.where((r) => selection.start >= r.start && selection.end <= r.end).firstOrNull;
  // (the word being typed is not marked; a word that was just typed is checked now)
  final range = at ?? _freshWord(controller, service, selection);
  if (range == null || range.end > controller.text.length) return const [];
  final word = controller.text.substring(range.start, range.end);
  final suggestions = service.checker.suggestions(word, max: 4);
  void replace(String with_) {
    hide();
    final text = controller.text;
    controller.value = TextEditingValue(
      text: text.replaceRange(range.start, range.end, with_),
      selection: TextSelection.collapsed(offset: range.start + with_.length),
    );
  }

  return [
    for (final s in suggestions) ContextMenuButtonItem(label: s, onPressed: () => replace(s)),
    ContextMenuButtonItem(
      label: tr('Add to dictionary'),
      onPressed: () {
        hide();
        service.addWord(word).then((_) => controller.recheckSpelling());
      },
    ),
    ContextMenuButtonItem(
      label: tr('Ignore'),
      onPressed: () {
        hide();
        service.ignore(word);
        controller.recheckSpelling();
      },
    ),
  ];
}

TextRange? _freshWord(RichInlineTextController controller, SpellService service, TextSelection selection) {
  if (!service.active) return null;
  for (final r in service.checker.misspellings(controller.text)) {
    if (selection.start >= r.start && selection.end <= r.end) return r;
  }
  return null;
}

/// What can be done about the misspelled word at [range]: what it may have been meant to be, adding it to the dictionary
/// and leaving it alone.
List<(String, VoidCallback)> _actions(RichInlineTextController controller, SpellService service, TextRange range, VoidCallback hide) {
  final word = controller.text.substring(range.start, range.end);
  void replace(String with_) {
    hide();
    final text = controller.text;
    controller.value = TextEditingValue(
      text: text.replaceRange(range.start, range.end, with_),
      selection: TextSelection.collapsed(offset: range.start + with_.length),
    );
  }

  return [
    for (final s in service.checker.suggestions(word, max: 5)) (s, () => replace(s)),
    (
      tr('Add to dictionary'),
      () {
        hide();
        service.addWord(word).then((_) => controller.recheckSpelling());
      }
    ),
    (
      tr('Ignore'),
      () {
        hide();
        service.ignore(word);
        controller.recheckSpelling();
      }
    ),
  ];
}

/// Wraps a text field: a tap that puts the cursor in a misspelled word opens a small menu with what it may have been meant
/// to be (a long press or a right click gets the same in the usual menu, see [spellMenuItems]).
class SpellTapRegion extends StatefulWidget {
  final RichInlineTextController controller;
  final SpellService? service;
  final Widget child;

  /// Where a word is on the screen, for text that is not one field (see BlockEditor).
  final Rect? Function(TextRange range)? wordRect;

  const SpellTapRegion({super.key, required this.controller, required this.service, required this.child, this.wordRect});

  @override
  State<SpellTapRegion> createState() => _SpellTapRegionState();
}

class _SpellTapRegionState extends State<SpellTapRegion> {
  Offset? _down;
  DateTime _downAt = DateTime.now();

  void _up(PointerUpEvent e) {
    final down = _down;
    _down = null;
    if (down == null || widget.service == null) return;
    final tap = (e.position - down).distance < 10 && DateTime.now().difference(_downAt) < const Duration(milliseconds: 400);
    if (!tap) return;
    final at = e.position;
    // the field moves its cursor when the tap is over: look then
    Future<void>.delayed(const Duration(milliseconds: 60), () => _open(at));
  }

  void _open(Offset at) {
    if (!mounted || widget.service == null) return;
    final c = widget.controller;
    final sel = c.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    final range = c.misspelled.where((r) => sel.baseOffset >= r.start && sel.baseOffset <= r.end && r.end <= c.text.length).firstOrNull;
    if (range == null) return;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final actions = _actions(c, widget.service!, range, () {});
    // under the word, not over it (above it where there is no room below)
    const itemHeight = 36.0;
    final height = actions.length * itemHeight + 16;
    var spot = Rect.fromLTWH(at.dx, at.dy, 1, 1);
    final word = widget.wordRect?.call(range);
    final editable = word == null ? _editable(context.findRenderObject()) : null;
    if (word != null) {
      final below = word.bottom + 4;
      spot = Rect.fromLTWH(word.left, below + height > overlay.size.height ? word.top - height - 4 : below, 1, 1);
    } else if (editable != null) {
      final boxes = editable.getBoxesForSelection(TextSelection(baseOffset: range.start, extentOffset: range.end));
      if (boxes.isNotEmpty) {
        final word = boxes.map((b) => b.toRect()).reduce((a, b) => a.expandToInclude(b));
        final top = editable.localToGlobal(word.topLeft), bottom = editable.localToGlobal(word.bottomLeft);
        final below = bottom.dy + 4;
        spot = Rect.fromLTWH(top.dx, below + height > overlay.size.height ? top.dy - height - 4 : below, 1, 1);
      }
    }
    showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(spot, Offset.zero & overlay.size),
      items: [
        for (var i = 0; i < actions.length; i++)
          PopupMenuItem<int>(
            key: ValueKey('spell-suggestion-$i'),
            value: i,
            height: itemHeight,
            child: Text(actions[i].$1, style: i < actions.length - 2 ? const TextStyle(fontWeight: FontWeight.w600) : null),
          ),
      ],
    ).then((i) {
      if (i != null) _actions(c, widget.service!, range, () {})[i].$2();
    });
  }

  /// The text of the field that is inside of this region.
  RenderEditable? _editable(RenderObject? root) {
    RenderEditable? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderEditable) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    if (root != null) visit(root);
    return found;
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          _down = e.position;
          _downAt = DateTime.now();
        },
        onPointerUp: _up,
        child: widget.child,
      );
}

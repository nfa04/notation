import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../models/canvas_models.dart';
import '../models/stroke_label.dart';
import '../painters/canvas_painters.dart';
import 'color_swatches.dart';
import 'color_wheel_dialog.dart';
import '../style/platform_dialog.dart';

/// What the person did in the label dialog: [label] is the text as it is to be now, null to take the text off.
class LabelEdit {
  final StrokeLabel? label;
  const LabelEdit(this.label);
}

/// Asks for the text of a line or a shape: the words, whether they run along the line or stand inside the shape, and how they are set.
/// [initial] is the text there is (offering to take it off); [lineColor] and [fill] are those of the line, for the automatic colour and
/// the preview. Answers null when cancelled.
Future<LabelEdit?> showLabelDialog(BuildContext context, {StrokeLabel? initial, required Color lineColor, Color? fill, bool closed = false}) =>
    showDialog<LabelEdit>(context: context, builder: (_) => LabelDialog(initial: initial, lineColor: lineColor, fill: fill, closed: closed));

class LabelDialog extends StatefulWidget {
  final StrokeLabel? initial;
  final Color lineColor;
  final Color? fill;
  final bool closed;

  const LabelDialog({super.key, this.initial, required this.lineColor, this.fill, this.closed = false});

  @override
  State<LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<LabelDialog> {
  late final _text = TextEditingController(text: widget.initial?.text ?? '');
  late StrokeLabel _label = widget.initial ?? StrokeLabel(text: '', place: widget.closed ? LabelPlace.inside : LabelPlace.along);
  final List<Color> _mine = [];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(StrokeLabel Function(StrokeLabel l) change) => setState(() => _label = change(_label));

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
      );

  @override
  Widget build(BuildContext context) {
    final label = _label.copyWith(text: _text.text);
    return PlatformAlertDialog(
      title: const Text('Text on the line or shape'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              key: const ValueKey('label-text'),
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr('The words')),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Container(
              height: 96,
              width: double.infinity,
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CustomPaint(painter: _LabelPreview(label, widget.lineColor, widget.fill)),
              ),
            ),
            _heading(tr('Where')),
            SegmentedButton<LabelPlace>(
              key: const ValueKey('label-place'),
              showSelectedIcon: false,
              segments: [for (final p in LabelPlace.values) ButtonSegment(value: p, label: Text(p.label))],
              selected: {_label.place},
              onSelectionChanged: (s) => _set((l) => l.copyWith(place: s.first)),
            ),
            if (_label.place == LabelPlace.along) ...[
              _heading(tr('Starts at')),
              SegmentedButton<LabelAlign>(
                key: const ValueKey('label-align'),
                showSelectedIcon: false,
                segments: [for (final a in LabelAlign.values) ButtonSegment(value: a, label: Text(a.label))],
                selected: {_label.align},
                onSelectionChanged: (s) => _set((l) => l.copyWith(align: s.first)),
              ),
              _heading(tr('Side of the line')),
              SegmentedButton<LabelSide>(
                key: const ValueKey('label-side'),
                showSelectedIcon: false,
                segments: [for (final d in LabelSide.values) ButtonSegment(value: d, label: Text(d.label))],
                selected: {_label.side},
                onSelectionChanged: (s) => _set((l) => l.copyWith(side: s.first)),
              ),
              if (!widget.closed)
                SwitchListTile.adaptive(
                  key: const ValueKey('label-turned'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _label.turned,
                  onChanged: (v) => _set((l) => l.copyWith(turned: v)),
                  title: const Text('Read it from the other end'),
                ),
            ],
            _heading(tr('Letters')),
            Row(children: [
              const Text('Size'),
              Expanded(
                child: Slider.adaptive(
                  key: const ValueKey('label-size'),
                  value: _label.size.clamp(8.0, 96.0),
                  min: 8,
                  max: 96,
                  divisions: 44,
                  label: _label.size.round().toString(),
                  onChanged: (v) => _set((l) => l.copyWith(size: v.roundToDouble())),
                ),
              ),
              SizedBox(width: 32, child: Text.verbatim('${_label.size.round()}')),
            ]),
            SwitchListTile.adaptive(
              key: const ValueKey('label-bold'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _label.bold,
              onChanged: (v) => _set((l) => l.copyWith(bold: v)),
              title: const Text('Bold'),
            ),
            _heading(tr('Colour')),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ChoiceChip(
                key: const ValueKey('label-color-auto'),
                label: const Text('Automatic'),
                selected: _label.color == null,
                onSelected: (_) => _set((l) => l.copyWith(noColor: true)),
              ),
            ]),
            const SizedBox(height: 6),
            ColorSwatches(
              selected: _label.color,
              keyPrefix: 'label-color',
              extra: _mine,
              onPick: (c) => _set((l) => l.copyWith(color: c)),
              onMore: () async {
                final c = await pickColorOnWheel(context, _label.color ?? widget.lineColor);
                if (c != null) {
                  setState(() => _mine.add(c));
                  _set((l) => l.copyWith(color: c));
                }
              },
            ),
          ]),
        ),
      ),
      actions: [
        if (widget.initial != null) TextButton(key: const ValueKey('label-remove'), onPressed: () => Navigator.pop(context, const LabelEdit(null)), child: const Text('Take the text off')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('label-apply'),
          onPressed: label.isEmpty ? null : () => Navigator.pop(context, LabelEdit(label)),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// A sample line (or shape, for text inside) with the text as it is set.
class _LabelPreview extends CustomPainter {
  final StrokeLabel label;
  final Color lineColor;
  final Color? fill;
  _LabelPreview(this.label, this.lineColor, this.fill);

  @override
  void paint(Canvas canvas, Size size) {
    final inside = label.place == LabelPlace.inside;
    final points = inside
        ? [for (var i = 0; i <= 48; i++) Offset(size.width / 2 + size.width * 0.4 * math.cos(i / 48 * 2 * math.pi), size.height / 2 + size.height * 0.42 * math.sin(i / 48 * 2 * math.pi))]
        : [for (var i = 0; i <= 40; i++) Offset(16 + (size.width - 32) * i / 40, size.height * 0.62 - size.height * 0.3 * math.sin(i / 40 * math.pi))];
    final sample = DrawingStroke(
      color: lineColor,
      width: 3,
      points: points,
      fill: inside ? (fill ?? lineColor.withValues(alpha: 0.12)) : null,
      label: label.isEmpty ? StrokeLabel(text: tr('Your words'), place: label.place, align: label.align, side: label.side, turned: label.turned, size: label.size, bold: label.bold, color: label.color) : label,
    );
    // (a preview is a small sample: the letters are shown at their size, but no bigger than the sample)
    paintStrokes(canvas, [sample], 0);
  }

  @override
  bool shouldRepaint(_LabelPreview old) => old.label != label || old.lineColor != lineColor || old.fill != fill;
}

import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../models/canvas_models.dart';
import '../models/gradient.dart';
import 'color_swatches.dart';
import 'color_wheel_dialog.dart';
import '../style/platform_dialog.dart';

/// The look of a line or a shape.
class ShapeStyle {
  final Color color;
  final double width;
  final StrokeDash dash;

  /// The colour inside a closed shape; null: nothing.
  final Color? fill;

  /// Where the fill runs to another colour (see `gradient.dart`); null: the fill is one colour.
  final FillGradient? gradient;
  const ShapeStyle({required this.color, required this.width, this.dash = StrokeDash.solid, this.fill, this.gradient});

  ShapeStyle copyWith({Color? color, double? width, StrokeDash? dash, Color? fill, bool noFill = false, FillGradient? gradient, bool noGradient = false}) => ShapeStyle(
        color: color ?? this.color,
        width: width ?? this.width,
        dash: dash ?? this.dash,
        fill: noFill ? null : (fill ?? this.fill),
        gradient: noFill || noGradient ? null : (gradient ?? this.gradient),
      );

  static ShapeStyle of(DrawingStroke s) => ShapeStyle(color: s.color, width: s.width, dash: s.dash, fill: s.fill, gradient: s.fill == null ? null : s.gradient);
}

/// Asks for the look of a shape: the line (colour, width, dashes) and the fill. Returns the choice, or null if cancelled.
Future<ShapeStyle?> showShapeStyleDialog(BuildContext context, ShapeStyle initial, {bool canFill = true}) =>
    showDialog<ShapeStyle>(context: context, builder: (_) => ShapeStyleDialog(initial: initial, canFill: canFill));

/// A dialog for the look of a shape: line colour, width, dashes and fill.
class ShapeStyleDialog extends StatefulWidget {
  final ShapeStyle initial;
  final bool canFill;
  const ShapeStyleDialog({super.key, required this.initial, this.canFill = true});

  @override
  State<ShapeStyleDialog> createState() => _ShapeStyleDialogState();
}

class _ShapeStyleDialogState extends State<ShapeStyleDialog> {
  late ShapeStyle _style = widget.initial;
  final List<Color> _mine = [];

  /// How solid the fill is (kept apart, so that the slider has a place when there is no fill yet).
  late double _opacity = widget.initial.fill?.a ?? 0.35;

  Widget _swatches(Color? selected, ValueChanged<Color> onPick, {Future<Color?> Function()? more, String keyPrefix = 'line'}) => ColorSwatches(
        selected: selected,
        onPick: onPick,
        extra: _mine,
        keyPrefix: keyPrefix,
        onMore: more == null
            ? null
            : () async {
                final c = await more();
                if (c != null) {
                  setState(() => _mine.add(c));
                  onPick(c);
                }
              },
      );

  /// Makes the fill run to a second colour (or one again): [kind] is 0 for none, 1 for along a line, 2 from the middle.
  void _chooseGradient(int kind) => setState(() {
        if (kind == 0) {
          _style = _style.copyWith(noGradient: true);
          return;
        }
        final fill = _style.fill ?? _style.color.withValues(alpha: _opacity);
        final old = _style.gradient;
        // (a second colour that is not the first: a turn along the colour wheel)
        final hsl = HSLColor.fromColor(fill);
        final end = old?.end ?? hsl.withHue((hsl.hue + 40) % 360).withLightness((hsl.lightness < 0.5 ? hsl.lightness + 0.3 : hsl.lightness - 0.3).clamp(0.0, 1.0)).toColor().withValues(alpha: fill.a);
        _style = _style.copyWith(fill: fill, gradient: (old ?? FillGradient(end: end)).copyWith(radial: kind == 2));
      });

  /// The choice of a gradient for the fill: none, along a line or from the middle, the second colour, and the angle of a line.
  List<Widget> _gradientControls(ColorScheme scheme) {
    final g = _style.gradient;
    return [
      const SizedBox(height: 12),
      Text('Gradient', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      SegmentedButton<int>(
        key: const ValueKey('gradient-kind'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: 0, label: const Text('None'), tooltip: tr('One colour')),
          ButtonSegment(value: 1, label: const Text('Linear'), tooltip: tr('From one side to the other')),
          ButtonSegment(value: 2, label: const Text('Radial'), tooltip: tr('From the middle outwards')),
        ],
        selected: {g == null ? 0 : (g.radial ? 2 : 1)},
        onSelectionChanged: (s) => _chooseGradient(s.first),
      ),
      if (g != null) ...[
        const SizedBox(height: 8),
        _swatches(g.end, (c) => setState(() => _style = _style.copyWith(gradient: g.copyWith(end: c.withValues(alpha: _opacity)))),
            more: () => pickColorOnWheel(context, g.end), keyPrefix: 'gradient'),
        if (!g.radial)
          Row(children: [
            const Text('Angle'),
            Expanded(
              child: Slider.adaptive(
                key: const ValueKey('gradient-angle'),
                value: g.angle.toDouble().clamp(0, 360),
                min: 0,
                max: 360,
                divisions: 24,
                label: '${g.angle}°',
                onChanged: (v) => setState(() => _style = _style.copyWith(gradient: g.copyWith(angle: v.round()))),
              ),
            ),
            SizedBox(width: 40, child: Text.verbatim('${g.angle}°')),
          ]),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = _style.fill;
    return PlatformAlertDialog(
      title: const Text('Style'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            // how it will look
            Container(
              height: 80,
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
              child: CustomPaint(painter: _PreviewPainter(_style)),
            ),
            Text('Line', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _swatches(_style.color, (c) => setState(() => _style = _style.copyWith(color: c)), more: () => pickColorOnWheel(context, _style.color)),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Width'),
              Expanded(
                child: Slider.adaptive(
                  key: const ValueKey('style-width'),
                  value: _style.width.clamp(0.5, 30.0),
                  min: 0.5,
                  max: 30,
                  divisions: 59,
                  label: _style.width.toStringAsFixed(1),
                  onChanged: (v) => setState(() => _style = _style.copyWith(width: v)),
                ),
              ),
              SizedBox(width: 40, child: Text.verbatim(_style.width.toStringAsFixed(1))),
            ]),
            SegmentedButton<StrokeDash>(
              key: const ValueKey('style-dash'),
              showSelectedIcon: false,
              segments: [for (final d in StrokeDash.values) ButtonSegment(value: d, label: Text(d.label))],
              selected: {_style.dash},
              onSelectionChanged: (s) => setState(() => _style = _style.copyWith(dash: s.first)),
            ),
            if (widget.canFill) ...[
              const SizedBox(height: 16),
              Text('Fill (closed shapes)', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                ChoiceChip(
                  key: const ValueKey('fill-none'),
                  label: const Text('None'),
                  selected: fill == null,
                  onSelected: (_) => setState(() => _style = _style.copyWith(noFill: true)),
                ),
                ChoiceChip(
                  key: const ValueKey('fill-same'),
                  label: const Text('Like the line'),
                  selected: fill != null && fill.toARGB32() == _style.color.withValues(alpha: _opacity).toARGB32(),
                  onSelected: (_) => setState(() => _style = _style.copyWith(fill: _style.color.withValues(alpha: _opacity))),
                ),
              ]),
              const SizedBox(height: 8),
              _swatches(fill, (c) => setState(() => _style = _style.copyWith(fill: c.withValues(alpha: _opacity))), more: () => pickColorOnWheel(context, fill ?? _style.color), keyPrefix: 'fill'),
              Row(children: [
                const Text('Opacity'),
                Expanded(
                  child: Slider.adaptive(
                    key: const ValueKey('fill-opacity'),
                    value: _opacity,
                    min: 0.05,
                    max: 1,
                    onChanged: fill == null
                        ? null
                        : (v) => setState(() {
                              _opacity = v;
                              final g = _style.gradient;
                              _style = _style.copyWith(fill: fill.withValues(alpha: v), gradient: g?.copyWith(end: g.end.withValues(alpha: v)));
                            }),
                  ),
                ),
                SizedBox(width: 40, child: Text.verbatim('${(_opacity * 100).round()}%')),
              ]),
              ..._gradientControls(scheme),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('style-apply'), onPressed: () => Navigator.pop(context, _style), child: const Text('Apply')),
      ],
    );
  }
}

class _PreviewPainter extends CustomPainter {
  final ShapeStyle style;
  _PreviewPainter(this.style);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(size.width * 0.25, 14, size.width * 0.5, size.height - 28);
    if (style.fill != null) {
      final shader = style.gradient?.shader(r, style.fill!);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), shader == null ? (Paint()..color = style.fill!) : (Paint()..shader = shader));
    }
    final path = Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)));
    final paint = Paint()
      ..color = style.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = style.width
      ..strokeCap = StrokeCap.round;
    if (style.dash == StrokeDash.solid) {
      canvas.drawPath(path, paint);
      return;
    }
    final on = style.dash == StrokeDash.dashed ? (style.width * 3.5).clamp(8.0, 100.0) : 0.1;
    final off = style.dash == StrokeDash.dashed ? (style.width * 2.5).clamp(6.0, 100.0) : (style.width * 2.2).clamp(5.0, 100.0);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += on + off) {
        canvas.drawPath(metric.extractPath(d, (d + on).clamp(0, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.style != style;
}

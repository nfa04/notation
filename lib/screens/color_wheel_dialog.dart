import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../models/color_harmony.dart';
import '../style/platform_dialog.dart';

/// Lets the user pick any colour on a hue/saturation wheel plus a brightness
/// slider; null if cancelled.
Future<Color?> pickColorOnWheel(BuildContext context, Color initial) async => (await pickColorsOnWheel(context, initial))?.use;

/// What the wheel decided: the colour to use, and the colours to keep (the colour itself, or a whole harmony palette).
typedef WheelChoice = ({Color use, List<Color> keep});

/// The wheel, also offering palettes (complementary, triadic, analogous) built on the colour; null if cancelled.
Future<WheelChoice?> pickColorsOnWheel(BuildContext context, Color initial) =>
    showDialog<WheelChoice>(context: context, builder: (_) => ColorWheelDialog(initial: initial));

String harmonyName(Harmony h) => switch (h) {
  Harmony.complementary => tr('Complementary'),
  Harmony.triadic => tr('Triadic'),
  Harmony.analogous => tr('Analogous'),
};

/// A dialog to pick any colour on a wheel; pops the chosen [WheelChoice], or null.
class ColorWheelDialog extends StatefulWidget {
  final Color initial;

  const ColorWheelDialog({super.key, required this.initial});

  @override
  State<ColorWheelDialog> createState() => _ColorWheelDialogState();
}

class _ColorWheelDialogState extends State<ColorWheelDialog> {
  static const double _size = 220;
  // A dark colour (black is the usual text and pen colour) would open the wheel at no brightness: a black disc, nothing to pick
  // from. It opens as bright as the colours are, with the hue it has.
  late HSVColor _hsv = _openedAs(HSVColor.fromColor(widget.initial));

  // The palette on offer is built on the colour as the wheel last set it, so that taking a colour of the palette does not move the palette.
  Harmony? _harmony;
  late Color _base = _hsv.toColor();

  static HSVColor _openedAs(HSVColor c) => c.value < 0.35 ? c.withValue(1) : c;

  void _pick(Offset local) {
    const r = _size / 2;
    final d = local - const Offset(r, r);
    final hue = (math.atan2(d.dy, d.dx) * 180 / math.pi + 360) % 360;
    final sat = (d.distance / r).clamp(0.0, 1.0);
    setState(() {
      _hsv = HSVColor.fromAHSV(1, hue, sat, _hsv.value);
      _base = _hsv.toColor();
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    const r = _size / 2;
    final angle = _hsv.hue * math.pi / 180;
    final marker = Offset(r + math.cos(angle) * _hsv.saturation * r, r + math.sin(angle) * _hsv.saturation * r);
    return PlatformAlertDialog(
      title: const Text('Pick a color'),
      content: SizedBox(
        width: _size,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            key: const ValueKey('color-wheel'),
            onPanStart: (d) => _pick(d.localPosition),
            onPanUpdate: (d) => _pick(d.localPosition),
            onTapDown: (d) => _pick(d.localPosition),
            child: SizedBox(
              width: _size,
              height: _size,
              child: Stack(children: [
                CustomPaint(size: const Size(_size, _size), painter: _WheelPainter(_hsv.value)),
                Positioned(
                  left: marker.dx - 9,
                  top: marker.dy - 9,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black54)],
                    ),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Slider.adaptive(
            key: const ValueKey('color-brightness'),
            value: _hsv.value,
            onChanged: (v) => setState(() {
              _hsv = _hsv.withValue(v);
              _base = _hsv.toColor();
            }),
          ),
          Container(
            height: 28,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            for (final h in Harmony.values)
              ChoiceChip(
                key: ValueKey('harmony-${h.name}'),
                label: Text(harmonyName(h)),
                selected: _harmony == h,
                onSelected: (on) => setState(() {
                  _harmony = on ? h : null;
                  _base = color;
                }),
              ),
          ]),
          if (_harmony != null) ...[
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final c in harmonyOf(_base, _harmony!))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkResponse(
                    key: ValueKey('harmony-swatch-${c.toARGB32().toRadixString(16)}'),
                    radius: 24,
                    onTap: () => setState(() => _hsv = HSVColor.fromColor(c)),
                    child: Semantics(
                      button: true,
                      label: tr('Use this color'),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(color: Theme.of(context).colorScheme.outline),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ],
        ])),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (_harmony != null)
          TextButton(
            key: const ValueKey('harmony-keep'),
            onPressed: () => Navigator.pop<WheelChoice>(context, (use: color, keep: [...harmonyOf(_base, _harmony!), color])),
            child: Text(tr('Add palette')),
          ),
        FilledButton(onPressed: () => Navigator.pop<WheelChoice>(context, (use: color, keep: [color])), child: const Text('Add')),
      ],
    );
  }
}

class _WheelPainter extends CustomPainter {
  final double brightness;

  _WheelPainter(this.brightness);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: size.width / 2);
    canvas.drawCircle(
      center,
      size.width / 2,
      Paint()
        ..shader = SweepGradient(colors: [
          for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
        ]).createShader(rect),
    );
    canvas.drawCircle(
      center,
      size.width / 2,
      Paint()..shader = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]).createShader(rect),
    );
    canvas.drawCircle(center, size.width / 2, Paint()..color = Colors.black.withValues(alpha: 1 - brightness));
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) => old.brightness != brightness;
}

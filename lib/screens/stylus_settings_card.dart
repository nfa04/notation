import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;

import '../l10n/text.dart';
import '../style/stylus_settings.dart';

/// How the pen is used: pressure, the button on its side, what fingers do, and the ring where it hovers.
class StylusSettingsCard extends StatelessWidget {
  final StylusSettings settings;
  const StylusSettingsCard({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Pen and fingers', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('For a stylus on a tablet or a screen that has one. A pen that cannot tell how hard it presses draws lines of one thickness.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        SwitchListTile.adaptive(
          key: const ValueKey('stylus-pressure'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Thicker lines where the pen presses harder'),
          value: settings.pressure,
          onChanged: settings.setPressure,
        ),
        if (settings.pressure)
          Row(children: [
            const Text('Sensitivity'),
            Expanded(
              child: Slider.adaptive(
                key: const ValueKey('stylus-sensitivity'),
                value: settings.sensitivity,
                divisions: 10,
                label: '${(settings.sensitivity * 100).round()}%',
                onChanged: settings.setSensitivity,
              ),
            ),
          ]),
        if (settings.pressure) ...[
          Row(children: [
            const Text('Response'),
            Expanded(
              child: Slider.adaptive(
                key: const ValueKey('stylus-curve'),
                value: settings.curve,
                min: -1,
                max: 1,
                divisions: 20,
                label: settings.curve == 0 ? 'Linear' : (settings.curve < 0 ? 'Soft' : 'Firm'),
                onChanged: settings.setCurve,
              ),
            ),
          ]),
          Text('Soft: a light touch already gives a thick line. Firm: it takes a hard press.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          Row(children: [
            const Text('Tilt thickens'),
            Expanded(
              child: Slider.adaptive(
                key: const ValueKey('stylus-tilt'),
                value: settings.tilt,
                divisions: 10,
                label: '${(settings.tilt * 100).round()}%',
                onChanged: settings.setTilt,
              ),
            ),
          ]),
          Text('A pen that reports how far it leans draws thicker lines when held flat, like the side of a pencil.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 8),
          PenTestPad(settings: settings),
        ],
        const SizedBox(height: 4),
        _choice<BarrelAction>('Button on the side of the pen (held down)', 'stylus-barrel', BarrelAction.values, settings.barrel, (b) => b.label, settings.setBarrel),
        const SizedBox(height: 12),
        _choice<FingerMode>('A finger', 'stylus-fingers', FingerMode.values, settings.fingers, (b) => b.label, settings.setFingers),
        const SizedBox(height: 4),
        Text(
          settings.fingers == FingerMode.auto
              ? 'Once the pen has been used, fingers only scroll and zoom, so that a resting hand does not write.'
              : (settings.fingers == FingerMode.scroll ? 'Fingers never write; only the pen (or a mouse) does.' : 'Fingers write too, also when a pen is in use.'),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('stylus-hover'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show a ring where the pen hovers'),
          subtitle: const Text('As big as the line it would draw.'),
          value: settings.hoverRing,
          onChanged: settings.setHoverRing,
        ),
      ]),
    );
  }

  Widget _choice<T extends Enum>(String label, String key, List<T> values, T current, String Function(T) name, Future<void> Function(T) set) =>
      Row(children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        DropdownButton<T>(
          key: ValueKey(key),
          value: current,
          items: [for (final v in values) DropdownMenuItem(value: v, child: Text(name(v)))],
          onChanged: (v) => set(v as T),
        ),
      ]);
}

/// A small pad to try the pen on: shows the response curve and draws with the thickness the settings give (nothing is saved).
class PenTestPad extends StatefulWidget {
  final StylusSettings settings;
  const PenTestPad({super.key, required this.settings});

  @override
  State<PenTestPad> createState() => _PenTestPadState();
}

class _PenTestPadState extends State<PenTestPad> {
  final List<({Offset at, double width})?> _dots = [];
  double? _live;

  void _add(PointerEvent e) {
    var raw = 0.5;
    if (e.kind == PointerDeviceKind.stylus && e.pressureMax > e.pressureMin) raw = ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin)).clamp(0.0, 1.0);
    final lean = e.kind == PointerDeviceKind.stylus ? e.tilt / (math.pi / 2) : 0.0;
    final r = widget.settings.response(raw, lean: lean);
    setState(() {
      _live = r;
      _dots.add((at: e.localPosition, width: 1 + r * 12));
      if (_dots.length > 600) _dots.removeRange(0, _dots.length - 600);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 96,
          height: 96,
          child: CustomPaint(
            key: const ValueKey('pen-curve'),
            painter: _CurvePainter(widget.settings.curve, _live, scheme.primary, scheme.outlineVariant),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 96,
            decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
            clipBehavior: Clip.antiAlias,
            child: Listener(
              key: const ValueKey('pen-test-pad'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                _dots.add(null);
                _add(e);
              },
              onPointerMove: _add,
              onPointerUp: (_) => setState(() => _live = null),
              child: CustomPaint(painter: _PadPainter(List.of(_dots), scheme.onSurface), child: const Center(child: SizedBox.expand())),
            ),
          ),
        ),
      ]),
    );
  }
}

class _PadPainter extends CustomPainter {
  final List<({Offset at, double width})?> dots;
  final Color color;
  _PadPainter(this.dots, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    ({Offset at, double width})? last;
    for (final d in dots) {
      if (d == null) {
        last = null;
        continue;
      }
      if (last != null) {
        // (round dots along the way, so that the thickness changes smoothly)
        final n = math.max(1, ((d.at - last.at).distance / 1.5).ceil());
        for (var k = 1; k <= n; k++) {
          canvas.drawCircle(Offset.lerp(last.at, d.at, k / n)!, (last.width + (d.width - last.width) * k / n) / 2, paint);
        }
      } else {
        canvas.drawCircle(d.at, d.width / 2, paint);
      }
      last = d;
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}

/// The response curve: how hard the pen is pressed (across) against how much it counts (up); a dot where the pen is now.
class _CurvePainter extends CustomPainter {
  final double curve;
  final double? live;
  final Color line, frame;
  _CurvePainter(this.curve, this.live, this.line, this.frame);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()
      ..style = PaintingStyle.stroke
      ..color = frame);
    final path = Path();
    for (var i = 0; i <= 40; i++) {
      final x = i / 40, y = StylusSettings.shaped(x, curve);
      final at = Offset(x * size.width, size.height - y * size.height);
      i == 0 ? path.moveTo(at.dx, at.dy) : path.lineTo(at.dx, at.dy);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = line);
  }

  @override
  bool shouldRepaint(_CurvePainter old) => old.curve != curve || old.live != live;
}

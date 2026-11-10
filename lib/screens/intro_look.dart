import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/app_theme.dart';
import '../style/stylus_settings.dart';
import 'color_swatches.dart';

/// What the intro needs for its step about the look of the app and the pen.
class IntroLook {
  final AppTheme? theme;
  final StylusSettings? stylus;

  const IntroLook({this.theme, this.stylus});
}

/// The language, the colour of the app and what a finger does, with a pad to try the pen on: it says what kind of pointer wrote on it.
class IntroLookPage extends StatelessWidget {
  final IntroLook look;

  const IntroLookPage({super.key, required this.look});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold);
    final hint = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final stylus = look.stylus;
    final theme = look.theme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Language, colour and pen', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      Text('All of this can be changed later in the settings.', style: hint),
      const SizedBox(height: 20),
      Text('Language', style: label),
      const SizedBox(height: 8),
      ListenableBuilder(
        listenable: AppLanguage.instance,
        builder: (context, _) => Wrap(spacing: 8, runSpacing: 8, children: [
          for (final choice in ['system', ...AppLanguage.names.keys])
            ChoiceChip(
              key: ValueKey('intro-language-$choice'),
              label: Text.verbatim(choice == 'system' ? tr('Device language') : AppLanguage.names[choice]!),
              selected: AppLanguage.instance.choice == choice,
              onSelected: (_) => AppLanguage.instance.choose(choice),
            ),
        ]),
      ),
      if (theme != null) ...[
        const SizedBox(height: 20),
        Text('Colour', style: label),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: theme,
          builder: (context, _) => ColorSwatches(keyPrefix: 'intro-accent', selected: theme.accent, onPick: theme.setAccent),
        ),
      ],
      const SizedBox(height: 20),
      Text('Try your pen', style: label),
      const SizedBox(height: 4),
      Text('Write or draw in the box with the pen, a finger or the mouse.', style: hint),
      const SizedBox(height: 8),
      const PenTestPad(),
      if (stylus != null) ...[
        const SizedBox(height: 16),
        ListenableBuilder(
          listenable: stylus,
          builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('What a finger does', style: label),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final mode in FingerMode.values)
                ChoiceChip(
                  key: ValueKey('intro-finger-${mode.name}'),
                  label: Text(mode.label),
                  selected: stylus.fingers == mode,
                  onSelected: (_) => stylus.setFingers(mode),
                ),
            ]),
            const SizedBox(height: 4),
            Text(
              switch (stylus.fingers) {
                FingerMode.auto => 'Once the pen has been used, fingers only scroll and zoom, so that a resting hand does not write.',
                FingerMode.scroll => 'Fingers never write; only the pen (or a mouse) does.',
                FingerMode.draw => 'Fingers write too, also when a pen is in use.',
              },
              style: hint,
            ),
          ]),
        ),
      ],
    ]);
  }
}

/// A box to scribble in. It records the pointers that touch it, draws their lines and says what kind they were.
class PenTestPad extends StatefulWidget {
  const PenTestPad({super.key});

  @override
  State<PenTestPad> createState() => _PenTestPadState();
}

class _PenTestPadState extends State<PenTestPad> {
  final List<List<Offset>> _lines = [];
  final Set<PointerDeviceKind> _seen = {};
  final Set<double> _pressures = {};

  void _down(PointerDownEvent e) => setState(() {
        _seen.add(e.kind);
        _lines.add([e.localPosition]);
      });

  void _move(PointerMoveEvent e) {
    if (_lines.isEmpty) return;
    setState(() {
      _lines.last.add(e.localPosition);
      if (e.kind == PointerDeviceKind.stylus && e.pressureMax > e.pressureMin) _pressures.add((e.pressure * 20).roundToDouble());
    });
  }

  String get _result {
    if (_seen.isEmpty) return '';
    if (_seen.contains(PointerDeviceKind.stylus) || _seen.contains(PointerDeviceKind.invertedStylus)) {
      return _pressures.length > 2 ? 'A pen was found, and it tells how hard it presses.' : 'A pen was found.';
    }
    if (_seen.contains(PointerDeviceKind.touch)) return 'A finger was found. If you have a pen, try it too.';
    return 'A mouse was found.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          key: const ValueKey('intro-pen-pad'),
          height: 140,
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(12)),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            child: CustomPaint(painter: _PadPainter(_lines, scheme.onSurface), size: Size.infinite),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: Text(
            _result.isEmpty ? '' : _result,
            key: const ValueKey('intro-pen-result'),
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
        if (_lines.isNotEmpty)
          TextButton(
            key: const ValueKey('intro-pen-clear'),
            onPressed: () => setState(_lines.clear),
            child: const Text('Clear'),
          ),
      ]),
    ]);
  }
}

class _PadPainter extends CustomPainter {
  final List<List<Offset>> lines;
  final Color color;

  _PadPainter(this.lines, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final line in lines) {
      if (line.length == 1) {
        canvas.drawCircle(line.first, 1.5, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        continue;
      }
      final path = Path()..moveTo(line.first.dx, line.first.dy);
      for (final p in line.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}

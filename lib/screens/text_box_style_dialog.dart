import '../style/color_names.dart';
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../models/canvas_models.dart';
import 'color_wheel_dialog.dart';
import '../style/platform_dialog.dart';

const _fills = [
  Colors.white,
  Color(0xFFFFF59D),
  Color(0xFFBBDEFB),
  Color(0xFFC8E6C9),
  Color(0xFFF8BBD0),
  Color(0xFFE0E0E0),
  Color(0xFF37474F),
  Colors.black,
];
const _borders = [
  Color(0xFFBDBDBD),
  Colors.black,
  Color(0xFF1565C0),
  Color(0xFFC62828),
  Color(0xFF2E7D32),
  Color(0xFFEF6C00),
];
const _texts = [
  Color(0xDD000000),
  Colors.white,
  Color(0xFF0D47A1),
  Color(0xFFB71C1C),
  Color(0xFF1B5E20),
];

/// Changes the look of a text box while the box stays in view: every change
/// goes to [onChanged] at once.
class TextBoxStyleDialog extends StatefulWidget {
  final TextBoxStyle initial;
  final ValueChanged<TextBoxStyle> onChanged;

  const TextBoxStyleDialog({super.key, required this.initial, required this.onChanged});

  @override
  State<TextBoxStyleDialog> createState() => _TextBoxStyleDialogState();
}

class _TextBoxStyleDialogState extends State<TextBoxStyleDialog> {
  late TextBoxStyle _style = widget.initial;

  void _set(TextBoxStyle s) {
    setState(() => _style = s);
    widget.onChanged(s);
  }

  Widget _swatches(String keyPrefix, List<Color> colors, Color selected, ValueChanged<Color> pick) {
    Widget dot(Color c, {VoidCallback? onTap, Widget? child, Key? key}) => Semantics(
        button: true,
        selected: child == null && c.toARGB32() == selected.toARGB32(),
        label: child == null ? colorName(c) : null,
        child: InkWell(
          key: key,
          customBorder: const CircleBorder(),
          onTap: onTap ?? () => pick(c),
          child: Container(
            width: 30,
            height: 30,
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: child == null ? c : null,
              shape: BoxShape.circle,
              border: Border.all(
                color: c.toARGB32() == selected.toARGB32() && child == null
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black26,
                width: c.toARGB32() == selected.toARGB32() && child == null ? 3 : 1,
              ),
            ),
            child: child,
          ),
        ));
    return Wrap(children: [
      for (final c in colors) dot(c, key: ValueKey('$keyPrefix-${c.toARGB32()}')),
      dot(
        selected,
        key: ValueKey('$keyPrefix-wheel'),
        child: const Icon(Icons.palette_outlined, size: 18),
        onTap: () async {
          final picked = await pickColorOnWheel(context, selected);
          if (picked != null) pick(picked);
        },
      ),
    ]);
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> change, {Key? key, String? text}) =>
      Row(children: [
        SizedBox(width: 86, child: Text(label)),
        Expanded(child: Slider.adaptive(key: key, value: value.clamp(min, max), min: min, max: max, onChanged: change)),
        SizedBox(width: 44, child: Text.verbatim(text ?? value.toStringAsFixed(0), textAlign: TextAlign.end)),
      ]);

  @override
  Widget build(BuildContext context) {
    final header = Theme.of(context).textTheme.titleSmall;
    return PlatformAlertDialog(
      title: const Text('Text box style'),
      // the box behind stays visible and changes as you go
      scrollable: true,
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // a preview on a checkerboard-ish grey, to see what see-through means
          Container(
            height: 70,
            width: double.infinity,
            decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(6)),
            alignment: Alignment.center,
            child: Container(
              key: const ValueKey('style-preview'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: _style.fill,
                borderRadius: BorderRadius.circular(_style.radius),
                border: _style.borderWidth > 0 ? Border.all(color: _style.borderColor, width: _style.borderWidth) : null,
              ),
              child: Text('Some text', style: TextStyle(color: _style.textColor, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 12),
          Text('Background', style: header),
          _swatches('fill', _fills, _style.background, (c) => _set(_style.copyWith(background: c))),
          _slider('Opacity', _style.opacity * 100, 0, 100, (v) => _set(_style.copyWith(opacity: v / 100)),
              key: const ValueKey('style-opacity'), text: '${(_style.opacity * 100).round()}%'),
          const SizedBox(height: 8),
          Text('Border', style: header),
          _swatches('border', _borders, _style.borderColor, (c) => _set(_style.copyWith(borderColor: c))),
          _slider('Thickness', _style.borderWidth, 0, 8, (v) => _set(_style.copyWith(borderWidth: v.roundToDouble())),
              key: const ValueKey('style-border-width'), text: _style.borderWidth == 0 ? 'none' : '${_style.borderWidth.round()}'),
          _slider('Corners', _style.radius, 0, 32, (v) => _set(_style.copyWith(radius: v.roundToDouble())),
              key: const ValueKey('style-radius')),
          const SizedBox(height: 8),
          Text('Text', style: header),
          _swatches('text', _texts, _style.textColor, (c) => _set(_style.copyWith(textColor: c))),
        ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('style-reset'),
          onPressed: _style.isDefault ? null : () => _set(TextBoxStyle.defaults),
          child: const Text('Reset'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../style/color_names.dart';

/// The colours the app offers wherever one is picked for a line, a shape or text that is drawn on a page.
const appColorPalette = [
  Colors.black,
  Color(0xFF616161),
  Colors.redAccent,
  Colors.orange,
  Colors.amber,
  Colors.green,
  Colors.teal,
  Colors.blueAccent,
  Colors.indigo,
  Colors.purple,
  Colors.pinkAccent,
  Colors.white,
];

/// A row of round colour swatches: [colors] (the app's palette by default), then the user's own [extra] ones, and a button for
/// any other colour when [onMore] is given. The picked one has a ring in the theme's colour.
class ColorSwatches extends StatelessWidget {
  final Color? selected;
  final ValueChanged<Color> onPick;
  final List<Color> colors;
  final List<Color> extra;
  final VoidCallback? onMore;

  /// Names the swatches' keys (`'line'` gives `line-ff000000`) and the button's (`line-wheel`).
  final String keyPrefix;

  const ColorSwatches({
    super.key,
    required this.selected,
    required this.onPick,
    this.colors = appColorPalette,
    this.extra = const [],
    this.onMore,
    this.keyPrefix = 'line',
  });

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.primary;
    bool isSelected(Color c) => selected != null && selected!.toARGB32() == c.withValues(alpha: selected!.a).toARGB32();
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final c in [...colors, ...extra])
        Semantics(
          button: true,
          selected: isSelected(c),
          label: colorName(c),
          child: GestureDetector(
            key: ValueKey('$keyPrefix-${c.toARGB32().toRadixString(16)}'),
            onTap: () => onPick(c),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(color: isSelected(c) ? ring : Colors.grey.shade400, width: isSelected(c) ? 3 : 1),
              ),
            ),
          ),
        ),
      if (onMore != null)
        IconButton(
          key: ValueKey('$keyPrefix-wheel'),
          visualDensity: VisualDensity.compact,
          tooltip: tr('Another color'),
          icon: const Icon(Icons.add_circle_outline),
          onPressed: onMore,
        ),
    ]);
  }
}

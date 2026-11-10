import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../models/color_harmony.dart';

/// What the harmony dialog decided: the colour to draw in now, and the colours to keep on the bar.
typedef HarmonyChoice = ({Color use, List<Color> keep});

String harmonyName(Harmony h) => switch (h) {
  Harmony.complementary => tr('Complementary'),
  Harmony.triadic => tr('Triadic'),
  Harmony.analogous => tr('Analogous'),
};

String harmonyHint(Harmony h) => switch (h) {
  Harmony.complementary => tr('Two colors opposite each other: the strongest contrast.'),
  Harmony.triadic => tr('Three colors evenly around the wheel: lively but balanced.'),
  Harmony.analogous => tr('Neighbours on the wheel: calm, one mood.'),
};

/// Palettes built from [base]: tap a colour to draw in it, or keep a whole palette on the bar.
Future<HarmonyChoice?> showColorHarmonies(BuildContext context, Color base) => showDialog<HarmonyChoice>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(tr('Color harmonies')),
    content: SizedBox(
      width: 340,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final h in Harmony.values) _HarmonyRow(base: base, kind: h),
          ],
        ),
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
  ),
);

class _HarmonyRow extends StatelessWidget {
  final Color base;
  final Harmony kind;

  const _HarmonyRow({required this.base, required this.kind});

  @override
  Widget build(BuildContext context) {
    final colors = harmonyOf(base, kind);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(harmonyName(kind), style: Theme.of(context).textTheme.titleSmall),
          Text(harmonyHint(kind), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final c in colors)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkResponse(
                    key: ValueKey('harmony-${kind.name}-${c.toARGB32().toRadixString(16)}'),
                    onTap: () => Navigator.pop(context, (use: c, keep: [c])),
                    radius: 24,
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
              const Spacer(),
              TextButton(
                key: ValueKey('harmony-keep-${kind.name}'),
                onPressed: () => Navigator.pop(context, (use: base, keep: colors)),
                child: Text(tr('Keep all')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

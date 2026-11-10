import 'package:flutter/material.dart';

import '../l10n/language.dart';
import '../style/platform_dialog.dart';

/// The colours found in a picture: a tap on one chooses it, "Add all" keeps them all; the dialog answers with the colours chosen
/// (the first is the one to draw with), or null.
class PaletteDialog extends StatelessWidget {
  final List<Color> colours;

  const PaletteDialog({super.key, required this.colours});

  @override
  Widget build(BuildContext context) {
    return PlatformAlertDialog(
      title: Text(tr('Colours of the picture')),
      content: colours.isEmpty
          ? Text(tr('No colours could be taken from this picture.'))
          : Wrap(spacing: 10, runSpacing: 10, children: [
              for (final (i, c) in colours.indexed)
                InkWell(
                  key: ValueKey('palette-color-$i'),
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.pop(context, [c]),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 2)),
                  ),
                ),
            ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        if (colours.length > 1) FilledButton(key: const ValueKey('palette-add-all'), onPressed: () => Navigator.pop(context, colours), child: Text(tr('Add all'))),
      ],
    );
  }
}

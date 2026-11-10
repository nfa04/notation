import 'package:flutter/material.dart' hide Text;

import '../features/feature.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// Every tool of the app with a switch, in groups. [selected] says which are on; [onChanged] is told of a change.
class ToolList extends StatelessWidget {
  final Set<Feature> selected;
  final void Function(Feature feature, bool on) onChanged;

  const ToolList({super.key, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final group in FeatureGroup.values) ...[
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(group.title, style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary)),
        ),
        for (final f in Feature.values.where((f) => f.group == group))
          SwitchListTile.adaptive(
            key: ValueKey('tool-${f.name}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            secondary: Icon(f.icon, size: 22),
            title: Text(f.title),
            subtitle: Text(f.description, style: const TextStyle(fontSize: 12)),
            value: selected.contains(f),
            onChanged: (v) => onChanged(f, v),
          ),
      ],
    ]);
  }
}

/// The uses to choose from, as chips: which ones are chosen and what happens on tapping one.
class UseAreaChips extends StatelessWidget {
  final Set<UseArea> chosen;
  final void Function(UseArea area, bool chosen) onChanged;

  const UseAreaChips({super.key, required this.chosen, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final a in UseArea.values)
        Tooltip(
          message: tr(a.description),
          child: FilterChip(
            key: ValueKey('area-${a.name}'),
            avatar: Icon(a.icon, size: 18),
            label: Text(a.title),
            selected: chosen.contains(a),
            onSelected: (v) => onChanged(a, v),
          ),
        ),
    ]);
  }
}

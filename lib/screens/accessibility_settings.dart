import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/accessibility.dart';

/// Settings for seeing and using the app comfortably: the size of the text, contrast, motion and the size of what is tapped.
class AccessibilitySettingsCard extends StatelessWidget {
  final AccessibilitySettings settings;
  const AccessibilitySettingsCard({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Accessibility', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'On top of what the system already offers: its text size, bold text and reduced motion are followed too.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Text('Text size'),
          Expanded(
            child: Slider.adaptive(
              key: const ValueKey('a11y-text-scale'),
              value: settings.textScale,
              min: AccessibilitySettings.minScale,
              max: AccessibilitySettings.maxScale,
              divisions: 12,
              label: '${(settings.textScale * 100).round()}%',
              semanticFormatterCallback: (v) => tr('{n} percent', {'n': (v * 100).round()}),
              onChanged: settings.setTextScale,
            ),
          ),
          SizedBox(width: 48, child: Text.verbatim('${(settings.textScale * 100).round()}%')),
        ]),
        Text('The quick brown fox jumps over the lazy dog.', key: const ValueKey('a11y-preview')),
        SwitchListTile.adaptive(
          key: const ValueKey('a11y-contrast'),
          contentPadding: EdgeInsets.zero,
          title: const Text('More contrast'),
          subtitle: const Text('Stronger colours and lines.'),
          value: settings.highContrast,
          onChanged: settings.setHighContrast,
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('a11y-bold'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Bold text'),
          value: settings.boldText,
          onChanged: settings.setBoldText,
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('a11y-motion'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Reduce motion'),
          subtitle: const Text('No sliding between screens.'),
          value: settings.reduceMotion,
          onChanged: settings.setReduceMotion,
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('a11y-targets'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Bigger buttons'),
          subtitle: const Text('More room around what you tap.'),
          value: settings.bigTargets,
          onChanged: settings.setBigTargets,
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('a11y-roomy'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Roomier text'),
          subtitle: const Text('More space between lines, words and letters.'),
          value: settings.roomyText,
          onChanged: settings.setRoomyText,
        ),
        if (settings.changed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('a11y-reset'),
              onPressed: () {
                settings.setTextScale(1);
                settings.setHighContrast(false);
                settings.setBoldText(false);
                settings.setReduceMotion(false);
                settings.setBigTargets(false);
                settings.setRoomyText(false);
              },
              child: const Text('Back to the usual'),
            ),
          ),
      ]),
    );
  }
}

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

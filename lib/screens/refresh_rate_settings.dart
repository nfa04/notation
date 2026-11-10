import 'package:flutter/material.dart' hide Text;

import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/refresh_rate.dart';

/// The refresh rate of the screen: the fastest it can do (off unless turned on), and the battery level below which that stops.
class RefreshRateSettings extends StatefulWidget {
  final NoteRepository repository;
  const RefreshRateSettings({super.key, required this.repository});

  @override
  State<RefreshRateSettings> createState() => _RefreshRateSettingsState();
}

class _RefreshRateSettingsState extends State<RefreshRateSettings> {
  bool _on = false;
  int? _below; // null: never

  @override
  void initState() {
    super.initState();
    () async {
      final on = await widget.repository.settings.get(highRefreshSetting) == '1';
      final below = int.tryParse(await widget.repository.settings.get(highRefreshBatterySetting) ?? '');
      if (mounted) {
        setState(() {
          _on = on;
          _below = below;
        });
      }
    }();
  }

  Future<void> _save() async {
    await widget.repository.settings.set(highRefreshSetting, _on ? '1' : '0');
    await widget.repository.settings.set(highRefreshBatterySetting, _below?.toString() ?? '');
    await applyRefreshRate(widget.repository.settings.get);
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile.adaptive(
        key: const ValueKey('high-refresh'),
        contentPadding: EdgeInsets.zero,
        title: Text(tr('High refresh rate')),
        subtitle: Text(tr('Asks the screen for the fastest refresh rate it has (90 or 120 Hz on some devices): scrolling and drawing look smoother, and the battery lasts less. Android may still slow it down, for example in battery saver.')),
        value: _on,
        onChanged: (v) {
          setState(() => _on = v);
          _save();
        },
      ),
      const SizedBox(height: 4),
      Text('Turn it off when the battery is below', style: _on ? null : muted),
      const SizedBox(height: 6),
      DropdownMenu<int?>(
        key: const ValueKey('high-refresh-battery'),
        enabled: _on,
        initialSelection: _below,
        onSelected: (v) {
          setState(() => _below = v);
          _save();
        },
        dropdownMenuEntries: [
          DropdownMenuEntry(value: null, label: tr('Never')),
          for (final p in highRefreshBatteryChoices) DropdownMenuEntry(value: p, label: tr('{n} %', {'n': p})),
        ],
      ),
    ]);
  }
}

import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../data/settings_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../widgets/paper.dart';

/// The places the bar at the foot of a phone can hold, with the ones it starts with.
const phoneNavChoices = <int, ({IconData icon, String label})>{
  0: (icon: Symbols.home, label: 'Dashboard'),
  1: (icon: Symbols.folder, label: 'Folders'),
  6: (icon: Symbols.search, label: 'Search'),
  9: (icon: Symbols.auto_awesome, label: 'Assistant'),
  2: (icon: Symbols.calendar_month, label: 'Calendar'),
  10: (icon: Symbols.school, label: 'Learning hub'),
  8: (icon: Symbols.hub, label: 'Graph'),
  4: (icon: Symbols.bolt, label: 'Automations'),
};

const defaultPhoneNav = [0, 1, 6, 9];
const phoneNavKey = 'phone_nav';

/// The places in the bar at the foot of a phone, in order; changes of them tell the shell through [phoneNavItems].
final ValueNotifier<List<int>> phoneNavItems = ValueNotifier(defaultPhoneNav);

List<int> decodePhoneNav(String? saved) {
  final ids = [for (final p in (saved ?? '').split(',')) if (int.tryParse(p) != null && phoneNavChoices.containsKey(int.parse(p))) int.parse(p)];
  return ids.length < 2 ? defaultPhoneNav : ids.take(5).toList();
}

/// Settings: which places the bar at the foot of a phone holds (two to five).
class PhoneNavSettings extends StatefulWidget {
  final SettingsRepository settings;

  const PhoneNavSettings({super.key, required this.settings});

  @override
  State<PhoneNavSettings> createState() => _PhoneNavSettingsState();
}

class _PhoneNavSettingsState extends State<PhoneNavSettings> {
  @override
  void initState() {
    super.initState();
    widget.settings.get(phoneNavKey).then((v) {
      if (mounted) phoneNavItems.value = decodePhoneNav(v);
    });
  }

  Future<void> _toggle(int id, bool on) async {
    final now = [...phoneNavItems.value];
    if (on) {
      if (now.length >= 5) return;
      now.add(id);
    } else {
      if (now.length <= 2) return;
      now.remove(id);
    }
    phoneNavItems.value = now;
    await widget.settings.set(phoneNavKey, now.join(','));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<int>>(
      valueListenable: phoneNavItems,
      builder: (context, items, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Bar at the foot of a phone', style: PaperSection.style(context)),
        const SizedBox(height: 6),
        Text('Choose two to five places. The others stay in the menu at the top left.', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in phoneNavChoices.entries)
            FilterChip(
              key: ValueKey('phone-nav-${e.key}'),
              avatar: Icon(e.value.icon, size: 18),
              label: Text.verbatim(tr(e.value.label)),
              selected: items.contains(e.key),
              onSelected: (on) => _toggle(e.key, on),
            ),
        ]),
      ]),
    );
  }
}

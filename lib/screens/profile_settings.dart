import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../features/feature.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../profile/user_profile.dart';
import 'tool_list.dart';

/// Settings: who the person is: the name others see, and the id of their own.
class ProfileSettings extends StatefulWidget {
  final UserProfile profile;

  /// Shows the intro again.
  final VoidCallback? onIntro;

  const ProfileSettings({super.key, required this.profile, this.onIntro});

  @override
  State<ProfileSettings> createState() => _ProfileSettingsState();
}

class _ProfileSettingsState extends State<ProfileSettings> {
  late final _name = TextEditingController(text: widget.profile.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.profile,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('You', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(
          'The name other people see in live sessions, on what you add to a note, and in the history of a note.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('profile-name'),
          controller: _name,
          decoration: InputDecoration(labelText: tr('Your name'), border: const OutlineInputBorder()),
          onSubmitted: widget.profile.setName,
          onTapOutside: (_) => widget.profile.setName(_name.text),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text.verbatim(tr('Your id: {id}', {'id': widget.profile.id}), key: const ValueKey('profile-id'), style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
          IconButton(
            tooltip: tr('Copy'),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => Clipboard.setData(ClipboardData(text: widget.profile.id)),
          ),
        ]),
        Text(
          'Made for you the first time the app started and kept. It tells two people with the same name apart when you work on a note together. It is not a password.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
        if (widget.onIntro != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('profile-intro'),
            onPressed: widget.onIntro,
            icon: const Icon(Icons.waving_hand_outlined, size: 18),
            label: const Text('Show the intro again'),
          ),
        ],
      ]),
    );
  }
}

/// Settings: which tools are on. Presets by what the app is used for, and a switch for every tool.
class ToolSettings extends StatelessWidget {
  final FeatureSettings features;

  const ToolSettings({super.key, required this.features});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: features,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Tools', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(
          'Switch off what you do not use and it goes away from the screens. Nothing is deleted: notes that use a tool that is off stay as they are.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.tonalIcon(
            key: const ValueKey('tools-all'),
            onPressed: features.allOn ? null : features.showAll,
            icon: const Icon(Icons.done_all, size: 18),
            label: const Text('Show everything'),
          ),
          OutlinedButton(
            key: const ValueKey('tools-basics'),
            onPressed: () => features.apply(FeaturePresets.basics),
            child: const Text('Only the basics'),
          ),
        ]),
        const SizedBox(height: 14),
        Text('Set up for what you use the app for:', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        UseAreaChips(
          chosen: features.areas,
          onChanged: (area, chosen) {
            final areas = {...features.areas};
            chosen ? areas.add(area) : areas.remove(area);
            features.apply(FeaturePresets.forAreas(areas), areas: areas);
          },
        ),
        ToolList(selected: features.enabled, onChanged: features.set),
      ]),
    );
  }
}

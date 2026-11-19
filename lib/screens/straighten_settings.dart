import 'package:flutter/material.dart' hide Text;

import '../data/note_repository.dart';
import '../l10n/text.dart';
import '../models/straighten.dart';

/// Settings: how readily a stroke drawn nearly straight is straightened, and a drawing close to a rectangle, ellipse, ... becomes
/// that shape. Notes opened after the change use it.
class StraightenSettings extends StatefulWidget {
  final NoteRepository repository;

  const StraightenSettings({super.key, required this.repository});

  @override
  State<StraightenSettings> createState() => _StraightenSettingsState();
}

class _StraightenSettingsState extends State<StraightenSettings> {
  double _looseness = 1;

  @override
  void initState() {
    super.initState();
    widget.repository.settings.get(straightenStrengthSetting).then((v) {
      if (mounted) setState(() => _looseness = straightenLooseness(v));
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Line and shape correction'),
      const SizedBox(height: 4),
      Text('How close to straight a line, or to a rectangle, ellipse, triangle or diamond a drawing, must be before it is corrected. Applies to notes opened after the change.', style: muted),
      Slider.adaptive(
        key: const ValueKey('straighten-strength'),
        value: _looseness,
        min: 0.5,
        max: 2,
        divisions: 6,
        onChanged: (v) => setState(() => _looseness = v),
        onChangeEnd: (v) => widget.repository.settings.set(straightenStrengthSetting, v.toString()),
      ),
      Row(children: [
        Text('Only neat drawings', style: muted),
        const Spacer(),
        Text('Rough drawings too', style: muted),
      ]),
    ]);
  }
}

import 'package:flutter/material.dart' hide Text;

import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../llm/onnx_acceleration_setting.dart';
import '../llm/onnx_session.dart';

/// Where the models (handwriting, maths, scans, search) run: on the processor, or on the device's own accelerator when it has one.
class AccelerationSettings extends StatefulWidget {
  final NoteRepository repository;
  const AccelerationSettings({super.key, required this.repository});

  @override
  State<AccelerationSettings> createState() => _AccelerationSettingsState();
}

class _AccelerationSettingsState extends State<AccelerationSettings> {
  bool _cpuOnly = false;
  List<String>? _found; // null: still asking

  @override
  void initState() {
    super.initState();
    () async {
      final cpu = await widget.repository.settings.get(onnxAccelerationSetting) == 'cpu';
      final found = [for (final p in await onnxAvailableAccelerators()) _label(p.name)];
      if (mounted) {
        setState(() {
          _cpuOnly = cpu;
          _found = found;
        });
      }
    }();
  }

  static String _label(String provider) => switch (provider) {
        'CORE_ML' => 'Apple Neural Engine / GPU (CoreML)',
        'NNAPI' => 'Android NPU / GPU (NNAPI)',
        _ => provider,
      };

  Future<void> _choose(bool cpuOnly) async {
    setState(() => _cpuOnly = cpuOnly);
    await widget.repository.settings.set(onnxAccelerationSetting, cpuOnly ? 'cpu' : 'auto');
    await applyOnnxAcceleration(widget.repository.settings.get);
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    final found = _found;
    final has = found != null && found.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Run models on'), style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      Text(
        found == null
            ? tr('Looking for an accelerator…')
            : has
                ? tr('Available on this device: {names}', {'names': found.join(', ')})
                : tr('This device has no accelerator the app can use: models always run on the processor.'),
        key: const ValueKey('acceleration-found'),
        style: muted,
      ),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        key: const ValueKey('acceleration-choice'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: false, enabled: has, label: Text(tr('Accelerator when available'))),
          ButtonSegment(value: true, label: Text(tr('Processor only'))),
        ],
        selected: {has ? _cpuOnly : true},
        onSelectionChanged: (v) => _choose(v.first),
      ),
      const SizedBox(height: 6),
      Text(tr('Applies to models opened from now on; restart the app to switch all of them. Models that write text word by word always use the processor.'), style: muted),
    ]);
  }
}

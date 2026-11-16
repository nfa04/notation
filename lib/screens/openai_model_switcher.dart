import 'package:flutter/material.dart' hide Text;

import '../ai/ai_service.dart';
import '../ai/openai_provider.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// A button that shows the model of an OpenAI-compatible provider and lets the user switch to any model the service
/// offers. Nothing when another provider answers. Put it wherever the AI is used.
class OpenAiModelSwitcher extends StatelessWidget {
  final AiService ai;

  /// Only the icon, for a crowded bar.
  final bool compact;

  const OpenAiModelSwitcher({super.key, required this.ai, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final p = ai.provider;
    if (p is! OpenAiProvider) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final model = p.config.model;
        final label = model.isEmpty ? tr('Choose a model') : model;
        void open() => showDialog<void>(context: context, builder: (_) => _ModelList(provider: p));
        if (compact) {
          return IconButton(
            key: const ValueKey('openai-switch-model'),
            tooltip: tr('Model: {model}', {'model': label}),
            icon: const Icon(Icons.model_training, size: 20),
            onPressed: open,
          );
        }
        return ActionChip(
          key: const ValueKey('openai-switch-model'),
          avatar: const Icon(Icons.model_training, size: 16),
          label: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: Text.verbatim(label, overflow: TextOverflow.ellipsis)),
          tooltip: tr('Switch model'),
          onPressed: open,
        );
      },
    );
  }
}

class _ModelList extends StatefulWidget {
  final OpenAiProvider provider;
  const _ModelList({required this.provider});

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  late Future<List<String>> _models = widget.provider.listModels();
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final current = widget.provider.config.model;
    return PlatformAlertDialog(
      title: Text(tr('Switch model')),
      content: SizedBox(
        width: 420,
        height: 420,
        child: FutureBuilder<List<String>>(
          future: _models,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) {
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Text.verbatim('${snap.error}'.replaceFirst('Bad state: ', '')),
                const SizedBox(height: 8),
                Text(tr('Not every service lists its models. You can still type the name in the Settings.')),
                TextButton(onPressed: () => setState(() => _models = widget.provider.listModels(refresh: true)), child: Text(tr('Try again'))),
              ]);
            }
            final all = snap.data!;
            final shown = all.where((m) => m.toLowerCase().contains(_filter.toLowerCase())).toList();
            return Column(children: [
              TextField(
                key: const ValueKey('openai-model-filter'),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Search {count} models', {'count': all.length})),
                onChanged: (v) => setState(() => _filter = v),
              ),
              Expanded(
                child: ListView(children: [
                  for (final m in shown)
                    ListTile(
                      dense: true,
                      title: Text.verbatim(m),
                      trailing: m == current ? const Icon(Icons.check, size: 18) : null,
                      onTap: () async {
                        await widget.provider.selectModel(m);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                ]),
              ),
            ]);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => setState(() => _models = widget.provider.listModels(refresh: true)), child: Text(tr('Refresh'))),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Close'))),
      ],
    );
  }
}

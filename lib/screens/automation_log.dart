import 'package:flutter/material.dart' hide Text;

import '../automations/automation.dart';
import '../automations/automation_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// The last runs of a rule: when, for which note, what it said, and a button to take back what it did where that can be done. A rule
/// that changes things by itself is trusted when it can be seen and undone.
Future<void> showAutomationLog(BuildContext context, {required AutomationService service, required Automation rule}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => SizedBox(height: MediaQuery.of(context).size.height * 0.7, child: AutomationLog(service: service, rule: rule)),
    );

class AutomationLog extends StatelessWidget {
  final AutomationService service;
  final Automation rule;

  const AutomationLog({super.key, required this.service, required this.rule});

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return tr('just now');
    if (d.inHours < 1) return tr('{n} min ago', {'n': d.inMinutes});
    if (d.inDays < 1) return tr('{n} h ago', {'n': d.inHours});
    return tr('{n} d ago', {'n': d.inDays});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final runs = service.runsOf(rule.id);
          final scheme = Theme.of(context).colorScheme;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(tr('What this rule did'), style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text.verbatim('${tr(rule.event.label)}  →  ${tr(rule.action.label)}', style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
            const Divider(),
            Expanded(
              child: runs.isEmpty
                  ? Center(child: Text(tr('It has not run yet.'), key: const ValueKey('log-empty')))
                  : ListView(children: [
                      for (final r in runs)
                        ListTile(
                          key: ValueKey('log-run-${r.at.microsecondsSinceEpoch}'),
                          title: Text.verbatim(r.title.isEmpty ? tr('(no note)') : r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text.verbatim('${_when(r.at)}: ${tr(r.result)}', maxLines: 3, overflow: TextOverflow.ellipsis),
                          isThreeLine: r.result.length > 60,
                          trailing: r.undone
                              ? Text(tr('Taken back'), style: TextStyle(color: scheme.onSurfaceVariant))
                              : r.canUndo
                                  ? OutlinedButton(
                                      key: ValueKey('log-undo-${r.at.microsecondsSinceEpoch}'),
                                      onPressed: () async {
                                        final messenger = ScaffoldMessenger.of(context);
                                        final said = await service.undo(r);
                                        messenger.showSnackBar(SnackBar(content: Text.verbatim(said)));
                                      },
                                      child: Text(tr('Take back')),
                                    )
                                  : null,
                        ),
                    ]),
            ),
          ]);
        },
      );
}

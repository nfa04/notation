import 'package:flutter/material.dart' hide Text;

import '../automations/automation_service.dart';
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// "Still relevant?": the notes that a rule asked about (see `AutomationAction.askAboutNote`), each with the answers. Nothing is
/// shown while there is nothing to ask.
class AskCard extends StatefulWidget {
  final AutomationService service;
  final NoteRepository repository;
  final ValueChanged<String> onOpenNote;

  const AskCard({super.key, required this.service, required this.repository, required this.onOpenNote});

  @override
  State<AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<AskCard> {
  final Map<String, String> _titles = {};

  Future<void> _titlesFor(Iterable<AskItem> items) async {
    var changed = false;
    for (final i in items) {
      if (_titles.containsKey(i.noteId)) continue;
      final info = await widget.repository.noteInfo(i.noteId);
      _titles[i.noteId] = info?.title ?? '';
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _answer(AskItem item, AskAnswer what) async {
    final messenger = ScaffoldMessenger.of(context);
    final said = await widget.service.answer(item.noteId, what);
    if (mounted) messenger.showSnackBar(SnackBar(content: Text.verbatim(said)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.service,
        builder: (context, _) {
          final items = widget.service.asking;
          final notice = widget.service.askNotice;
          if (items.isEmpty && notice == null) return const SizedBox.shrink();
          _titlesFor(items);
          final scheme = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Card(
              key: const ValueKey('ask-card'),
              elevation: 0,
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (items.isNotEmpty)
                    Text(items.length == 1 ? tr('Still relevant?') : tr('Still relevant? ({n} notes)', {'n': items.length}),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  if (notice != null)
                    ListTile(
                      key: const ValueKey('ask-notice'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text.verbatim(notice),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: tr('Hide'),
                        onPressed: () => setState(() => widget.service.askNotice = null),
                      ),
                    ),
                  for (final item in items.take(5)) ...[
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => widget.onOpenNote(item.noteId),
                      child: Text.verbatim(
                        (_titles[item.noteId] ?? '').isEmpty ? tr('Untitled') : _titles[item.noteId]!,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (item.reason.isNotEmpty) Text.verbatim(tr(item.reason), style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      for (final (what, label) in [
                        (AskAnswer.keep, tr('Keep')),
                        (AskAnswer.archive, tr('Archive')),
                        (AskAnswer.remind, tr('Remind me in a week')),
                        if (widget.service.canAskForCards) (AskAnswer.cards, tr('Make flashcards')),
                        (AskAnswer.later, tr('Not now')),
                      ])
                        OutlinedButton(
                          key: ValueKey('ask-${what.name}-${item.noteId}'),
                          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                          onPressed: () => _answer(item, what),
                          child: Text.verbatim(label),
                        ),
                    ]),
                  ],
                  if (items.length > 5) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(tr('and {n} more', {'n': items.length - 5}))),
                ]),
              ),
            ),
          );
        },
      );
}

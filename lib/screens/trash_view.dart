import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../data/debounced_changes.dart';
import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// The notes that were thrown away: they can be brought back, or deleted for good. What stays for [NoteRepository.purgeTrash]'s time is removed on its own.
class TrashView extends StatefulWidget {
  final NoteRepository repository;

  /// Told when notes were brought back or deleted for good (a list that shows the notes, or counts them, looks again).
  final VoidCallback? onChanged;

  const TrashView({super.key, required this.repository, this.onChanged});

  @override
  State<TrashView> createState() => _TrashViewState();
}

class _TrashViewState extends State<TrashView> {
  List<TrashedNote>? _notes;

  /// Loads again when a note is put in the trash, brought back or deleted elsewhere (an agent, a sync).
  StreamSubscription<void>? _live;

  @override
  void initState() {
    super.initState();
    _load();
    _live = debouncedChanges([widget.repository.changes]).listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final notes = await widget.repository.listTrash();
    if (mounted) setState(() => _notes = notes);
  }

  Future<bool> _ask(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: Text.verbatim(title),
          content: Text.verbatim(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('trash-confirm'), onPressed: () => Navigator.pop(context, true), child: Text.verbatim(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _forever(TrashedNote n) async {
    if (!await _ask(tr('Delete for good?'), tr('"{title}" and all its annotations will be deleted. This cannot be undone.', {'title': n.shownTitle}), tr('Delete'))) return;
    await widget.repository.deleteNote(n.id);
    await _load();
    widget.onChanged?.call();
  }

  Future<void> _empty() async {
    if (!await _ask(tr('Empty the trash?'), tr('All notes in the trash will be deleted for good. This cannot be undone.'), tr('Empty'))) return;
    await widget.repository.purgeTrash(keep: null);
    await _load();
    widget.onChanged?.call();
  }

  static String _left(DateTime deleted) {
    final days = 30 - DateTime.now().difference(deleted).inDays;
    return days <= 0 ? tr('removed soon') : trCount(days, '{n} day left', '{n} days left');
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          if (notes != null && notes.isNotEmpty)
            TextButton.icon(key: const ValueKey('trash-empty'), onPressed: _empty, icon: const Icon(Icons.delete_forever), label: const Text('Empty the trash')),
        ],
      ),
      body: notes == null
          ? const Center(child: CircularProgressIndicator.adaptive())
          : notes.isEmpty
              ? const Center(child: Text('The trash is empty. Deleted notes stay here for 30 days.'))
              : ListView(children: [
                  for (final n in notes)
                    ListTile(
                      key: ValueKey('trashed-${n.id}'),
                      leading: Icon(n.lockMode != 0 ? Icons.lock : (n.isPdf ? Icons.picture_as_pdf : Icons.description_outlined)),
                      title: Text.verbatim(n.shownTitle),
                      subtitle: Text.verbatim(_left(n.deletedAt)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          key: ValueKey('restore-${n.id}'),
                          tooltip: tr('Restore'),
                          icon: const Icon(Icons.restore),
                          onPressed: () async {
                            await widget.repository.restoreNote(n.id);
                            await _load();
                            widget.onChanged?.call();
                          },
                        ),
                        IconButton(key: ValueKey('forever-${n.id}'), tooltip: tr('Delete for good'), icon: const Icon(Icons.delete_forever), onPressed: () => _forever(n)),
                      ]),
                    ),
                ]),
    );
  }
}

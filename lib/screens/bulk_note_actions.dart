import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'folder_picker.dart';
import '../style/platform_dialog.dart';

/// Whether a click should add to a selection instead of opening (a Ctrl or Cmd click, as in a file manager).
bool get selectModifierPressed => HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

/// Asks where [ids] should go and moves them there. Returns whether they were moved.
Future<bool> moveNotesTo(BuildContext context, NoteRepository repository, List<String> ids, {String? current}) async {
  final folders = await repository.listFolders();
  if (!context.mounted) return false;
  final target = await pickFolder(
    context,
    folders: folders,
    title: trCount(ids.length, 'Move 1 note to', 'Move {n} notes to'),
    current: current,
  );
  if (target == null) return false;
  for (final id in ids) {
    await repository.moveNote(id, target.$1);
  }
  return true;
}

/// Asks, then moves [ids] to the trash. Returns whether they were trashed.
Future<bool> trashNotes(BuildContext context, NoteRepository repository, List<String> ids) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: Text.verbatim(trCount(ids.length, 'Move note to the trash?', 'Move {n} notes to the trash?')),
      content: Text.verbatim(tr('They go to the trash, where they stay for 30 days.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('bulk-confirm-delete'), onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
  if (ok != true) return false;
  for (final id in ids) {
    await repository.trashNote(id);
  }
  return true;
}

/// How many selection bars are showing; the phone's floating menu button steps aside while there is one, as it would cover the bar's close button.
final ValueNotifier<int> selectionBarsShowing = ValueNotifier(0);

/// The bar that replaces the title bar while notes are selected: how many, select all, and what can be done with them.
class SelectionBar extends StatefulWidget implements PreferredSizeWidget {
  final int count;
  final int total;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  /// Stars (true) or unstars (false) all the selected notes; the icon shows what a tap does.
  final ValueChanged<bool> onFavorite;
  final bool allFavorite;

  const SelectionBar({
    super.key,
    required this.count,
    required this.total,
    required this.onClose,
    required this.onSelectAll,
    required this.onMove,
    required this.onDelete,
    required this.onFavorite,
    required this.allFavorite,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<SelectionBar> createState() => _SelectionBarState();
}

class _SelectionBarState extends State<SelectionBar> {
  @override
  void initState() {
    super.initState();
    // not during the build that mounts this bar: the shell listening to the count is building too
    WidgetsBinding.instance.addPostFrameCallback((_) => selectionBarsShowing.value++);
    _counted = true;
  }

  bool _counted = false;

  @override
  void dispose() {
    if (_counted) WidgetsBinding.instance.addPostFrameCallback((_) => selectionBarsShowing.value--);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count, total = widget.total, onClose = widget.onClose, onSelectAll = widget.onSelectAll;
    final onMove = widget.onMove, onDelete = widget.onDelete, onFavorite = widget.onFavorite, allFavorite = widget.allFavorite;
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      leading: IconButton(key: const ValueKey('selection-close'), tooltip: tr('Stop selecting'), icon: const Icon(Icons.close), onPressed: onClose),
      title: Text.verbatim(trCount(count, '1 note selected', '{n} notes selected'), key: const ValueKey('selection-count')),
      actions: [
        IconButton(
          key: const ValueKey('selection-all'),
          tooltip: tr('Select all'),
          icon: const Icon(Icons.select_all),
          onPressed: count == total ? null : onSelectAll,
        ),
        IconButton(
          key: const ValueKey('selection-star'),
          tooltip: tr(allFavorite ? 'Remove from favourites' : 'Add to favourites'),
          icon: Icon(allFavorite ? Icons.star_rounded : Icons.star_outline_rounded),
          onPressed: count == 0 ? null : () => onFavorite(!allFavorite),
        ),
        IconButton(key: const ValueKey('selection-move'), tooltip: tr('Move to...'), icon: const Icon(Icons.drive_file_move_outline), onPressed: count == 0 ? null : onMove),
        IconButton(key: const ValueKey('selection-delete'), tooltip: tr('Delete'), icon: const Icon(Icons.delete_outline), onPressed: count == 0 ? null : onDelete),
        const SizedBox(width: 8),
      ],
    );
  }
}

import 'package:flutter/material.dart' hide Text;

import '../data/tag_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../tags/tag_names.dart';
import '../style/platform_dialog.dart';

/// Edits the tags of one note: the ones it has as chips to remove, a field to add more (with the tags already in use to pick
/// from). Saves when the dialog is confirmed.
Future<bool> editNoteTags(BuildContext context, TagRepository tags, String noteId, {String? title}) async {
  final current = await tags.tagsOf(noteId);
  final inUse = (await tags.counts()).keys.toList();
  if (!context.mounted) return false;
  final result = await showDialog<List<String>>(
    context: context,
    builder: (context) => _NoteTagsDialog(initial: current, inUse: inUse, title: title),
  );
  if (result == null) return false;
  await tags.setTags(noteId, result);
  return true;
}

class _NoteTagsDialog extends StatefulWidget {
  final List<String> initial;
  final List<String> inUse;
  final String? title;

  const _NoteTagsDialog({required this.initial, required this.inUse, this.title});

  @override
  State<_NoteTagsDialog> createState() => _NoteTagsDialogState();
}

class _NoteTagsDialogState extends State<_NoteTagsDialog> {
  late final List<String> _tags = [...widget.initial];
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _addTyped() {
    final typed = parseTags(_field.text);
    _field.clear();
    if (typed.isEmpty) return;
    setState(() {
      for (final t in typed) {
        if (!_tags.contains(t)) _tags.add(t);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = [for (final t in widget.inUse) if (!_tags.contains(t)) t];
    return PlatformAlertDialog(
      title: const Text('Tags'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.title != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text.verbatim(widget.title!, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (_tags.isEmpty)
            Text('No tags yet.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
          else
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in _tags)
                InputChip(key: ValueKey('tag-chip-$t'), label: Text.verbatim('#$t'), onDeleted: () => setState(() => _tags.remove(t))),
            ]),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('tag-field'),
            controller: _field,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr('Add a tag'),
              helperText: tr('Use / to nest, like school/maths'),
              suffixIcon: IconButton(key: const ValueKey('tag-add'), tooltip: tr('Add'), icon: const Icon(Icons.add), onPressed: _addTyped),
            ),
            onSubmitted: (_) => _addTyped(),
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final t in suggestions.take(24))
                ActionChip(
                  key: ValueKey('tag-suggestion-$t'),
                  visualDensity: VisualDensity.compact,
                  label: Text.verbatim('#$t'),
                  onPressed: () => setState(() => _tags.add(t)),
                ),
            ]),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('tags-save'),
          onPressed: () {
            _addTyped(); // what is typed but not added yet counts
            Navigator.pop(context, _tags);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Lists every tag with the number of notes under it; a tag can be renamed (to a name that exists: the two are merged) or
/// deleted. Closes when done; [onChanged] is called after each change.
Future<void> manageTags(BuildContext context, TagRepository tags, {VoidCallback? onChanged}) => showDialog<void>(
      context: context,
      builder: (context) => _ManageTagsDialog(tags: tags, onChanged: onChanged),
    );

class _ManageTagsDialog extends StatefulWidget {
  final TagRepository tags;
  final VoidCallback? onChanged;

  const _ManageTagsDialog({required this.tags, this.onChanged});

  @override
  State<_ManageTagsDialog> createState() => _ManageTagsDialogState();
}

class _ManageTagsDialogState extends State<_ManageTagsDialog> {
  List<TagNode> _tree = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tree = buildTagTree(await widget.tags.all());
    if (mounted) {
      setState(() {
        _tree = tree;
        _loaded = true;
      });
    }
  }

  Future<void> _rename(TagNode node) async {
    final name = await showDialog<String>(context: context, builder: (context) => _RenameTagDialog(initial: node.tag));
    final target = name == null ? null : normalizeTag(name);
    if (target == null || target == node.tag) return;
    await widget.tags.rename(node.tag, target);
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _delete(TagNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Delete tag?'),
        content: Text.verbatim(tr('"#{tag}" is taken off {n} notes. The notes are kept.', {'tag': node.tag, 'n': node.notes})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('tag-delete-ok'), onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.tags.delete(node.tag);
    widget.onChanged?.call();
    await _load();
  }

  List<Widget> _rows(List<TagNode> nodes) => [
        for (final n in nodes) ...[
          ListTile(
            key: ValueKey('manage-tag-${n.tag}'),
            dense: true,
            contentPadding: EdgeInsets.only(left: 8.0 + 20 * n.depth, right: 0),
            title: Text.verbatim('#${tagLeaf(n.tag)}'),
            subtitle: n.depth == 0 ? null : Text.verbatim(n.tag, style: const TextStyle(fontSize: 11)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text.verbatim('${n.notes}', style: const TextStyle(fontSize: 12)),
              IconButton(key: ValueKey('rename-tag-${n.tag}'), tooltip: tr('Rename'), icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _rename(n)),
              IconButton(key: ValueKey('delete-tag-${n.tag}'), tooltip: tr('Delete'), icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => _delete(n)),
            ]),
          ),
          ..._rows(n.children),
        ],
      ];

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Manage tags'),
        content: SizedBox(
          width: 420,
          height: 420,
          child: !_loaded
              ? const Center(child: CircularProgressIndicator.adaptive())
              : _tree.isEmpty
                  ? const Center(child: Text('No notes have tags yet.'))
                  : ListView(children: _rows(_tree)),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      );
}

class _RenameTagDialog extends StatefulWidget {
  final String initial;

  const _RenameTagDialog({required this.initial});

  @override
  State<_RenameTagDialog> createState() => _RenameTagDialogState();
}

class _RenameTagDialogState extends State<_RenameTagDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Rename tag'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(key: const ValueKey('tag-rename-field'), controller: _field, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
          const SizedBox(height: 8),
          Text('Tags nested under it are renamed with it. A name that is in use already merges the two tags.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('tag-rename-ok'), onPressed: () => Navigator.pop(context, _field.text), child: const Text('Rename')),
        ],
      );
}

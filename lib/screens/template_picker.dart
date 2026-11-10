import 'package:flutter/material.dart' hide Text;

import '../data/note_data.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../templates/templates.dart';
import '../style/platform_dialog.dart';

/// Asks which page to start a new note from and makes the note. Returns its id, or null if nothing was chosen.
Future<String?> newNoteFromTemplate(BuildContext context, TemplateService templates, {String? folderId}) async {
  final saved = await templates.saved();
  if (!context.mounted) return null;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showDialog<Object>(
    context: context,
    builder: (context) => _TemplateDialog(templates: templates, saved: saved),
  );
  if (choice == null) return null;
  try {
    if (choice is BuiltInTemplate) return await templates.createFrom(choice, folderId: folderId);
    final id = await templates.createFromSaved((choice as SavedTemplate).id, folderId: folderId);
    if (id == null) messenger.showSnackBar(SnackBar(content: Text('That template could not be opened')));
    return id;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not make the note: {error}', {'error': e}))));
    return null;
  }
}

/// Asks for a name and keeps the note as a template.
Future<void> saveNoteAsTemplate(BuildContext context, TemplateService templates, String noteId, String title) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = await showDialog<String>(context: context, builder: (_) => _NameDialog(initial: title.trim().isEmpty ? tr('Template') : title.trim()));
  if (name == null || name.trim().isEmpty) return;
  final ok = await templates.saveAsTemplate(noteId, name.trim());
  messenger.showSnackBar(SnackBar(content: Text.verbatim(ok ? tr('Saved the template "{name}"', {'name': name.trim()}) : tr('That note is gone'))));
}

class _NameDialog extends StatefulWidget {
  final String initial;
  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Save as a template'),
        content: TextField(key: const ValueKey('template-name'), controller: _name, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('template-save'), onPressed: () => Navigator.pop(context, _name.text), child: const Text('Save')),
        ],
      );
}

class _TemplateDialog extends StatefulWidget {
  final TemplateService templates;
  final List<SavedTemplate> saved;
  const _TemplateDialog({required this.templates, required this.saved});

  @override
  State<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends State<_TemplateDialog> {
  late List<SavedTemplate> _saved = widget.saved;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: const Text('New note from a template'),
      content: SizedBox(
        width: 460,
        child: ListView(shrinkWrap: true, children: [
          for (final t in widget.templates.builtIn)
            ListTile(
              key: ValueKey('template-${t.id}'),
              leading: Icon(t.icon, color: scheme.primary),
              title: Text.verbatim(t.name),
              subtitle: Text.verbatim(t.about),
              onTap: () => Navigator.pop(context, t),
            ),
          if (_saved.isNotEmpty) ...[
            const Divider(),
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: Text('Your templates', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold))),
            for (final t in _saved)
              ListTile(
                key: ValueKey('saved-template-${t.id}'),
                leading: const Icon(Icons.bookmark_outline),
                title: Text.verbatim(t.name),
                onTap: () => Navigator.pop(context, t),
                trailing: IconButton(
                  key: ValueKey('remove-template-${t.id}'),
                  tooltip: tr('Remove this template'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await widget.templates.remove(t.id);
                    if (mounted) setState(() => _saved = [for (final s in _saved) if (s.id != t.id) s]);
                  },
                ),
              ),
          ],
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

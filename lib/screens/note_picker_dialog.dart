import 'package:flutter/material.dart' hide Text;

import '../data/note_data.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// Asks which note, from a list that can be narrowed by typing. Returns the id.
class NotePickerDialog extends StatefulWidget {
  final List<NoteSummary> notes;
  final String title;
  const NotePickerDialog({super.key, required this.notes, this.title = 'Open beside this note'});

  @override
  State<NotePickerDialog> createState() => _NotePickerDialogState();
}

class _NotePickerDialogState extends State<NotePickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final n in widget.notes)
        if (_query.isEmpty || n.title.toLowerCase().contains(_query.toLowerCase())) n,
    ];
    return PlatformAlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(children: [
          TextField(
            key: const ValueKey('note-picker-search'),
            autofocus: true,
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Find a note'), border: const OutlineInputBorder(), isDense: true),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('No notes.'))
                : ListView(children: [
                    for (final n in shown)
                      ListTile(
                        key: ValueKey('pick-note-${n.id}'),
                        dense: true,
                        leading: Icon(n.locked ? Icons.lock_outline : (n.isPdf ? Icons.picture_as_pdf_outlined : Icons.note_alt_outlined)),
                        title: Text.verbatim(n.shownTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, n.id),
                      ),
                  ]),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

part of 'fixed_page_note_editor.dart';

/// Showing a second note beside this one.
extension _EditorSplit on _FixedPageNoteEditorState {
  Future<void> _chooseNoteBeside() async {
    final notes = await widget.repository.listNotes();
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => NotePickerDialog(notes: [for (final n in notes) if (n.id != widget.noteId) n]),
    );
    if (picked != null) widget.onOpenBeside?.call(picked);
  }
}

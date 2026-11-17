part of 'fixed_page_note_editor.dart';

/// The whole note as Markdown (see `note_markdown.dart`): the written document and every page's texts, handwriting readings and
/// formulas in reading order; pictures go along as files in a ZIP.
extension _EditorMarkdownExport on _FixedPageNoteEditorState {
  Future<void> _exportNoteMarkdown() async {
    try {
      _setLoadingPdf(true);
      await _saveNow();
      final note = await widget.repository.loadNote(widget.noteId);
      if (note == null || !mounted) {
        if (mounted) _setLoadingPdf(false);
        return;
      }
      final text = widget.repository.text;
      final made = await noteToMarkdown(
        note,
        handwriting: await text.inkTexts(widget.noteId),
        formulas: await text.inkFormulas(widget.noteId),
        readPicture: (path) async {
          try {
            return await File(path).readAsBytes();
          } catch (_) {
            return null;
          }
        },
        document: _hasDocument ? _documentController.text : null,
      );
      if (!mounted) return;
      _setLoadingPdf(false);
      final name = _safeFileName(_titleController.text);
      final packed = made.pack(name);
      final target = _exportTo;
      if (target != null) {
        await File(target).writeAsBytes(packed.bytes);
        return;
      }
      final savePath = await saveWithDialog(dialogTitle: tr('Export as Markdown'), fileName: '$name.${packed.extension}', extension: packed.extension, bytes: packed.bytes);
      if (savePath == null || !mounted) return;
      final inked = made.handwriting;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text.verbatim(
          tr('Successfully exported to {path}', {'path': savePath}) +
              (inked == 0 ? '' : ' ${tr('Handwriting is in it as read by the app: check it. Drawings are not in it.')}'),
        ),
      ));
    } catch (e) {
      _exportError = '$e';
      if (mounted) {
        _setLoadingPdf(false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not export the document: {error}', {'error': e}))));
      }
    }
  }
}

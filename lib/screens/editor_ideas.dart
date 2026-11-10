part of 'fixed_page_note_editor.dart';

/// Ideas from the assistant: a palette for a mood or a subject (kept among the person's colours), or ideas to start from (put on the
/// page as a text box).
extension _EditorIdeas on _FixedPageNoteEditorState {
  Future<void> _openIdeas() async {
    final ai = widget.ai;
    if (ai == null || ai.provider == null) return;
    final answer = await showIdeasDialog(context, ai);
    if (answer == null || !mounted) return;
    if (answer.colours.isNotEmpty) await _keepColours(answer.colours);
    final text = answer.text;
    if (text != null && text.trim().isNotEmpty) _addAnswerToNote(text.trim());
  }
}

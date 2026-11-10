import 'package:flutter/widgets.dart' show TextEditingValue, TextSelection;

/// An `@` typed in some text, with what follows it: the start of a link to
/// another note, [query] being the part of the title typed so far.
class Mention {
  /// Where the `@` is.
  final int start;
  final String query;

  const Mention(this.start, this.query);
}

final _mention = RegExp(r'(^|\s)@([^\s@\[\]()]*)$');

/// The mention being typed at the cursor, or null. The `@` must start the text
/// or follow a space, so addresses like `a@b.c` are left alone.
Mention? mentionAt(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final before = value.text.substring(0, sel.baseOffset.clamp(0, value.text.length));
  final m = _mention.firstMatch(before);
  if (m == null) return null;
  return Mention(m.start + m.group(1)!.length, m.group(2)!);
}

/// `[title](note:id)`, the way a link to a note is written.
String noteLink(String id, String title) {
  final label = title.trim().isEmpty ? 'Untitled' : title.trim().replaceAll('[', '(').replaceAll(']', ')');
  return '[$label](note:$id)';
}

/// [value] with the mention replaced by a link to the note, and the cursor after it.
TextEditingValue withNoteLink(TextEditingValue value, Mention mention, String id, String title) {
  final end = value.selection.baseOffset;
  final link = '${noteLink(id, title)} ';
  final text = value.text.replaceRange(mention.start, end, link);
  return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: mention.start + link.length));
}

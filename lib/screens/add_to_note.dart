import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';

/// Where text that the AI made goes in the note.
enum AddTarget {
  /// A text box on the page in view.
  textBox,

  /// The end of the written document, under a heading when it has a title.
  document,

  /// The end of the written document, after a page break: a page of its own.
  page,

  /// Not in the note's pages or text at all: kept beside them, with the note, where the "Made by the AI" panel lists it.
  keep,
}

/// What a text kept with the note is stored as (see `NoteAiRepository`): the key is when it was kept.
const keptKind = 'saved';

/// Puts [text] in the note at [target]; [title] is what it is (a heading in the written document).
typedef AddToNote = void Function(String text, AddTarget target, {String? title});

/// The button "Add to the note": it asks where (a text box, the written document, a page of its own) and calls [onSelected].
class AddToNoteMenu extends StatelessWidget {
  final ValueChanged<AddTarget> onSelected;

  /// What the button looks like; null: an icon.
  final Widget? child;
  final Key? buttonKey;

  /// Whether keeping it apart from the note is offered (not for what is kept anyway, like a summary).
  final bool canKeep;

  const AddToNoteMenu({super.key, required this.onSelected, this.child, this.buttonKey, this.canKeep = true});

  @override
  Widget build(BuildContext context) => PopupMenuButton<AddTarget>(
        key: buttonKey,
        tooltip: tr('Add to the note'),
        onSelected: onSelected,
        itemBuilder: (_) => [
          if (canKeep) PopupMenuItem(key: const ValueKey('add-target-keep'), value: AddTarget.keep, child: _item(Icons.bookmark_add_outlined, 'Keep with the note, apart from its pages')),
          PopupMenuItem(key: const ValueKey('add-target-document'), value: AddTarget.document, child: _item(Icons.article_outlined, 'At the end of the written document')),
          PopupMenuItem(key: const ValueKey('add-target-page'), value: AddTarget.page, child: _item(Icons.insert_page_break_outlined, 'On a page of its own')),
          PopupMenuItem(key: const ValueKey('add-target-textBox'), value: AddTarget.textBox, child: _item(Icons.text_fields, 'As a text box on the page')),
        ],
        icon: child == null ? const Icon(Icons.note_add_outlined, size: 16) : null,
        padding: EdgeInsets.zero,
        child: child,
      );

  static Widget _item(IconData icon, String label) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 10), Expanded(child: Text(label))]),
      );
}

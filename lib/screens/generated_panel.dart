import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../ai/note_ai.dart';
import '../data/note_data.dart';
import '../data/note_ai_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'add_to_note.dart';

/// What the AI made of this note and kept with it (a summary, a study guide, slides, a quiz, action items), beside the page: read it
/// here, put it in the note (a text box, the written document, a page of its own), copy it, or open it where it can be used (slides,
/// quiz). What is not made yet is offered to be made.
class GeneratedPanel extends StatefulWidget {
  final NoteAiRepository store;
  final NoteAi? noteAi;
  final String noteId;

  /// Counts up when something was made, changed or removed, so that the list is read again.
  final ValueListenable<int> changed;

  /// Puts text in the note.
  final AddToNote onAdd;

  /// Opens [kind] where it is shown (and made, if it is not made yet).
  final void Function(NoteAiKind kind) onOpen;
  final VoidCallback? onClose;

  const GeneratedPanel({super.key, required this.store, this.noteAi, required this.noteId, required this.changed, required this.onAdd, required this.onOpen, this.onClose});

  /// The kinds whose result is text, which can be read in the panel and put in the note.
  static bool isText(NoteAiKind kind) => kind == NoteAiKind.summary || kind == NoteAiKind.studyGuide;

  @override
  State<GeneratedPanel> createState() => _GeneratedPanelState();
}

class _GeneratedPanelState extends State<GeneratedPanel> {
  List<({NoteAiRow row, bool stale})>? _rows;
  final _open = <NoteAiKind>{};
  final _openKept = <String>{};
  var _reading = 0;

  @override
  void initState() {
    super.initState();
    widget.changed.addListener(_read);
    _read();
  }

  @override
  void dispose() {
    widget.changed.removeListener(_read);
    super.dispose();
  }

  Future<void> _read() async {
    final token = ++_reading;
    final rows = await widget.store.of(widget.noteId);
    final list = <({NoteAiRow row, bool stale})>[];
    for (final r in rows) {
      var stale = false;
      try {
        stale = await widget.noteAi?.isStale(r) ?? false;
      } catch (_) {
        // (whether it is out of date is only a hint)
      }
      list.add((row: r, stale: stale));
    }
    if (mounted && token == _reading) setState(() => _rows = list);
  }

  static IconData _icon(NoteAiKind kind) => switch (kind) {
        NoteAiKind.summary => Icons.short_text,
        NoteAiKind.presentation => Icons.slideshow_outlined,
        NoteAiKind.studyGuide => Icons.menu_book_outlined,
        NoteAiKind.quiz => Icons.quiz_outlined,
        NoteAiKind.actions => Icons.checklist,
      };

  String _when(DateTime t) => '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    final made = {for (final r in rows ?? const <({NoteAiRow row, bool stale})>[]) NoteAiKind.byId(r.row.kind)};
    final anything = rows?.any((r) => r.row.kind == keptKind || NoteAiKind.byId(r.row.kind) != null) ?? false;
    return Material(
      key: const ValueKey('generated-panel'),
      color: scheme.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(children: [
            const Icon(Icons.auto_fix_high_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Made by the AI', style: Theme.of(context).textTheme.titleSmall)),
            if (widget.onClose != null) IconButton(key: const ValueKey('generated-close'), tooltip: tr('Close'), icon: const Icon(Icons.close, size: 20), onPressed: widget.onClose),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: rows == null
              ? const Center(child: CircularProgressIndicator.adaptive())
              : ListView(padding: const EdgeInsets.all(8), children: [
                  for (final r in rows) _item(context, r.row, r.stale),
                  if (!anything)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Nothing here yet. A summary, a study guide, slides, a quiz or action items can be made from the note, and an answer of the assistant can be kept with "Add to the note"; they stay with the note, apart from its pages, and show here.',
                          key: const ValueKey('generated-none'), style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  const Padding(padding: EdgeInsets.fromLTRB(8, 16, 8, 4), child: Text('Make')),
                  Wrap(spacing: 8, children: [
                    for (final kind in NoteAiKind.values)
                      if (!made.contains(kind))
                        ActionChip(
                          key: ValueKey('generated-make-${kind.id}'),
                          avatar: Icon(_icon(kind), size: 16),
                          label: Text(kind.label),
                          tooltip: tr(kind.description),
                          onPressed: () => widget.onOpen(kind),
                        ),
                  ]),
                ]),
        ),
      ]),
    );
  }

  /// The first line of a kept text, without the marks of Markdown, as its name.
  static String _nameOf(String text) {
    final line = text.split('\n').map((l) => l.replaceAll(RegExp(r'^[#>\-*\s]+'), '').replaceAll(RegExp(r'[*_`]'), '').trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.length > 60 ? '${line.substring(0, 60)}...' : line;
  }

  /// A text that was kept with the note by the person (an answer of the assistant, for one): read it, put it in the note, or throw it away.
  Widget _kept(BuildContext context, NoteAiRow row) {
    final id = row.key;
    final open = _openKept.contains(id);
    return Card(
      key: ValueKey('generated-kept-$id'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.bookmark_outline, size: 20),
          title: Text.verbatim(_nameOf(row.content), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text.verbatim(_when(row.createdAt)),
          trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => open ? _openKept.remove(id) : _openKept.add(id)),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectableText(row.content, key: ValueKey('generated-kept-text-$id')),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
            IconButton(
              key: ValueKey('generated-copy-$id'),
              tooltip: tr('Copy'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () => Clipboard.setData(ClipboardData(text: row.content)),
            ),
            AddToNoteMenu(canKeep: false, buttonKey: ValueKey('generated-add-$id'), onSelected: (target) => widget.onAdd(row.content, target)),
            IconButton(
              key: ValueKey('generated-delete-$id'),
              tooltip: tr('Remove it'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async {
                await widget.store.delete(widget.noteId, keptKind, id);
                _read();
              },
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _item(BuildContext context, NoteAiRow row, bool stale) {
    if (row.kind == keptKind) return _kept(context, row);
    final kind = NoteAiKind.byId(row.kind);
    if (kind == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = GeneratedPanel.isText(kind);
    final open = _open.contains(kind);
    return Card(
      key: ValueKey('generated-item-${kind.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          dense: true,
          leading: Icon(_icon(kind), size: 20),
          title: Text(kind.label),
          subtitle: Text.verbatim('${_when(row.createdAt)}${stale ? '  ·  ${tr('the note has changed since')}' : ''}', style: TextStyle(color: stale ? scheme.tertiary : null)),
          trailing: text ? Icon(open ? Icons.expand_less : Icons.expand_more) : null,
          onTap: text ? () => setState(() => open ? _open.remove(kind) : _open.add(kind)) : () => widget.onOpen(kind),
        ),
        if (text && open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectableText(row.content, key: ValueKey('generated-text-${kind.id}')),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
            if (text)
              IconButton(
                key: ValueKey('generated-copy-${kind.id}'),
                tooltip: tr('Copy'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () => Clipboard.setData(ClipboardData(text: row.content)),
              ),
            if (text) AddToNoteMenu(canKeep: false, buttonKey: ValueKey('generated-add-${kind.id}'), onSelected: (target) => widget.onAdd(row.content, target, title: kind.label)),
            TextButton(key: ValueKey('generated-open-${kind.id}'), onPressed: () => widget.onOpen(kind), child: Text(text ? 'Open' : 'Open it')),
          ]),
        ),
      ]),
    );
  }
}

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide Text;

import '../data/bookmark_repository.dart';
import '../data/link_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../outline/outline.dart';
import '../style/platform_dialog.dart';

/// The contents of a long note in one place: its headings, the pages the person bookmarked, and the other notes that refer to it.
/// Choosing a line jumps there.
class OutlinePanel extends StatefulWidget {
  final String noteId;
  final String noteTitle;

  /// The headings (and the outline of an imported PDF), in reading order.
  final List<OutlineEntry> contents;

  /// The bookmarks; the panel follows the list as it changes.
  final ValueListenable<List<PageBookmark>> bookmarks;
  final int pageCount;

  /// The page in view (zero-based), for the "Bookmark this page" button.
  final int currentPage;

  /// Takes the reader to a page (zero-based).
  final ValueChanged<int> onJump;

  /// Goes to a place in the written document (a heading in it: one page however long it is).
  final ValueChanged<int>? onJumpToText;

  /// Marks the page or takes the mark away.
  final Future<void> Function(int page) onToggleBookmark;
  final Future<void> Function(int page, String label) onLabelBookmark;

  /// Finds the notes that refer to this one; null hides the tab.
  final LinkRepository? links;

  /// Opens another note, at a page (zero-based) when it is known.
  final void Function(String noteId, int? page)? onOpenNote;
  final VoidCallback? onClose;

  /// Whether choosing a line shuts the panel (a sheet over the note) or leaves it open (a panel beside it).
  final bool closeOnPick;

  /// Reads the headings again; when given the panel does so when the page in view changes, and has a button for it (a panel beside
  /// the note, which stays open while the note is written).
  final Future<List<OutlineEntry>> Function()? reload;

  const OutlinePanel({
    super.key,
    required this.noteId,
    required this.noteTitle,
    required this.contents,
    required this.bookmarks,
    required this.pageCount,
    required this.currentPage,
    required this.onJump,
    this.onJumpToText,
    required this.onToggleBookmark,
    required this.onLabelBookmark,
    this.links,
    this.onOpenNote,
    this.onClose,
    this.closeOnPick = true,
    this.reload,
  });

  @override
  State<OutlinePanel> createState() => _OutlinePanelState();
}

class _OutlinePanelState extends State<OutlinePanel> {
  late List<OutlineEntry> _entries = widget.contents;

  @override
  void initState() {
    super.initState();
    if (widget.reload != null) _refresh();
  }

  @override
  void didUpdateWidget(OutlinePanel old) {
    super.didUpdateWidget(old);
    if (old.contents != widget.contents) _entries = widget.contents;
    if (old.currentPage != widget.currentPage) _refresh();
  }

  Future<void> _refresh() async {
    final reload = widget.reload;
    if (reload == null) return;
    final entries = await reload();
    if (mounted) setState(() => _entries = entries);
  }

  void _picked() {
    if (widget.closeOnPick) widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      Tab(key: const ValueKey('outline-tab-contents'), text: tr('Contents')),
      Tab(key: const ValueKey('outline-tab-bookmarks'), text: tr('Bookmarks')),
      if (widget.links != null) Tab(key: const ValueKey('outline-tab-links'), text: tr('Links')),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(children: [
            Expanded(child: Text('Outline', style: Theme.of(context).textTheme.titleMedium)),
            if (widget.reload != null) IconButton(key: const ValueKey('outline-refresh'), tooltip: tr('Read the headings again'), icon: const Icon(Icons.refresh), onPressed: _refresh),
            if (widget.onClose != null) IconButton(tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: widget.onClose),
          ]),
        ),
        TabBar(tabs: tabs),
        Expanded(
          child: TabBarView(children: [
            _contents(context),
            _bookmarks(context),
            if (widget.links != null) _LinksTab(links: widget.links!, noteId: widget.noteId, noteTitle: widget.noteTitle, onOpen: _open),
          ]),
        ),
      ]),
    );
  }

  void _jump(int page) {
    _picked();
    widget.onJump(page);
  }

  void _open(String noteId, int? page) {
    _picked();
    widget.onOpenNote?.call(noteId, page);
  }

  Widget _contents(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = tidyLevels(_entries);
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No headings yet. A line that starts with # in a text box or the document becomes a heading here.',
              textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    return ListView(children: [
      for (var i = 0; i < entries.length; i++)
        ListTile(
          key: ValueKey('outline-entry-$i'),
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + 18 * (entries[i].level - 1), right: 16),
          title: Text.verbatim(entries[i].title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: entries[i].level == 1 ? FontWeight.w600 : FontWeight.normal)),
          trailing: Text.verbatim('${entries[i].page + 1}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          onTap: () {
            final at = entries[i].at, text = widget.onJumpToText;
            if (at == null || text == null) return _jump(entries[i].page);
            _picked();
            text(at);
          },
        ),
    ]);
  }

  Widget _bookmarks(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<PageBookmark>>(
      valueListenable: widget.bookmarks,
      builder: (context, marks, _) {
        final marked = marks.any((b) => b.page == widget.currentPage);
        return ListView(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const ValueKey('bookmark-this-page'),
                icon: Icon(marked ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined, size: 18),
                label: Text.verbatim(tr(marked ? 'Remove the bookmark from page {n}' : 'Bookmark page {n}', {'n': widget.currentPage + 1})),
                onPressed: () => widget.onToggleBookmark(widget.currentPage),
              ),
            ),
          ),
          if (marks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No bookmarks yet. Mark the pages you want to come back to.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final b in marks)
            ListTile(
              key: ValueKey('bookmark-${b.page}'),
              dense: true,
              leading: const Icon(Icons.bookmark, size: 20),
              title: Text.verbatim(b.label.isEmpty ? tr('Page {n}', {'n': b.page + 1}) : b.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: b.label.isEmpty ? null : Text.verbatim(tr('Page {n}', {'n': b.page + 1})),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(key: ValueKey('bookmark-name-${b.page}'), tooltip: tr('Name'), icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _name(b)),
                IconButton(key: ValueKey('bookmark-remove-${b.page}'), tooltip: tr('Remove'), icon: const Icon(Icons.close, size: 18), onPressed: () => widget.onToggleBookmark(b.page)),
              ]),
              onTap: () => _jump(b.page),
            ),
        ]);
      },
    );
  }

  Future<void> _name(PageBookmark b) async {
    final label = await showDialog<String>(context: context, builder: (context) => _NameDialog(initial: b.label));
    if (label != null) await widget.onLabelBookmark(b.page, label);
  }
}

class _NameDialog extends StatefulWidget {
  final String initial;

  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Name the bookmark'),
        content: TextField(key: const ValueKey('bookmark-name-field'), controller: _field, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('bookmark-name-ok'), onPressed: () => Navigator.pop(context, _field.text), child: const Text('Save')),
        ],
      );
}

/// The notes that link here, and those that only write the title.
class _LinksTab extends StatefulWidget {
  final LinkRepository links;
  final String noteId;
  final String noteTitle;
  final void Function(String noteId, int? page) onOpen;

  const _LinksTab({required this.links, required this.noteId, required this.noteTitle, required this.onOpen});

  @override
  State<_LinksTab> createState() => _LinksTabState();
}

class _LinksTabState extends State<_LinksTab> {
  late final Future<(List<Backlink>, List<Backlink>)> _found = _find();

  Future<(List<Backlink>, List<Backlink>)> _find() async => (await widget.links.linksTo(widget.noteId), await widget.links.mentionsOf(widget.noteId, widget.noteTitle));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder(
      future: _found,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text.verbatim('${snap.error}', style: TextStyle(color: scheme.error))));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator.adaptive());
        final (linked, mentions) = snap.data!;
        if (linked.isEmpty && mentions.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No other note refers to this one. Type @ in a text box to link to a note.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          );
        }
        Widget row(Backlink b, String key) => ListTile(
              key: ValueKey(key),
              dense: true,
              leading: Icon(b.linked ? Icons.link : Icons.text_snippet_outlined, size: 20),
              title: Text.verbatim(b.title.trim().isEmpty ? tr('Untitled Note') : b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text.verbatim(b.page == null ? b.snippet : '${tr('Page {n}', {'n': b.page! + 1})}: ${b.snippet}', maxLines: 3, overflow: TextOverflow.ellipsis),
              onTap: () => widget.onOpen(b.noteId, b.page),
            );
        Widget heading(String text, int n) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text.verbatim('$text ($n)', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, letterSpacing: 0.4)),
            );
        return ListView(children: [
          if (linked.isNotEmpty) ...[heading(tr('Linked from'), linked.length), for (var i = 0; i < linked.length; i++) row(linked[i], 'backlink-$i')],
          if (mentions.isNotEmpty) ...[heading(tr('Mentioned without a link'), mentions.length), for (var i = 0; i < mentions.length; i++) row(mentions[i], 'mention-$i')],
        ]);
      },
    );
  }
}

part of 'fixed_page_note_editor.dart';

/// The outline of a note: its headings, bookmarked pages and the notes that link to it, in one sheet.
extension _EditorOutline on _FixedPageNoteEditorState {
  Widget _outlineButton() => ValueListenableBuilder<List<PageBookmark>>(
        valueListenable: _bookmarks,
        builder: (context, marks, _) => IconButton(
          key: const ValueKey('outline-button'),
          tooltip: tr('Outline, bookmarks and links'),
          visualDensity: VisualDensity.compact,
          icon: Icon(marks.isEmpty ? Icons.format_list_bulleted : Icons.bookmarks_outlined, size: 20, color: _outlineOpen ? Theme.of(context).colorScheme.primary : null),
          onPressed: _openOutline,
        ),
      );

  /// The outline as a panel beside the note: it stays open while the note is written, so it reads the headings again when the page in
  /// view changes (or on the button), and choosing a line does not shut it.
  Widget _outlinePanel({required VoidCallback onClose}) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: ListenableBuilder(
          listenable: _pageScroll,
          builder: (context, _) => OutlinePanel(
            key: const ValueKey('outline-panel'),
            noteId: widget.noteId,
            noteTitle: _titleController.text,
            contents: const [],
            reload: _outlineEntries,
            closeOnPick: false,
            bookmarks: _bookmarks,
            pageCount: _pageCount,
            currentPage: _pageScroll.hasClients ? _visiblePage().$1 : 0,
            onJump: _jumpToPage,
            onJumpToText: _jumpToText,
            onToggleBookmark: _toggleBookmark,
            onLabelBookmark: _labelBookmark,
            links: widget.links,
            onOpenNote: (id, at) => widget.onOpenNoteAt != null ? widget.onOpenNoteAt!(id, at) : widget.onOpenNote?.call(id),
            onClose: onClose,
          ),
        ),
      );

  /// The headings of the note in reading order: the outline of the PDF if it has one, and the headings written in the document and
  /// the text boxes, page by page.
  Future<List<OutlineEntry>> _outlineEntries() async {
    await ready;
    final entries = <OutlineEntry>[];
    final doc = _pdfDocument;
    if (doc != null) {
      try {
        void add(List<PdfOutlineNode> nodes, int level) {
          for (final n in nodes) {
            final page = n.dest?.pageNumber;
            if (page != null && n.title.trim().isNotEmpty) entries.add(OutlineEntry(n.title.trim(), level, (page - 1).clamp(0, _pageCount - 1)));
            add(n.children, level + 1);
          }
        }

        add(await doc.loadOutline(), 1);
      } catch (_) {
        // a file whose outline cannot be read has none
      }
    }
    final written = buildOutline(
      documentText: _hasDocument ? _documentController.text : '',
      documentPage: _hasDocument ? 0 : null,
      boxes: {
        for (final e in _textBoxesPerPage.entries)
          e.key: [for (final b in ([...e.value]..sort((a, b) => a.position.dy.compareTo(b.position.dy)))) b.controller.text],
      },
    );
    // by page, a page's own entries in the order they were found
    final all = [...entries, ...written];
    final order = {for (var i = 0; i < all.length; i++) all[i]: i};
    all.sort((a, b) => a.page != b.page ? a.page.compareTo(b.page) : order[a]!.compareTo(order[b]!));
    return all;
  }

  void _applyBookmarks(List<PageBookmark> marks) {
    _bookmarks.value = marks;
    final repo = widget.bookmarks;
    if (repo != null) unawaited(repo.replace(widget.noteId, marks));
  }

  Future<void> _toggleBookmark(int page) async {
    final repo = widget.bookmarks;
    if (repo == null) return;
    await repo.toggle(widget.noteId, page);
    _bookmarks.value = await repo.list(widget.noteId);
  }

  Future<void> _labelBookmark(int page, String label) async {
    final repo = widget.bookmarks;
    if (repo == null) return;
    await repo.setLabel(widget.noteId, page, label);
    _bookmarks.value = await repo.list(widget.noteId);
  }

  /// The outline beside the note on a wide screen (the button opens and shuts it), else in a sheet over it.
  Future<void> _openOutline() async {
    if (_roomForSidePanel) {
      _toggleSidePanel(_outlineOpen, () => _outlineOpen = true);
      return;
    }
    final contents = await _outlineEntries();
    if (!mounted) return;
    final page = _visiblePage().$1;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (sheet) => SizedBox(
        height: MediaQuery.of(sheet).size.height * 0.7,
        child: OutlinePanel(
          noteId: widget.noteId,
          noteTitle: _titleController.text,
          contents: contents,
          bookmarks: _bookmarks,
          pageCount: _pageCount,
          currentPage: page,
          onJump: _jumpToPage,
          onJumpToText: _jumpToText,
          onToggleBookmark: _toggleBookmark,
          onLabelBookmark: _labelBookmark,
          links: widget.links,
          onOpenNote: (id, at) => widget.onOpenNoteAt != null ? widget.onOpenNoteAt!(id, at) : widget.onOpenNote?.call(id),
          onClose: () => Navigator.pop(sheet),
        ),
      ),
    );
  }
}

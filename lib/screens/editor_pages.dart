part of 'fixed_page_note_editor.dart';

/// Moving, adding and deleting the pages of a notebook, or of the PDF a note is made from (which is rewritten with the new pages).
extension _EditorPages on _FixedPageNoteEditorState {
  /// The things placed on pages, kept by page, as they are now.
  ({
    Map<int, List<DrawingStroke>> strokes,
    Map<int, List<TextBoxWidgetModel>> boxes,
    Map<int, List<ImageItem>> images,
    Map<int, List<PdfHighlight>> highlights,
  }) _pageContents() => (
        strokes: {for (final e in _strokesPerPage.entries) e.key: List.of(e.value)},
        boxes: {for (final e in _textBoxesPerPage.entries) e.key: List.of(e.value)},
        images: {for (final e in _imagesPerPage.entries) e.key: List.of(e.value)},
        highlights: {for (final e in _highlightsPerPage.entries) e.key: List.of(e.value)},
      );

  void _setPageContents(({Map<int, List<DrawingStroke>> strokes, Map<int, List<TextBoxWidgetModel>> boxes, Map<int, List<ImageItem>> images, Map<int, List<PdfHighlight>> highlights}) c) {
    void put<T>(Map<int, List<T>> into, Map<int, List<T>> from) => into
      ..clear()
      ..addAll({for (final e in from.entries) e.key: List.of(e.value)});
    put(_strokesPerPage, c.strokes);
    put(_textBoxesPerPage, c.boxes);
    put(_imagesPerPage, c.images);
    put(_highlightsPerPage, c.highlights);
  }

  /// Gives everything on page `i` the page `to(i)` (null: it goes away), as one step to take back.
  ///
  /// [onUndo] and [onRedo] do what else goes with the step (the PDF is swapped for the one with the pages the other way).
  void _reshapePages(int? Function(int page) to, {VoidCallback? onUndo, VoidCallback? onRedo}) {
    final before = _pageContents();
    Map<int, List<T>> moved<T>(Map<int, List<T>> m) {
      final out = <int, List<T>>{};
      m.forEach((page, items) {
        final n = to(page);
        if (n != null) out.putIfAbsent(n, () => []).addAll(items);
      });
      return out;
    }

    setState(() {
      _clearSelection();
      _activeSelectedBox = null;
      _selectedImage = null;
      _setPageContents((
        strokes: moved(before.strokes),
        boxes: moved(before.boxes),
        images: moved(before.images),
        highlights: moved(before.highlights),
      ));
      final after = _pageContents();
      // the bookmarks stay on the pages they were on
      final marksBefore = _bookmarks.value, marksAfter = moveBookmarks(marksBefore, to);
      _applyBookmarks(marksAfter);
      _undoStack.push(UndoStep(
        () {
          _setPageContents(before);
          _applyBookmarks(marksBefore);
          onUndo?.call();
        },
        () {
          _setPageContents(after);
          _applyBookmarks(marksAfter);
          onRedo?.call();
        },
      ));
    });
  }

  /// Whether pages can be moved, added and deleted at all: in a notebook or a PDF, never the page with the written document, and not
  /// in a canvas.
  bool get _canShapePages => !_infinite && (_isBlank || (_pdfDocument != null && pdfContentEditingSupported));

  Future<void> _movePage(int page, int by) => _movePageTo(page, page + by);

  /// Moves page [from] to where page [to] is (the pages in between move up or down by one), as one step to take back.
  Future<void> _movePageTo(int from, int to) async {
    if (from == to || from < 0 || to < 0 || from >= _pageCount || to >= _pageCount || _isDocumentPage(from) || _isDocumentPage(to)) return;
    if (!_isBlank) {
      final order = <int?>[for (var i = 0; i < _pageCount; i++) i]
        ..removeAt(from)
        ..insert(to, from);
      return _reshapePdf(order, jumpTo: to);
    }
    _reshapePages((i) {
      if (i == from) return to;
      if (from < to && i > from && i <= to) return i - 1;
      if (from > to && i >= to && i < from) return i + 1;
      return i;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPage(to));
  }

  /// A blank page at index [at]; what was there and after moves down. In a PDF it is a notebook page (the paper of the note, not the
  /// file), as big as the page [at] is next to.
  Future<void> _insertPage(int at) async {
    if (at < 0 || _isDocumentPage(at)) return;
    if (!_isBlank) {
      final order = <int?>[for (var i = 0; i < _pageCount; i++) i]..insert(math.min(at, _pageCount), null);
      return _reshapePdf(order, jumpTo: at, blankLike: math.min(at, _pageCount - 1));
    }
    _reshapePages((i) => i >= at ? i + 1 : i);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPage(at));
  }

  Future<void> _deletePage(int page) async {
    if (_isDocumentPage(page)) return;
    if (!_isBlank) {
      // (a PDF without pages is none)
      if (_pageCount < 2) return;
      final order = <int?>[for (var i = 0; i < _pageCount; i++) if (i != page) i];
      return _reshapePdf(order, jumpTo: math.min(page, _pageCount - 2));
    }
    _reshapePages((i) => i == page ? null : (i > page ? i - 1 : i));
  }

  /// Gives the PDF of the note the pages [order] says (each the number of the page it was, null for a new blank one of the size of
  /// [blankLike]), and everything placed on the pages goes with them. One step to take back.
  Future<void> _reshapePdf(List<int?> order, {required int jumpTo, int blankLike = 0}) async {
    final oldPath = _pdfFilePath, oldSha = _pdfSha256;
    if (oldPath == null || _pdfEditBusy) return;
    setState(() => _pdfEditBusy = true);
    // a line still being typed in the PDF is put in it first
    _endPdfInlineEdit(apply: true);
    try {
      await _pdfEditWork;
      final from = _totalPages;
      final moved = await arrangePdfFile(oldPath, order, fileName: '${widget.noteId}-${DateTime.now().millisecondsSinceEpoch}.pdf', blankLike: blankLike);
      final path = moved.path, sha = moved.sha256;
      final PdfDocument doc;
      try {
        doc = await openPdfFile(path);
      } catch (_) {
        File(path).delete().catchError((Object _) => File(path));
        rethrow;
      }
      if (!mounted) {
        doc.dispose();
        return;
      }
      _pdfShaped.addAll([oldPath, path]);
      // (the states the edits of the text left have the old pages)
      _discardEditedPdfs(keep: null);
      _closePdfEditor();
      final to = {for (var n = 0; n < order.length; n++) if (order[n] != null) order[n]!: n};
      // the pages added here are notebook pages; the ones that were stay so wherever they went
      final nativeBefore = Set.of(_nativePages);
      final nativeAfter = {for (var n = 0; n < order.length; n++) if (order[n] == null || nativeBefore.contains(order[n])) n};
      _nativePages = nativeAfter;
      _reshapePages(
        (i) => to[i],
        onUndo: () {
          _nativePages = Set.of(nativeBefore);
          unawaited(_swapPdfFile(oldPath, oldSha ?? ''));
        },
        onRedo: () {
          _nativePages = Set.of(nativeAfter);
          unawaited(_swapPdfFile(path, sha));
        },
      );
      _showPdf(path, sha, doc);
      if (_mode == CanvasInteractionMode.document) unawaited(_openPdfEditor());
      _scheduleSave();
      // the others do the same to their file (what is on the pages goes to them with the other changes)
      _live?.announcePages(PageArrangement(order, from, moved.blank));
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPage(jumpTo));
    } catch (e) {
      _pdfEditMessage(e);
    } finally {
      if (mounted) setState(() => _pdfEditBusy = false);
    }
  }

  /// Gives the PDF the pages somebody else arranged in the live session (what is on the pages comes with their other changes).
  Future<void> _takeRemotePages(PageArrangement arrangement) async {
    // (one change of the PDF after the other)
    for (var i = 0; i < 100 && _pdfEditBusy && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final oldPath = _pdfFilePath;
    if (!mounted || oldPath == null || _pdfEditBusy || _totalPages != arrangement.from) return;
    setState(() => _pdfEditBusy = true);
    _endPdfInlineEdit(apply: true);
    try {
      await _pdfEditWork;
      final moved = await arrangePdfFile(oldPath, arrangement.order,
          fileName: '${widget.noteId}-${DateTime.now().millisecondsSinceEpoch}.pdf', blank: arrangement.blank);
      final doc = await openPdfFile(moved.path);
      if (!mounted) {
        doc.dispose();
        return;
      }
      _pdfShaped.addAll([oldPath, moved.path]);
      _discardEditedPdfs(keep: null);
      _closePdfEditor();
      _showPdf(moved.path, moved.sha256, doc);
      if (_mode == CanvasInteractionMode.document) unawaited(_openPdfEditor());
      _scheduleSave();
    } catch (e) {
      _pdfEditMessage(e);
    } finally {
      if (mounted) setState(() => _pdfEditBusy = false);
    }
  }

  /// Puts the PDF somebody else sent in the place of this one.
  Future<void> _takeRemotePdf(SharedPdf pdf) async {
    for (var i = 0; i < 100 && _pdfEditBusy && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final oldPath = _pdfFilePath;
    if (!mounted || oldPath == null || _pdfEditBusy) return;
    setState(() => _pdfEditBusy = true);
    _endPdfInlineEdit(apply: true);
    try {
      await _pdfEditWork;
      final path = p.join(p.dirname(oldPath), '${widget.noteId}-${DateTime.now().millisecondsSinceEpoch}.pdf');
      await File(path).writeAsBytes(pdf.bytes, flush: true);
      final PdfDocument doc;
      try {
        doc = await openPdfFile(path);
      } catch (_) {
        File(path).delete().catchError((Object _) => File(path));
        rethrow;
      }
      if (!mounted) {
        doc.dispose();
        return;
      }
      _pdfShaped.addAll([oldPath, path]);
      _discardEditedPdfs(keep: null);
      _closePdfEditor();
      _showPdf(path, pdf.sha256, doc);
      if (_mode == CanvasInteractionMode.document) unawaited(_openPdfEditor());
      _scheduleSave();
    } catch (e) {
      _pdfEditMessage(e);
    } finally {
      if (mounted) setState(() => _pdfEditBusy = false);
    }
  }

  /// Shows the file at [path] as the note's PDF, for taking back (or doing again) a change of its pages, and tells the others. Only the last asked counts.
  Future<void> _swapPdfFile(String path, String sha) async {
    final turn = ++_pdfSwapTurn;
    try {
      final doc = await openPdfFile(path);
      if (!mounted || turn != _pdfSwapTurn) {
        doc.dispose();
        return;
      }
      _closePdfEditor();
      _showPdf(path, sha, doc);
      if (_mode == CanvasInteractionMode.document) unawaited(_openPdfEditor());
      _scheduleSave();
      // the others get the file as it is now
      final live = _live;
      if (live != null) live.announcePdf(SharedPdf(_importedPdfName ?? 'document.pdf', sha, _totalPages, await File(path).readAsBytes()));
    } catch (e) {
      _pdfEditMessage(e);
    }
  }

  /// Deletes the files the PDF had before its pages were changed (all but [keep]).
  void _discardShapedPdfs({required String? keep}) {
    for (final path in _pdfShaped) {
      if (path != keep) File(path).delete().catchError((Object _) => File(path));
    }
    _pdfShaped.clear();
  }

  /// The "Pages" menu of the top bar, acting on the page in view.
  Widget _pagesMenu() {
    final page = _visiblePage().$1;
    final document = _isDocumentPage(page);
    return PopupMenuButton<VoidCallback>(
      key: const ValueKey('pages-menu'),
      tooltip: tr('Pages'),
      icon: const Icon(Icons.auto_stories_outlined, size: 20),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(value: () => _movePage(page, -1), enabled: page > 0 && !document && !_isDocumentPage(page - 1), child: Text(tr('Move page up'))),
        PopupMenuItem(value: () => _movePage(page, 1), enabled: !document && page + 1 < _pageCount, child: Text(tr('Move page down'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: () => _insertPage(page), enabled: !document, child: Text(tr('Insert a blank page before'))),
        PopupMenuItem(value: () => _insertPage(page + 1), child: Text(tr('Insert a blank page after'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: () => _deletePage(page), enabled: !document, child: Text(tr('Delete page'))),
      ],
    );
  }
}

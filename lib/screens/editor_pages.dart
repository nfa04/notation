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
  bool get _canShapePages => !_infinite && (_isBlank || _pdfTable != null || (_pdfDocument != null && pdfContentEditingSupported));

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

  /// Shows all the pages small, to drag into a new order, and does what was arranged as one step to take back.
  Future<void> _arrangePages() async {
    // (the notebook shows one empty page after the last used one: that stays the last)
    final count = _isBlank ? math.max(1, _lastUsedBlankPage + 1) : _totalPages;
    if (count < 2) return;
    final order = await showPageArrangeDialog(
      context,
      count: count,
      locked: _hasDocument ? 1 : 0,
      current: _visiblePage().$1 < count ? _visiblePage().$1 : null,
      aspect: (_isBlank ? basePageHeight : _heightOf(0)) / _paperWidth,
      thumbnail: (page) => _picturePage(page, ImagePreset.web, seeThrough: false, across: 240),
    );
    if (order == null || !mounted || order.isEmpty || order.length > count) return;
    final viewed = _visiblePage().$1;
    final left = count - order.length;
    final at = viewed < count ? (order.contains(viewed) ? order.indexOf(viewed) : math.min(viewed, order.length - 1)) : viewed - left;
    if (!_isBlank) return _reshapePdf([...order, for (var i = count; i < _pageCount; i++) i], jumpTo: at);
    final to = {for (var n = 0; n < order.length; n++) order[n]: n};
    // (a page taken out takes what is on it along; the empty page after the last stays the last)
    _reshapePages((i) => i >= count ? i - left : to[i]);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPage(at));
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
    if (_pdfTable != null) return _reshapeTable(order, jumpTo: jumpTo);
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

  /// Asks for PDFs and adds them to the note as files of their own: their pages come as page [at] and on (after the last page by default).
  /// What is on the pages from there on goes with them, and it is one step to take back.
  Future<void> _addPdfs({int? at}) async {
    if (_pdfFilePath == null || _pdfEditBusy || _isLoadingPdf) return;
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (picked.isEmpty || !mounted) return;
    final sources = <String>[];
    for (final file in picked) {
      final path = await pickedPath(file);
      if (path != null) sources.add(path);
    }
    await _addPdfFiles(sources, at: at);
  }

  /// Copies the PDF at [source] into the app's folder (the original may be moved or deleted later) and opens it.
  Future<(NotePdf, PdfDocument)> _takePdfCopy(String source) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'pdfs'));
    await dir.create(recursive: true);
    final path = p.join(dir.path, '${widget.noteId}-${DateTime.now().microsecondsSinceEpoch}.pdf');
    await File(source).copy(path);
    try {
      final sha = await sha256OfFile(path);
      final doc = await openPdfFile(path);
      return (NotePdf(name: p.basename(source), path: path, sha256: sha, pages: doc.pages.length), doc);
    } catch (_) {
      File(path).delete().catchError((Object _) => File(path));
      rethrow;
    }
  }

  /// Opens the files of [table] that are not open yet (the open ones are kept by the path they are at, until the editor closes).
  Future<void> _openTableFiles(NotePdfs table) async {
    for (final f in table.files) {
      if (_tableDocs.containsKey(f.path)) continue;
      _tableDocs[f.path] = await openPdfFile(f.path);
    }
  }

  /// Shows the PDFs of [table] (null: the one file [single], on its own as before); the files must be open (see [_openTableFiles]) unless
  /// it is [single]. What is on the pages is not touched.
  Future<void> _applyTable(NotePdfs? table, {NotePdf? single}) async {
    if (table == null) {
      final file = single!;
      final doc = await openPdfFile(file.path);
      if (!mounted) {
        doc.dispose();
        return;
      }
      _pdfTable = null;
      _closePdfEditor();
      _showPdf(file.path, file.sha256, doc);
      _importedPdfName = file.name;
      _scheduleSave();
      return;
    }
    await _openTableFiles(table);
    if (!mounted) return;
    _pdfTable = table;
    _closePdfEditor();
    _showDocument(
      NotePdfDocument.table([for (final f in table.files) _tableDocs[f.path]!], table.layout),
      also: () {
        // (the first file is the one the note's other readers know)
        final first = table.files.first;
        _importedPdfName = first.name;
        _pdfFilePath = first.path;
        _pdfSha256 = first.sha256;
      },
    );
    _scheduleSave();
  }

  /// Adds the PDFs at [sources] to the note, each as a file of its own (see [_addPdfs]). A note with one PDF becomes one with several.
  Future<void> _addPdfFiles(List<String> sources, {int? at}) async {
    final oldPath = _pdfFilePath;
    if (oldPath == null || _pdfEditBusy || sources.isEmpty) return;
    setState(() => _pdfEditBusy = true);
    _endPdfInlineEdit(apply: true);
    final taken = <NotePdf>[];
    try {
      await _pdfEditWork;
      for (final source in sources) {
        try {
          final (file, doc) = await _takePdfCopy(source);
          taken.add(file);
          _tableDocs[file.path] = doc;
        } catch (e) {
          throw StateError('${p.basename(source)}: $e');
        }
      }
      if (!mounted) return;
      final before = _pdfTable;
      final single = NotePdf(name: _importedPdfName ?? 'document.pdf', path: oldPath, sha256: _pdfSha256 ?? '', pages: _totalPages);
      final base = before ?? NotePdfs.inOrder([single]);
      final into = (at ?? base.pageCount).clamp(0, base.pageCount);
      final next = base.adding(taken, at: into);
      final brought = next.pageCount - base.pageCount;
      await _openTableFiles(next);
      if (!mounted) return;
      final nativeBefore = Set.of(_nativePages);
      final nativeAfter = {for (final n in nativeBefore) n < into ? n : n + brought};
      _nativePages = nativeAfter;
      _reshapePages(
        (i) => i < into ? i : i + brought,
        onUndo: () {
          _nativePages = Set.of(nativeBefore);
          unawaited(_applyTable(before, single: single));
        },
        onRedo: () {
          _nativePages = Set.of(nativeAfter);
          unawaited(_applyTable(next));
        },
      );
      await _applyTable(next);
      _announceTable();
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPage(into));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('{pages} pages added from {files} PDFs', {'pages': brought, 'files': taken.length}))));
      }
    } catch (e) {
      for (final file in taken) {
        _tableDocs.remove(file.path)?.dispose();
        File(file.path).delete().catchError((Object _) => File(file.path));
      }
      _pdfEditMessage(e);
    } finally {
      if (mounted) setState(() => _pdfEditBusy = false);
    }
  }

  /// Takes file number [file] out of the note with its pages (and what is drawn or written on them): one step to take back. The file is not
  /// deleted until the note is closed.
  Future<void> _removePdfFile(int file) async {
    final table = _pdfTable;
    if (table == null || table.files.length < 2 || file < 0 || file >= table.files.length || _pdfEditBusy) return;
    final name = table.files[file].name;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Remove this PDF?')),
        content: Text(tr('"{name}" and its pages are taken out of the note, with what is drawn or written on them.', {'name': name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(key: const ValueKey('remove-pdf-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Remove'))),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final next = table.removing(file);
    // (where each page that stays goes)
    final to = <int, int>{};
    var n = 0;
    for (var i = 0; i < table.layout.length; i++) {
      if (table.layout[i].file != file) to[i] = n++;
    }
    if (n == 0) return;
    final nativeBefore = Set.of(_nativePages);
    final nativeAfter = {for (final i in nativeBefore) ?to[i]};
    _nativePages = nativeAfter;
    _reshapePages(
      (i) => to[i],
      onUndo: () {
        _nativePages = Set.of(nativeBefore);
        unawaited(_applyTable(table));
      },
      onRedo: () {
        _nativePages = Set.of(nativeAfter);
        unawaited(_applyTable(next));
      },
    );
    await _applyTable(next);
    _announceTable();
    if (mounted) setState(() {});
  }

  /// Where a run of pages of one PDF starts in a note with several, a small label with its name and the number of its page (not in the
  /// way of anything: it takes no room and no touch).
  Widget? _pdfFileLabel(int page) {
    final table = _pdfTable;
    if (table == null || page < 0 || page >= table.layout.length) return null;
    final ref = table.layout[page];
    if (ref.isBlank) return null;
    if (page > 0 && table.layout[page - 1].file == ref.file) return null;
    final file = table.files[ref.file];
    return Positioned(
      left: 8,
      top: 8,
      child: IgnorePointer(
        child: DecoratedBox(
          key: ValueKey('pdf-file-label-$page'),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text.rich(
              TextSpan(children: [
                const WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(Icons.picture_as_pdf, size: 12, color: Colors.white)),
                TextSpan(text: ' ${file.name} · ${ref.page + 1}/${file.pages}'),
              ]),
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ),
      ),
    );
  }

  /// The PDFs of a note that has several: a button that lists them, to go to one or take one out.
  Widget _pdfFilesMenu() {
    final table = _pdfTable!;
    return PopupMenuButton<VoidCallback>(
      key: const ValueKey('pdf-files-menu'),
      tooltip: tr('The PDFs of this note'),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        for (var f = 0; f < table.files.length; f++)
          PopupMenuItem(
            key: ValueKey('pdf-file-$f'),
            value: () => _goToPdfFile(f),
            enabled: table.firstPageOf(f) != null,
            child: Text.rich(TextSpan(text: table.files[f].name, children: [TextSpan(text: '  ${tr('{n} pages', {'n': table.layout.where((r) => r.file == f).length})}', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant))])),
          ),
        const PopupMenuDivider(),
        for (var f = 0; f < table.files.length; f++)
          PopupMenuItem(key: ValueKey('remove-pdf-$f'), value: () => _removePdfFile(f), enabled: table.files.length > 1, child: Text(tr('Remove {name}…', {'name': table.files[f].name}))),
      ],
      child: Chip(
        avatar: const Icon(Icons.picture_as_pdf, size: 16),
        label: Text(tr('{n} PDFs ({pages} Pages)', {'n': table.files.length, 'pages': _totalPages}), style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  /// Moves the view to the first page of file number [file].
  void _goToPdfFile(int file) {
    final page = _pdfTable?.firstPageOf(file);
    if (page != null) _jumpToPage(page);
  }

  /// Gives the pages of a note with several PDFs another order (see [_reshapePdf]): [order] has for each new page the number of the page it was, null
  /// for a new blank page. Only the page table changes; the files are not touched.
  Future<void> _reshapeTable(List<int?> order, {required int jumpTo}) async {
    final table = _pdfTable;
    if (table == null || _pdfEditBusy) return;
    final next = table.withLayout([for (final i in order) i == null ? const PdfPageRef.blank() : table.layout[i]]);
    final to = {for (var n = 0; n < order.length; n++) if (order[n] != null) order[n]!: n};
    final nativeBefore = Set.of(_nativePages);
    final nativeAfter = {for (var n = 0; n < order.length; n++) if (order[n] == null || nativeBefore.contains(order[n])) n};
    _nativePages = nativeAfter;
    _reshapePages(
      (i) => to[i],
      onUndo: () {
        _nativePages = Set.of(nativeBefore);
        unawaited(_applyTable(table));
      },
      onRedo: () {
        _nativePages = Set.of(nativeAfter);
        unawaited(_applyTable(next));
      },
    );
    await _applyTable(next);
    _announceTable();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToPage(jumpTo));
  }

  /// Tells the others in a live session what the PDF is now: one PDF with the pages in the order they are shown (their copy of the note has no page table).
  void _announceTable() {
    final live = _live, table = _pdfTable;
    if (live == null || table == null) return;
    final name = _importedPdfName ?? 'document.pdf';
    unawaited(() async {
      try {
        final bytes = await combinePdfFiles(table);
        live.announcePdf(SharedPdf(name, await sha256Of(bytes), table.pageCount, bytes));
      } catch (e) {
        debugPrint('sharing the PDFs failed: $e');
      }
    }());
  }

  /// Gives the PDF the pages somebody else arranged in the live session (what is on the pages comes with their other changes).
  Future<void> _takeRemotePages(PageArrangement arrangement) async {
    // (one change of the PDF after the other)
    for (var i = 0; i < 100 && _pdfEditBusy && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final oldPath = _pdfFilePath;
    if (!mounted || oldPath == null || _pdfTable != null || _pdfEditBusy || _totalPages != arrangement.from) return;
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
    // (a note with several PDFs keeps its own: what the others share is one PDF)
    if (!mounted || oldPath == null || _pdfTable != null || _pdfEditBusy) return;
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
        PopupMenuItem(key: const ValueKey('arrange-pages'), value: _arrangePages, enabled: _pageCount > 2 || (!_isBlank && _pageCount > 1), child: Text(tr('Arrange pages…'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: () => _insertPage(page), enabled: !document, child: Text(tr('Insert a blank page before'))),
        PopupMenuItem(value: () => _insertPage(page + 1), child: Text(tr('Insert a blank page after'))),
        if (!_isBlank) PopupMenuItem(key: const ValueKey('insert-pdf-after'), value: () => _addPdfs(at: page + 1), enabled: _canShapePages, child: Text(tr('Insert PDFs after this page…'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: () => _deletePage(page), enabled: !document, child: Text(tr('Delete page'))),
      ],
    );
  }
}

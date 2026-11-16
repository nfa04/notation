part of 'fixed_page_note_editor.dart';

/// Opening a PDF, loading and previewing its pages, and highlighting or commenting on its text.
extension _EditorPdfPages on _FixedPageNoteEditorState {
  /// Small picture of a page for the scrollbar.
  /// What a stop of the scrollbar shows: a sheet of the written document as a sheet, not all of them squeezed into one.
  Widget _stopPreview(int stop) {
    final sheets = _sheetsOfDocument;
    if (sheets == 1) return _pagePreview(stop);
    if (stop >= sheets) return _pagePreview(stop - sheets + 1);
    final pieces = _readPieces.shown;
    final reading = _mode != CanvasInteractionMode.document && stop <= _docBreaks.length && _docPieceTops.isNotEmpty;
    final edges = [0.0, ..._docBreaks];
    final here = reading ? piecesBetween(_docPieceTops, edges[stop], stop + 1 < edges.length ? edges[stop + 1] : double.infinity) : null;
    return AspectRatio(
      aspectRatio: basePageWidth / basePageHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black26)),
        child: here == null || here.first >= pieces.length
            ? null
            : ClipRect(
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: basePageWidth,
                    height: basePageHeight,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(_marginLeft, _marginTop, _marginRight, _marginBottom),
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minHeight: 0,
                          maxHeight: double.infinity,
                          child: Transform.translate(
                            offset: Offset(0, here.top - edges[stop]),
                            child: LiveMarkdownView(
                              controller: _documentController,
                              fontSize: DocumentSheet.fontSize,
                              pieces: pieces.sublist(here.first, math.min(here.end, pieces.length)),
                              first: here.first,
                              ended: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _pagePreview(int index) {
    final h = _shownPageHeight(index);
    Widget picture(Widget base) => AspectRatio(
      aspectRatio: basePageWidth / h,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black26),
        ),
        child: ClipRect(
          child: Stack(fit: StackFit.expand, children: [
            base,
            // what is on the page, laid out as on the page and scaled down with it
            FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(width: basePageWidth, height: h, child: _previewContent(index, h)),
            ),
          ]),
        ),
      ),
    );
    if (_isBlank || _nativePages.contains(index)) {
      return picture(
        FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: basePageWidth,
            height: h,
            child: CustomPaint(painter: PageBackgroundPainter(_background)),
          ),
        ),
      );
    }
    // the picture of the page if it is kept, else a small one: dragging the scrollbar goes past many pages, and each used to be read
    // whole (with its text), in line before the page the drag ended on
    final kept = _pagesRead[index] ?? _thumbs[index];
    if (kept != null && kept.alive) return picture(_PageImage(data: kept, quality: FilterQuality.medium));
    return FutureBuilder<PdfPageData>(
      future: _thumbOf(index),
      builder: (context, snap) => picture(
        snap.hasData && snap.data!.alive
            ? _PageImage(data: snap.data!, quality: FilterQuality.medium)
            : const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
              ),
      ),
    );
  }

  /// Pictures, highlights, drawings and text boxes of page [index], without
  /// anything to touch.
  Widget _previewContent(int index, double h) {
    return IgnorePointer(
      child: Stack(clipBehavior: Clip.hardEdge, children: [
        for (final m in _imagesPerPage[index] ?? const <ImageItem>[])
          Positioned(
            left: m.position.dx,
            top: m.position.dy,
            width: m.size.width,
            height: m.size.height,
            child: Image.file(File(m.path), fit: BoxFit.fill, errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ),
        Positioned.fill(child: CustomPaint(painter: HighlightsPainter(highlights: _highlightsPerPage[index] ?? const [], behindText: true))),
        Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: InkLayerPainter(strokes: _strokesPerPage[index] ?? const [], layers: _layers, pressureSensitivity: widget.stylus?.effectiveSensitivity ?? 0.6, pixelScale: _inkPixelScale), isComplex: true))),
        for (final box in _textBoxesPerPage[index] ?? const <TextBoxWidgetModel>[])
          Positioned(
            left: box.position.dx,
            top: box.position.dy,
            child: Container(
              width: box.size.width,
              constraints: BoxConstraints(minHeight: box.size.height),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: box.style.fill,
                borderRadius: BorderRadius.circular(box.style.radius),
                border: box.style.borderWidth > 0
                    ? Border.all(color: box.style.borderColor, width: box.style.borderWidth)
                    : null,
              ),
              child: MarkdownView(controller: box.controller, fontSize: box.fontSize, textColor: box.style.textColor),
            ),
          ),
      ]),
    );
  }

  Future<void> _pickAndLoadPdfFile() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (picked == null) return;
      final pickedFile = await pickedPath(picked);
      if (pickedFile == null) return;

      setState(() => _isLoadingPdf = true);

      final fileName = picked.name;

      // keep our own copy: the original may be moved or deleted later. A new
      // name each time, as the previous copy may still be open (Windows
      // refuses to overwrite an open file).
      final pdfDir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'pdfs'),
      );
      await pdfDir.create(recursive: true);
      final filePath = p.join(
        pdfDir.path,
        '${widget.noteId}-${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      // (copied by the system and hashed in pieces on another isolate: a PDF of scans is hundreds of MB, which are not read into memory)
      await File(pickedFile).copy(filePath);
      final String sha;
      try {
        sha = await sha256OfFile(filePath);
      } catch (_) {
        File(filePath).delete().catchError((Object _) => File(filePath));
        rethrow;
      }

      final PdfDocument doc;
      try {
        doc = await openPdfFile(filePath);
      } catch (e) {
        File(filePath).delete().catchError((Object _) => File(filePath));
        rethrow;
      }
      final pagesCount = doc.pages.length;
      final previousDoc = _pdfDocument;
      final previousFile = _pdfFilePath;

      _strokesPerPage.clear();
      _textBoxesPerPage.clear();
      _highlightsPerPage.clear();
      _imagesPerPage.clear();
      _selectedImage = null;
      _nativePages = {};
      _forgetPages();
      for (final patch in _hiRes.values) {
        patch.dispose();
      }
      _hiRes.clear();
      _hiResPending.clear();
      _pageHeights.clear();

      _resetPdfEdit();
      setState(() {
        if (_mode == CanvasInteractionMode.document) {
          _mode = CanvasInteractionMode.selectText;
        }
        _importedPdfName = fileName;
        _pdfFilePath = filePath;
        _pdfSha256 = sha;
        _pdfDocument = doc;
        _totalPages = pagesCount;
        _applyPageSizes(doc);
        _isLoadingPdf = false;
        _currentSelectedText = null;
        _currentSelectedPageIndex = null;
      });
      previousDoc?.dispose();
      if (previousFile != null) {
        File(
          previousFile,
        ).delete().catchError((Object _) => File(previousFile));
      }
      widget.onPdfImported?.call();
    } catch (e) {
      setState(() => _isLoadingPdf = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context
        ).showSnackBar(SnackBar(content: Text.verbatim(tr('Error loading PDF: {error}', {'error': e}))));
      }
    }
  }

  /// Every page's size is known as soon as the PDF is open, so the list has
  /// its final layout before any page image is ready. Otherwise pages would
  /// start as A4 placeholders and shrink or grow while the user scrolls.
  void _applyPageSizes(PdfDocument doc) {
    _schedulePrefetch();
    for (var i = 0; i < doc.pages.length; i++) {
      final page = doc.pages[i];
      if (page.width > 0 && page.height > 0) {
        _pageHeights[i] = basePageWidth * page.height / page.width;
      }
    }
  }

  /// The pages moved (or the PDF is new): the ink is read after things are quiet, and at most every 100 ms what is wanted of PDFium is
  /// looked at again: the pages ahead are asked for, what went out of reach is dropped, what is on screen is made sharp.
  void _schedulePrefetch() {
    _ink?.changed(); // (what is in view is read, after things are quiet)
    if (_pageScroll.hasClients) {
      final offset = _pageScroll.offset;
      if (offset != _lastScrollOffset) _scrollingBack = offset < _lastScrollOffset;
      _lastScrollOffset = offset;
    }
    _sharpenSoon();
    if (_scrollLook?.isActive ?? false) return;
    _scrollLook = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      _prefetch();
      _jobs.reconsider();
    });
  }

  /// Asks for the pictures of the pages on screen and those next to them, ahead of the reading first (the queue puts them in order).
  void _prefetch() {
    final doc = _pdfDocument;
    if (doc == null || _isBlank || _infinite) return;
    final (first, last) = _screenPages();
    final from = first - (_scrollingBack ? _pagesAhead : _pagesBehind), to = last + (_scrollingBack ? _pagesBehind : _pagesAhead);
    for (var i = math.max(0, from); i <= math.min(to, doc.pages.length - 1); i++) {
      if (_nativePages.contains(i) || _pageFutures.containsKey(i)) continue;
      _getOrLoadPage(i,).ignore(); // (whoever shows the page shows what went wrong)
    }
  }

  /// The first and the last page that are at least partly on the screen.
  (int, int) _screenPages() {
    if (_infinite || !_pageScroll.hasClients || _pageCount == 0) return (0, 0);
    final scale = _pageScale;
    final from = _pageScroll.offset, to = from + _pageScroll.position.viewportDimension;
    var top = _bannerExtent;
    var first = -1, last = -1;
    for (var i = 0; i < _pageCount; i++) {
      final extent = _pageExtent(i, scale);
      if (top >= to) break;
      if (top + extent > from) {
        if (first < 0) first = i;
        last = i;
      }
      top += extent;
    }
    return first < 0 ? (0, 0) : (first, last);
  }

  /// A page started or stopped being shown somewhere ([_BuiltPage]).
  void _pageBuilt(int index, bool shown) {
    if (shown) {
      _builtPages.update(index, (n) => n + 1, ifAbsent: () => 1);
    } else if ((_builtPages[index] ?? 0) <= 1) {
      _builtPages.remove(index);
    } else {
      _builtPages[index] = _builtPages[index]! - 1;
    }
  }

  /// Ranks the work for PDFium, lower first; null drops it (see [PageJobs]). What is on screen comes first: its pictures, then what
  /// is on screen of it made sharp for the zoom, then its words; then the pages ahead of the reading and their words, then those behind.
  /// A page that is built is never dropped (its widget waits for the work); others are dropped once they are out of reach.
  double? Function(PageJob) _jobRanker() {
    final (first, last) = _screenPages();
    final back = _scrollingBack;
    final thumb = _thumbWanted;
    double distance(int page) {
      if (page >= first && page <= last) return 0;
      final ahead = back ? first - page : page - last;
      return ahead > 0 ? ahead.toDouble() : (page < first ? first - page : page - last) * 1.5;
    }

    return (job) {
      final page = job.page;
      final built = _builtPages.containsKey(page);
      switch (job.kind) {
        case PageJobKind.thumb:
          return page == thumb ? -1 : null;
        case PageJobKind.picture:
          final reach = page < first ? (back ? _pagesAhead : _pagesBehind) : (back ? _pagesBehind : _pagesAhead);
          if (!built && (page < first - reach || page > last + reach)) return null;
          return distance(page);
        case PageJobKind.sharp:
          return _hiResWidth > 0 && page >= first && page <= last ? 0.5 : null;
        case PageJobKind.words:
          return built ? distance(page) + 1.5 : null;
      }
    };
  }

  /// Whether the pages go by too fast to be worth drawing: a fling of more than two pages a second. What it passes would be drawn
  /// long after it is gone, in front of the page it stops on.
  bool _flingingPast() {
    if (!_pageScroll.hasClients || _infinite) return false;
    final speed = _pageScroll.zoomPosition.flingVelocity.abs();
    return speed > 2 * _pageExtent(_visiblePage().$1, _pageScale);
  }

  /// A token that stops the render of [page] if [run] is called off (pdfrx renders in slices and looks at it between them).
  PdfPageRenderCancellationToken _cancelOnDrop(PageJobRun run, PdfPage page) {
    final token = page.createCancellationToken();
    run.onCancel(token.cancel);
    return token;
  }

  /// How many pixels across the picture of page [index] is made with: as wide as the screen shows the page at the normal size, at
  /// most the resolution of the settings (see [pagePixelWidth]).
  int _pictureWidthOf(int index) {
    final doc = _pdfDocument;
    final pageWidth = doc != null && index >= 0 && index < doc.pages.length ? doc.pages[index].width : 595.0;
    return pagePixelWidth(screenPixels: _fitWidth * _devicePixelRatio, pageWidth: pageWidth, dpi: _dpi);
  }

  Future<PdfPageData> _getOrLoadPage(int pageIndex) {
    final known = _pageFutures[pageIndex];
    if (known != null) return known;
    final loading = _loadSinglePageData(pageIndex);
    _pageFutures[pageIndex] = loading;
    // (a page that was dropped before it was drawn is asked for again by whoever shows it next)
    loading.then((_) {}, onError: (Object e) {
      if (e is PageJobDropped && identical(_pageFutures[pageIndex], loading)) _pageFutures.remove(pageIndex);
    });
    return loading;
  }

  Future<PdfPageData> _loadSinglePageData(int pageIndex) async {
    final epoch = _pagesEpoch;
    await _dpiSetting.catchError((Object _) => _dpi);
    final data = await _jobs.add(PageJob(pageIndex, PageJobKind.picture), (run) {
      final doc = _pdfDocument; // (the one there is when it starts)
      if (doc == null || pageIndex >= doc.pages.length) throw StateError('page ${pageIndex + 1} is not in the PDF');
      final page = doc.pages[pageIndex];
      final (first, last) = _screenPages();
      return loadPdfPicture(page, _pictureWidthOf(pageIndex),
          cancel: _cancelOnDrop(run, page), priority: pageIndex >= first && pageIndex <= last ? PdfPageRenderPriority.high : PdfPageRenderPriority.normal);
    });
    if (data.pageWidth > 0 && data.pageHeight > 0) {
      final height = basePageWidth * data.pageHeight / data.pageWidth;
      if (height != _pageHeights[pageIndex]) {
        _pageHeights[pageIndex] = height;
        if (mounted) setState(() {}); // (the list of pages goes by these)
      }
    }
    if (!mounted) {
      data.release();
    } else if (epoch == _pagesEpoch && !_pagesRead.containsKey(pageIndex)) {
      // (not when the PDF changed meanwhile, or the page has a newer picture: this one is shown to whoever waited for it, and not kept)
      _pagesRead[pageIndex] = data;
      _trimPages();
    }
    return data;
  }

  /// Keeps [data] as page [index] (what was kept of it is let go of).
  void _setPageRead(int index, PdfPageData data) {
    final old = _pagesRead[index];
    if (!identical(old, data)) old?.release();
    _pagesRead[index] = data;
  }

  /// Lets go of every page that was read, for a PDF that is another now. The pictures on screen stay as they are until the new ones
  /// are there (each page on screen has a handle of its own).
  void _forgetPages() {
    _remakePictures();
    _jobs.clear();
    _forgetWords();
    _thumbFutures.clear();
    for (final data in _thumbs.values) {
      data.release();
    }
    _thumbs.clear();
  }

  /// Lets go of the pictures of the pages, to have them made again (at another size); their words stay.
  void _remakePictures() {
    _pagesEpoch++;
    _jobs.dropWhere((j) => j.kind == PageJobKind.picture);
    _pageFutures.clear();
    for (final data in _pagesRead.values) {
      data.release();
    }
    _pagesRead.clear();
  }

  /// Has the words of page [index] read if they are not (after the pictures on screen); returns [index].
  int _requestWords(int index) {
    if (!_wordFutures.containsKey(index) && _wordsOf[index]?.value == null && _pdfDocument != null) _pageWords(index).ignore();
    return index;
  }

  /// The text layer of page [index] listens to this: it gets the words once they are read.
  ValueNotifier<PdfPageWords?> _wordsNotifier(int index) => _wordsOf.putIfAbsent(index, () => ValueNotifier(null));

  /// The words of page [index], read after the pictures on screen unless [urgent] (the user waits for them: a find, a highlight).
  Future<PdfPageWords> _pageWords(int index, {bool urgent = false}) {
    final known = _wordFutures[index];
    if (known != null && (known.urgent || !urgent || _wordsOf[index]?.value != null)) return known.future;
    late final Future<PdfPageWords> loading;
    loading = () async {
      final raw = await _jobs.add(PageJob(index, PageJobKind.words, urgent: urgent), (_) {
        final doc = _pdfDocument;
        if (doc == null || index >= doc.pages.length) throw StateError('page ${index + 1} is not in the PDF');
        return readPdfText(doc.pages[index],); // (only PDFium's part waits in line: the rest is on another isolate)
      },);
      final words = await pdfWordsOf(raw);
      // (not if the words of the page were let go of meanwhile: the PDF changed)
      if (mounted && identical(_wordFutures[index]?.future, loading)) {
        _wordsNotifier(index).value = words;
        _trimWords();
      }
      return words;
    }();
    _wordFutures[index] = (future: loading, urgent: urgent);
    loading.then((_) {}, onError: (Object e) {
      if (identical(_wordFutures[index]?.future, loading)) _wordFutures.remove(index); // (asked for again when the page is shown)
      if (e is! PageJobDropped) debugPrint('reading the text of page ${index + 1} failed: $e');
    });
    return loading;
  }

  /// Lets go of the words read ([only] that page's, else all): the PDF changed.
  void _forgetWords([int? only]) {
    _jobs.dropWhere((j) => j.kind == PageJobKind.words && (only == null || j.page == only));
    for (final page in only == null ? [..._wordFutures.keys, ..._wordsOf.keys] : [only]) {
      _wordFutures.remove(page);
      _wordsOf[page]?.value = null;
    }
  }

  /// The words of pages that are not shown and are far from the screen are let go of (a dense page is about 100 KB of them).
  void _trimWords() {
    final (first, last) = _screenPages();
    final far = [
      for (final page in _wordsOf.keys)
        if (!_builtPages.containsKey(page) && (page < first - 12 || page > last + 12)) page,
    ];
    for (final page in far) {
      _wordFutures.remove(page);
      _wordsOf.remove(page)?.dispose();
    }
  }

  /// A small picture of page [index] for the preview beside the scrollbar (only the page the preview shows now is made).
  Future<PdfPageData> _thumbOf(int index) {
    _thumbWanted = index;
    final known = _thumbFutures[index];
    if (known != null) return known;
    final epoch = _pagesEpoch;
    final loading = _jobs.add(PageJob(index, PageJobKind.thumb), (run) {
      final doc = _pdfDocument;
      if (doc == null || index >= doc.pages.length) throw StateError('page ${index + 1} is not in the PDF');
      final page = doc.pages[index];
      return loadPdfPicture(page, (150 * _devicePixelRatio * 2).round(), cancel: _cancelOnDrop(run, page), priority: PdfPageRenderPriority.high);
    }).then((data) {
      if (!mounted || epoch != _pagesEpoch) {
        data.release();
        throw PageJobDropped(PageJob(index, PageJobKind.thumb));
      }
      _thumbs.remove(index)?.release();
      _thumbs[index] = data;
      // (the 24 last made stay: dragging back and forth shows them again at once)
      while (_thumbs.length > 24) {
        final oldest = _thumbs.keys.first;
        _thumbs.remove(oldest)!.release();
        _thumbFutures.remove(oldest);
      }
      return data;
    });
    _thumbFutures[index] = loading;
    loading.then((_) {}, onError: (Object e) {
      if (identical(_thumbFutures[index], loading)) _thumbFutures.remove(index);
    });
    return loading;
  }

  /// How many pages are in view at once (a few, when the view is zoomed out): they all stay.
  int _pagesInView() {
    if (!_pageScroll.hasClients) return 1;
    final one = (_shownPageHeight(_visiblePage().$1) + 24) * _pageScale + _rulerExtent;
    return (_pageScroll.position.viewportDimension / math.max(one, 1)).ceil() + 1;
  }

  /// Lets go of the pages far from the one in view when the pages kept take too much; they are read again from the file if they are
  /// asked for (their height stays known).
  void _trimPages() {
    final sizes = {for (final e in _pagesRead.entries) e.key: e.value.bytes};
    for (final page in pagesToDrop(sizes, near: _visiblePage().$1, keep: math.max(pagesKeptAround, _pagesInView()))) {
      if (_builtPages.containsKey(page)) continue; // (shown: its widget would ask for it again at once)
      _pagesRead.remove(page)?.release();
      _pageFutures.remove(page);
    }
  }

  /// Page [index] as a PNG, for an export, at the resolution of the settings. Not through the pages kept: one page after the other is
  /// made, written and let go of.
  Future<Uint8List> _pagePng(int index) async {
    final page = _pdfDocument!.pages[index];
    final dpi = await _dpiSetting.catchError((Object _) => _dpi);
    final data = await loadPdfPicture(page, math.min(maxPagePixelWidth, (page.width * dpi / 72).round()));
    try {
      return await data.png();
    } finally {
      data.release();
    }
  }

  /// Where a text box goes so that it sits just under the highlighted text of page [pageIndex].
  Future<Offset> _positionUnderSelection(int pageIndex, String? selected) async {
    var at = const Offset(40, 40);
    try {
      final data = await _pageWords(pageIndex, urgent: true);
      final spans = selected == null ? null : _selectedSpans(pageIndex, data, selected);
      if (spans != null && spans.isNotEmpty) {
        final scale = basePageWidth / data.pageWidth;
        at = Offset(spans.first.$1.xMin * scale, spans.last.$1.yMax * scale + 10);
      }
    } catch (e) {
      debugPrint('locating the highlighted text failed: $e');
    }
    return at;
  }

  /// The render object of the text layer of page [pageIndex], while it is shown with its words.
  RenderPdfTextLayer? _layerOf(int pageIndex) {
    final box = _layerKeys[pageIndex]?.currentContext?.findRenderObject();
    return box is RenderPdfTextLayer && box.attached ? box : null;
  }

  /// How much the text under a selection handle of page [pageIndex] is made larger on the screen, along each axis (the layer is in
  /// page units, so that is the zoom). [type] says which handle; the same for both.
  Offset _handleStretch(int pageIndex, TextSelectionHandleType? type) {
    final uniform = Offset(_pageScale, _pageScale);
    try {
      final box = _layerOf(pageIndex);
      if (box == null) return uniform;
      final m = box.getTransformTo(null);
      final zero = MatrixUtils.transformPoint(m, Offset.zero);
      final sx = (MatrixUtils.transformPoint(m, const Offset(1, 0)) - zero).distance;
      final sy = (MatrixUtils.transformPoint(m, const Offset(0, 1)) - zero).distance;
      return sx > 0 && sy > 0 ? Offset(sx, sy) : uniform;
    } catch (e) {
      debugPrint('measuring the selection handle failed: $e');
      return uniform;
    }
  }

  /// The characters of each line that the user has selected on [pageIndex], found from where the selection starts and ends on the
  /// page, not from its text (which cannot tell two occurrences of a word apart). Null when there is no selection or it does not agree
  /// with the selected [text].
  List<(PdfTextLine, int, int)>? _selectedSpans(int pageIndex, PdfPageWords data, String text) {
    try {
      final spans = _layerOf(pageIndex)?.selectedSpans;
      if (spans == null || spans.isEmpty) return null;
      String squash(String t) => t.replaceAll(RegExp(r'\s+'), '');
      if (squash(spans.map((e) => e.$1.text.substring(e.$2, e.$3)).join()) != squash(text)) return null;
      return spans;
    } catch (e) {
      debugPrint('locating the selection failed: $e');
      return null;
    }
  }

  /// The highlight stretch around [mark]: the neighbours on its line in the same colour (a selection makes one mark per word).
  List<PdfHighlight> _stretchOf(int pageIndex, PdfHighlight mark) {
    final marks = _highlightsPerPage[pageIndex] ?? const <PdfHighlight>[];
    final stretch = <PdfHighlight>{mark};
    var grew = true;
    while (grew) {
      grew = false;
      for (final h in marks) {
        if (stretch.contains(h) || h.commentBox != null || h.color != mark.color) continue;
        final near = stretch.any((s) {
          final overlap = (h.rect.bottom < s.rect.bottom ? h.rect.bottom : s.rect.bottom) - (h.rect.top > s.rect.top ? h.rect.top : s.rect.top);
          return overlap > s.rect.height / 2 && h.rect.left <= s.rect.right + 8 && h.rect.right >= s.rect.left - 8;
        });
        if (near) {
          stretch.add(h);
          grew = true;
        }
      }
    }
    return stretch.toList();
  }

  /// A tap on a highlight: offers the other colours and taking it away. Returns whether there was a highlight under [at].
  bool _editHighlightAt(int pageIndex, Offset at, Offset globalAt) {
    final marks = _highlightsPerPage[pageIndex] ?? const <PdfHighlight>[];
    final hit = marks.where((h) => h.commentBox == null && h.rect.contains(at)).lastOrNull;
    if (hit == null) return false;
    final stretch = _stretchOf(pageIndex, hit);
    final size = MediaQuery.sizeOf(context);
    showMenu<Color?>(
      context: context,
      position: RelativeRect.fromLTRB(globalAt.dx, globalAt.dy, size.width - globalAt.dx, size.height - globalAt.dy),
      items: [
        for (final (name, color) in highlightColors)
          if (color != hit.color)
            PopupMenuItem(value: color, child: Row(children: [Icon(Icons.circle, color: color.withValues(alpha: 1), size: 16), const SizedBox(width: 8), Text(tr(name))])),
        PopupMenuItem(value: Colors.transparent, child: Row(children: [const Icon(Icons.format_color_reset, size: 16), const SizedBox(width: 8), Text(tr('Remove highlight'))])),
      ],
    ).then((picked) {
      if (picked == null || !mounted) return;
      setState(() {
        final list = _highlightsPerPage[pageIndex]!;
        if (picked == Colors.transparent) {
          list.removeWhere(stretch.contains);
        } else {
          for (final h in stretch) {
            final i = list.indexOf(h);
            if (i >= 0) list[i] = PdfHighlight(id: h.id, rect: h.rect, color: picked, author: h.author);
          }
        }
      });
    });
    return true;
  }

  /// Takes the plain highlights away from the selected text (comment marks go with their comment).
  void _removeHighlightFromSelection(int pageIndex, String? selectedText) async {
    if (selectedText == null || selectedText.trim().isEmpty) return;
    final pageData = await _pageWords(pageIndex, urgent: true);
    final spans = _selectedSpans(pageIndex, pageData, selectedText);
    final marks = _highlightsPerPage[pageIndex];
    if (spans == null || marks == null) return;
    final scale = basePageWidth / pageData.pageWidth;
    final covered = <Rect>[
      for (final (line, from, to) in spans)
        for (final w in line.words)
          if (w.endIndex > from && w.startIndex < to) Rect.fromLTRB(w.xMin * scale, w.yMin * scale, w.xMax * scale, w.yMax * scale),
    ];
    final before = marks.length;
    setState(() => marks.removeWhere((h) => h.commentBox == null && covered.any((r) => r.contains(h.rect.center))));
    if (marks.length != before) _scheduleSave();
  }

  void _applyHighlightOrCommentToSelection(
    int pageIndex,
    String? selectedText, {
    required bool isComment,
  }) async {
    if (selectedText == null || selectedText.trim().isEmpty) return;

    final pageData = await _pageWords(pageIndex, urgent: true);
    final scaleX = basePageWidth / pageData.pageWidth;
    final scaleY =
        basePageWidth / pageData.pageWidth; // uniform: aspect ratio is kept
    final searchLines = selectedText
        .toLowerCase()
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    Rect? firstMatchedRect;
    final spans = _selectedSpans(pageIndex, pageData, selectedText);
    // a comment is the marked text plus a box for what is said about it; the marks name the box
    final commentBox = isComment ? '${DateTime.now().microsecondsSinceEpoch}' : null;

    if (spans != null) {
      setState(() {
        for (final (line, from, to) in spans) {
          for (final w in line.words) {
            if (w.endIndex > from && w.startIndex < to) {
              final rect = Rect.fromLTRB(w.xMin * scaleX, w.yMin * scaleY, w.xMax * scaleX, w.yMax * scaleY);
              firstMatchedRect ??= rect;
              _highlightsPerPage.putIfAbsent(pageIndex, () => []).add(PdfHighlight(
                    rect: rect,
                    color: isComment ? Colors.blueAccent.withValues(alpha: 0.3) : _highlightColor,
                    commentBox: commentBox,
                    author: Authorship.current,
                  ));
            }
          }
        }
      });
      if (isComment && firstMatchedRect != null) {
        _addTextBoxAt(pageIndex, Offset(firstMatchedRect!.right + 10, firstMatchedRect!.top - 20), initialText: 'Comment: ', id: commentBox);
      }
      return;
    }

    // no geometry (should not happen): find the text in the page's lines
    setState(() {
      for (var line in pageData.lines) {
        final lineStr = line.text.toLowerCase();

        for (var sLine in searchLines) {
          int matchIdx = lineStr.indexOf(sLine);

          if (matchIdx != -1) {
            int matchEnd = matchIdx + sLine.length;
            for (var w in line.words) {
              if (w.endIndex > matchIdx && w.startIndex < matchEnd) {
                final rect = Rect.fromLTRB(
                  w.xMin * scaleX,
                  w.yMin * scaleY,
                  w.xMax * scaleX,
                  w.yMax * scaleY,
                );
                firstMatchedRect ??= rect;
                _highlightsPerPage
                    .putIfAbsent(pageIndex, () => [])
                    .add(
                      PdfHighlight(
                        rect: rect,
                        color: isComment
                            ? Colors.blueAccent.withValues(alpha: 0.3)
                            : _highlightColor,
                        commentBox: commentBox,
                    author: Authorship.current,
                      ),
                    );
              }
            }
          } else if (sLine.contains(lineStr)) {
            for (var w in line.words) {
              final rect = Rect.fromLTRB(
                w.xMin * scaleX,
                w.yMin * scaleY,
                w.xMax * scaleX,
                w.yMax * scaleY,
              );
              firstMatchedRect ??= rect;
              _highlightsPerPage
                  .putIfAbsent(pageIndex, () => [])
                  .add(
                    PdfHighlight(
                      rect: rect,
                      color: isComment
                          ? Colors.blueAccent.withValues(alpha: 0.3)
                          : _highlightColor,
                      commentBox: commentBox,
                    author: Authorship.current,
                    ),
                  );
            }
          }
        }
      }
    });

    if (isComment && firstMatchedRect != null) {
      _addTextBoxAt(
        pageIndex,
        Offset(firstMatchedRect!.right + 10, firstMatchedRect!.top - 20),
        initialText: 'Comment: ',
        id: commentBox,
      );
    }
  }

  // ---- making a text box
}

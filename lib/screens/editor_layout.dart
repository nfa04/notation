part of 'fixed_page_note_editor.dart';

/// What the editor is made of on the screen: the buttons of the top bar and the scrolling pages (the rest of the frame is in `build`).
extension _EditorLayout on _FixedPageNoteEditorState {
  /// Goes to select, draw or document mode.
  void _selectMode(CanvasInteractionMode mode) {
    setState(() {
      _mode = mode;
      // boxes are not editable in document mode: show them rendered
      if (_mode == CanvasInteractionMode.document) {
        _activeSelectedBox = null;
        if (!_isBlank) unawaited(_openPdfEditor());
      }
    });
    // (after the change: the edit still being typed is made, which sets state itself)
    if (_mode != CanvasInteractionMode.document) _leavePdfEdit();
  }

  void _toggleFavorite() {
    widget.repository.setFavorite(widget.noteId, !_favorite);
    setState(() => _favorite = !_favorite);
  }

  Future<void> _remindAboutNote() => showRemindDialog(context, widget.reminders!, kind: ReminderKind.note, refId: widget.noteId, title: _titleController.text.trim().isEmpty ? tr('Untitled Note') : _titleController.text.trim());

  /// The buttons of the top bar, left to right: the view, undo, the selection, the mode, what can be put on the page, the page itself,
  /// speech and the assistant, history and live work, and the files.
  /// Marks [child] as part of the text selection's own area. In a browser, pressing anything outside a [SelectableRegion] takes the
  /// focus from it and so drops its selection, before the press is finished: the Highlight button of the top bar went away under the
  /// finger (and the words it marks were no longer selected). A [TapRegion] of the region's group is not "outside". Elsewhere the
  /// selection is kept anyway, so this changes nothing there.
  Widget _keepsSelection(Widget child) =>
      TapRegion(groupId: SelectableRegion, child: child);
  List<Widget> _toolbarButtons(BuildContext context, {bool bottom = false}) {
    final sections = <String, List<Widget>>{
      'edit': [
      if (widget.onCloseSplit != null)
        IconButton(
          key: ValueKey('close-split-${widget.noteId}'),
          tooltip: tr('Close this note (end the split view)'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close_fullscreen, size: 20),
          onPressed: widget.onCloseSplit,
        )
      else if (widget.onOpenBeside != null)
        IconButton(
          key: const ValueKey('open-beside'),
          tooltip: tr('Open another note beside this one'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.vertical_split_outlined, size: 20),
          onPressed: _chooseNoteBeside,
        ),
      // takes back (or does again) the last change of any kind, not only drawings
      ValueListenableBuilder<int>(
        valueListenable: _undoTick,
        builder: (context, _, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            key: const ValueKey('undo-any'),
            tooltip: tr('Undo'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.undo_rounded, size: 20),
            onPressed: _undoStack.canUndo ? _undoDrawing : null,
          ),
          IconButton(
            key: const ValueKey('redo-any'),
            tooltip: tr('Redo'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.redo_rounded, size: 20),
            onPressed: _undoStack.canRedo ? _redoDrawing : null,
          ),
        ]),
      ),
      ],
      'note': [
      if (_canShapePages) _pagesMenu(),
      if (_on(Feature.outline) && (widget.bookmarks != null || widget.links != null)) _outlineButton(),
      if (!_infinite && _on(Feature.present)) _presentButton(),
      if (!_infinite && _on(Feature.flipbook)) _flipbookButton(),
      if (widget.audio != null && _on(Feature.audio)) _audioButton(),
      if (widget.audio != null && _on(Feature.audio)) _lectureButton(),
      if (widget.ai != null && _on(Feature.translate)) _translateButton(),
      if (widget.reminders != null && _on(Feature.reminders))
        IconButton(
          key: const ValueKey('remind-note'),
          tooltip: tr('Remind me about this note'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_alert_outlined, size: 20),
          onPressed: _remindAboutNote,
        ),
      if (widget.locks != null && _on(Feature.lock)) _lockButton(),
      if (_on(Feature.favorites))
      IconButton(
        key: const ValueKey('favorite-note'),
        tooltip: tr(_favorite ? 'Remove from favourites' : 'Add to favourites'),
        visualDensity: VisualDensity.compact,
        icon: Icon(_favorite ? Icons.star_rounded : Icons.star_outline_rounded, size: 20, color: _favorite ? Colors.amber : null),
        onPressed: _toggleFavorite,
      ),
      ],
      'selection': [
      if (_currentSelectedText != null &&
          _currentSelectedText!.trim().isNotEmpty &&
          _currentSelectedPageIndex != null) ...[
          _keepsSelection(
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.yellow.shade700,
            foregroundColor: Colors.black87,
          ),
          icon: const Icon(Icons.highlight, size: 16),
          label: const Text(
            'Highlight',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12
            ),
          ),
          onPressed: () {
            _applyHighlightOrCommentToSelection(
              _currentSelectedPageIndex!,
              _currentSelectedText,
              isComment: false,
            );
            setState(() {
              _currentSelectedText = null;
              _currentSelectedPageIndex = null;
            });
          },
        ),
          ),
          _keepsSelection(
        PopupMenuButton<Color>(
          key: const ValueKey('highlight-color'),
          tooltip: tr('Highlight colour'),
          icon: Icon(Icons.circle, size: 18, color: _highlightColor.withValues(alpha: 1)),
          onSelected: (c) => setState(() => _highlightColor = c),
          itemBuilder: (_) => [
            for (final (name, color) in highlightColors)
              PopupMenuItem(value: color, child: _keepsSelection( Row(children: [Icon(Icons.circle, color: color.withValues(alpha: 1), size: 16), const SizedBox(width: 8), Text(tr(name))])),
                  ),
          ],
            ),
        ),
        const SizedBox(width: 8),
          _keepsSelection(
        OutlinedButton.icon(
          key: const ValueKey('remove-highlight'),
          icon: const Icon(Icons.format_color_reset, size: 16),
          label: Text(tr('Remove highlight'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12,)),
          onPressed: () {
            _removeHighlightFromSelection(_currentSelectedPageIndex!, _currentSelectedText);
            setState(() {
              _currentSelectedText = null;
              _currentSelectedPageIndex = null;
            });
          },
        ),
          ),
        const SizedBox(width: 8),
          _keepsSelection(
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.add_comment, size: 16),
          label: const Text(
            'Comment',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12
            ),
          ),
          onPressed: () {
            _applyHighlightOrCommentToSelection(
              _currentSelectedPageIndex!,
              _currentSelectedText,
              isComment: true,
            );
            setState(() {
              _currentSelectedText = null;
              _currentSelectedPageIndex = null;
            });
          },
        ),
          ),
        const VerticalDivider(width: 24, indent: 12, endIndent: 12),
      ],
      ],
      'mode': [
      SegmentedButton<CanvasInteractionMode>(
          showSelectedIcon: false,
        segments: [
          const ButtonSegment(
            value: CanvasInteractionMode.selectText,
            icon: Icon(Icons.select_all, size: 16),
            label: Text('Select'),
          ),
          const ButtonSegment(
            value: CanvasInteractionMode.draw,
            icon: Icon(Icons.edit, size: 16),
            label: Text('Draw'),
          ),
          // the notebook's own text; on an imported PDF it edits the PDF's text and pictures
          ButtonSegment(
            value: CanvasInteractionMode.document,
            enabled: _isBlank && !_infinite || _pdfEditable,
            icon: const Icon(Icons.article_outlined, size: 16),
            label: const Text('Document'),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: (newSelection) => _selectMode(newSelection.first),
      ),
      const SizedBox(width: 12),

      if (_mode == CanvasInteractionMode.document && !_isBlank) ...[
        IconButton(
          tooltip: tr('Undo the last change to the PDF'),
          icon: const Icon(Icons.undo_rounded, size: 20),
          onPressed: _pdfEditUndo.isEmpty || _pdfEditBusy ? null : _undoPdfEdit,
        ),
        Text(tr('Tap text or a picture to change it'), style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
      ],
      ],
      'insert': [
      IconButton(
        key: const ValueKey('add-text-box'),
        tooltip: tr(_desktop
            ? 'Add a text box (or triple-click the page)'
            : 'Add a text box (or double-tap the page)'),
        icon: const Icon(Icons.text_fields_rounded, size: 20),
        onPressed: _addTextBoxHere,
      ),
      if (_on(Feature.tables))
      IconButton(
        key: const ValueKey('add-table'),
        tooltip: tr(_mode == CanvasInteractionMode.document ? 'Insert a table' : 'Add a table'),
        icon: const Icon(Icons.table_chart_outlined, size: 20),
        onPressed: _insertTable,
      ),
      if (_on(Feature.tables))
      IconButton(
        key: const ValueKey('add-truth-table'),
        tooltip: tr('Make the truth table of a formula'),
        icon: const Icon(Icons.grid_on, size: 20),
        onPressed: _insertTruthTable,
      ),
      if (_on(Feature.diagrams))
      IconButton(
        key: const ValueKey('add-diagram'),
        tooltip: tr('Make a mind map or a flowchart from a text'),
        icon: const Icon(Icons.account_tree_outlined, size: 20),
        onPressed: _insertDiagram,
      ),
      if (_on(Feature.images))
      PopupMenuButton<String>(
        key: const ValueKey('scan-menu'),
        tooltip: tr('Scan a page or read text from a picture'),
        icon: const Icon(Icons.document_scanner_outlined, size: 20),
        onSelected: _scanAction,
        itemBuilder: (_) => [
          if (_hasCamera) PopupMenuItem(value: 'camera', child: Text('Scan a page with the camera')),
          PopupMenuItem(value: 'file', child: Text('Scan a page from a picture...')),
          PopupMenuItem(value: 'read', child: Text('Read text from a picture...')),
        ],
      ),
      if (_on(Feature.images))
      IconButton(
        tooltip: tr('Add a picture'),
        icon: const Icon(
          Icons.add_photo_alternate_outlined,
          size: 20
        ),
        onPressed: _addImage,
      ),
      if (_on(Feature.images))
      IconButton(
        key: const ValueKey('add-collage'),
        tooltip: tr('Add several pictures as a mood board'),
        icon: const Icon(Icons.dashboard_outlined, size: 20),
        onPressed: _addCollage,
      ),
      if (_on(Feature.stamps))
      IconButton(
        key: const ValueKey('stamps'),
        tooltip: tr('Stamps: drawings kept to put on a page again'),
        icon: Icon(Icons.approval_outlined, size: 20, color: _stampsOpen ? Theme.of(context).colorScheme.primary : null),
        onPressed: _openStamps,
      ),

      ],
      'page': [
      // (in a PDF it is the paper of the pages added to it)
        PopupMenuButton<PageBackground>(
          tooltip: tr('Page background'),
          initialValue: _background,
          onSelected: (b) => setState(() => _background = b),
          itemBuilder: (_) => [
            for (final b in PageBackground.values)
              if (!_infinite || b.fitsCanvas || b == _background)
                CheckedPopupMenuItem(
                  value: b,
                  checked: b == _background,
                  child: Text(tr(b.label)),
                ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.grid_on_rounded, size: 16),
                const SizedBox(width: 4),
                Text(
                  tr(_background.label),
                  style: const TextStyle(fontSize: 12),
                ),
                const Icon(Icons.arrow_drop_down, size: 16),
              ],
            ),
          ),
        ),
      if (_isBlank) ...[
        if (!_infinite) ...[
        PopupMenuButton<PageFormat>(
          tooltip: tr('Page size'),
          initialValue: _pageFormat,
          onSelected: (f) => f.isInfinite ? _makeCanvas() : setState(() => _pageFormat = f),
          itemBuilder: (_) => [
            for (final f in PageFormat.papers)
              CheckedPopupMenuItem(
                value: f,
                checked: f == _pageFormat,
                child: Text(f.label),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(
              key: const ValueKey('page-size-infinite'),
              value: PageFormat.infinite,
              child: Text(PageFormat.infinite.label),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.crop_portrait_rounded, size: 16),
                const SizedBox(width: 4),
                Text(
                  _pageFormat.label,
                  style: const TextStyle(fontSize: 12),
                ),
                const Icon(Icons.arrow_drop_down, size: 16),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: tr(_landscape
              ? 'Landscape (tap for portrait)'
              : 'Portrait (tap for landscape)'),
          visualDensity: VisualDensity.compact,
          icon: Icon(
            _landscape
                ? Icons.crop_landscape_rounded
                : Icons.crop_portrait_rounded,
            size: 18,
          ),
          onPressed: () => setState(() => _landscape = !_landscape),
        ),
        ],
      ],

      if (_on(Feature.themeImages) && !_infinite)
      IconButton(
        tooltip: tr(_bannerImage == null
            ? 'Set a theme image for this note'
            : 'Change the theme image'),
        icon: const Icon(Icons.wallpaper_outlined, size: 20),
        onPressed: _pickThemeImage,
      ),
      ],
      'tools': [
      if (widget.speech != null && _on(Feature.dictate))
        IconButton(
          key: const ValueKey('dictate'),
          tooltip: tr('Dictate: write down what is said'),
          icon: const Icon(Icons.mic_none, size: 20),
          onPressed: _dictate,
        ),
      if (widget.readAloud != null && _on(Feature.readAloud))
        ListenableBuilder(
          listenable: widget.readAloud!,
          builder: (context, _) => IconButton(
            key: const ValueKey('read-aloud'),
            tooltip: tr(widget.readAloud!.preparing ? 'Getting the voice ready... (press to stop)' : widget.readAloud!.speaking ? 'Stop reading' : 'Read the note aloud'),
            icon: widget.readAloud!.preparing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(key: ValueKey('read-aloud-preparing'), strokeWidth: 2))
                : Icon(widget.readAloud!.speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined, size: 20),
            onPressed: _readAloud,
          ),
        ),
      if (widget.ai != null && _on(Feature.ideas))
        IconButton(
          key: const ValueKey('ideas-button'),
          tooltip: tr('Ideas from the assistant: colours, drawing prompts, characters, stories'),
          icon: const Icon(Icons.lightbulb_outline, size: 20),
          onPressed: _openIdeas,
        ),
      if (widget.ai != null && _on(Feature.assistant)) ...[
        IconButton(
          key: const ValueKey('assistant-button'),
          tooltip: tr('Ask about this document'),
          icon: Icon(Icons.auto_awesome, size: 20, color: _assistantOpen ? Theme.of(context).colorScheme.primary : null),
          onPressed: _toggleAssistant,
        ),
        IconButton(
          key: const ValueKey('generated-button'),
          tooltip: tr('What the AI made of this note'),
          icon: Icon(Icons.auto_fix_high_outlined, size: 20, color: _generatedOpen ? Theme.of(context).colorScheme.primary : null),
          onPressed: _toggleGenerated,
        ),
      ],
      ],
      'history': [
      if (widget.history != null && _on(Feature.history))
        IconButton(
          key: const ValueKey('history-button'),
          tooltip: tr('History of this note'),
          icon: Icon(Icons.history, size: 20, color: _historyOpen ? Theme.of(context).colorScheme.primary : null),
          onPressed: _openHistory,
        ),
      if (widget.collab != null && _on(Feature.live)) _liveButton(),
      ],
      'files': [
      ?_citationsButton(),
      ?_bibliographyButton(),
      // the file: the PDF it is made from and the one it makes
      if (_importedPdfName != null) ...[
        Chip(
          avatar: const Icon(Icons.picture_as_pdf, size: 16),
          label: Text(
            tr('{name} ({n} Pages)', {'name': _importedPdfName, 'n': _totalPages}),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
      ],
      if (_on(Feature.pdf) && !_infinite)
      ElevatedButton.icon(
        onPressed: _isLoadingPdf ? null : _pickAndLoadPdfFile,
        icon: _isLoadingPdf
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              )
            : const Icon(Icons.folder_open_rounded, size: 16),
        label: Text(
          _importedPdfName != null ? 'Change PDF' : 'Import PDF',
          style: const TextStyle(fontSize: 12),
        ),
      ),
      const SizedBox(width: 8),
      if (widget.noteFiles != null && _on(Feature.noteFiles)) ...[
        IconButton(
          key: const ValueKey('save-note-file'),
          tooltip: tr('Save this note as a file (.uninote), to keep or to open on another device'),
          icon: const Icon(Icons.save_alt_rounded, size: 20),
          onPressed: () => saveNoteAsFile(context, widget.noteFiles!, widget.noteId, _titleController.text, beforeExport: _saveNow),
        ),
        const SizedBox(width: 4),
      ],
      if (_on(Feature.exportImages))
        IconButton(
          key: const ValueKey('export-images-button'),
          tooltip: tr('Export as pictures'),
          icon: const Icon(Icons.image_outlined, size: 20),
          onPressed: _isLoadingPdf ? null : _exportImages,
        ),
      if (_hasDocument) _documentExportMenu(),
      // (a canvas has no pages to cut it into)
      if (_on(Feature.pdf) && !_infinite)
      ElevatedButton.icon(
        onPressed: !_isLoadingPdf ? _exportPdf : null,
        icon: const Icon(Icons.download_rounded, size: 16),
        label: const Text(
          'Export PDF',
          style: TextStyle(fontSize: 12)
        ),
      ),
      ],
    };
    final shown = <Widget>[];
    final selection = sections['selection']!;
    final ids = [for (final id in bottom ? _toolbarBottomIds() : _toolbarTopIds()) if (!_toolbarHidden.contains(id)) id];
    // what is selected on the page gets its buttons right after the note's own (at the start of the top bar if those are hidden)
    if (!bottom && _toolbarHidden.contains('note')) shown.addAll(selection);
    for (final id in ids) {
      final items = sections[id];
      if (items == null || items.isEmpty) continue;
      if (shown.isNotEmpty) shown.add(const VerticalDivider(width: 16, indent: 12, endIndent: 12));
      shown.addAll(items);
      if (id == 'note') shown.addAll(selection);
    }
    if (bottom) return shown;
    return [
      ...shown,
      if (shown.isNotEmpty) const VerticalDivider(width: 16, indent: 12, endIndent: 12),
      IconButton(
        key: const ValueKey('customize-toolbar'),
        tooltip: tr('Arrange the toolbars'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.tune_rounded, size: 20),
        onPressed: _customizeToolbar,
      ),
    ];
  }

  /// The pages, scrolling down (and across when zoomed in), with what the fingers and the pen do on them.
  Widget _pagesArea(BoxConstraints box) {
    if (_viewportW != box.maxWidth) _scheduleHiRes(); // (a window much wider: sharper pictures of the pages)
    _viewportW = box.maxWidth;
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    // while the note is presented its pages are shown by the presentation, which takes over their keys (see [_present])
    if (_presenting) return const ColoredBox(color: Colors.black);
    return Listener(
      onPointerDown: (e) {
        _lastPointerDown = e.pointer;
        _areaDownAt = e.position;
        _areaDownTime = DateTime.now();
        _areaTravel = 0;
        _onTouchDown(e);
      },
      onPointerMove: (e) {
        _areaTravel = math.max(_areaTravel, (e.position - _areaDownAt).distance);
        _onTouchMove(e);
        if (_drag != null && e.pointer == _drag!.pointer) {
          _dragTo(e.position);
        }
      },
      onPointerUp: (e) {
        _releasePen(e.pointer);
        _onTouchEnd(e);
        _tapOnNothing(e);
        if (_drag != null && e.pointer == _drag!.pointer) {
          _endDrag();
        }
      },
      onPointerCancel: (e) {
        _releasePen(e.pointer);
        _onTouchEnd(e);
        if (_drag != null && e.pointer == _drag!.pointer) {
          _endDrag();
        }
      },
      onPointerPanZoomStart: (_) => _panZoomStartZoom = _zoom,
      onPointerPanZoomUpdate: (e) {
        if (_canZoom) {
          _setZoom(
            _panZoomStartZoom * e.scale,
            _localInArea(e.position)
          );
        }
      },
      child: ScrollConfiguration(
        // the page scrollbar on the right is the one to use: the platform's would sit on top of it
        // (and while drawing the pen is for drawing: only fingers and the like scroll)
        behavior: ScrollConfiguration.of(context).copyWith(
          scrollbars: false,
          dragDevices: {
            for (final d in PointerDeviceKind.values)
              if (d != PointerDeviceKind.mouse &&
                  !(_mode == CanvasInteractionMode.draw && (d == PointerDeviceKind.stylus || d == PointerDeviceKind.invertedStylus)))
                d,
          },
        ),
        child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _hScroll,
        physics: _pinching
            ? const NeverScrollableScrollPhysics()
            : null,
        child: SizedBox(
          width:
              _contentWidth, // the banner fills it; the pages are centred in it
          height: box.maxHeight,
          child: AnimatedBuilder(
            animation: _textChanges,
            // (a screen made shorter by the keyboard or a place the layout puts right are no scrolling: its listeners are not told)
            builder: (context, _) {
              final scale = _pageScale;
              final extents = [for (var i = 0; i < _pageCount; i++) _pageExtent(i, scale)];
              return NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _lookForSheets();
                return false;
              },
              child: CustomScrollView(
              controller: _pageScroll,
              physics: _penDown || _pinching
                  ? const NeverScrollableScrollPhysics()
                  : null,
              // build well beyond the screen: a page takes a moment to appear
              scrollCacheExtent: ScrollCacheExtent.pixels(math.max(3000.0, box.maxHeight * 3)),
              slivers: [
                if (_bannerImage != null)
                  SliverToBoxAdapter(child: _buildBanner()),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16
                  ),
                  sliver: PageList(
                    extents: extents,
                    // every page is drawn page-sized and scaled to the zoom (and as tall as it is: for the frame until the list is told, it may be taller)
                    itemBuilder: (context, index) => OverflowBox(
                      maxHeight: double.infinity,
                      alignment: Alignment.topCenter,
                      child: _pageItem(index),
                    ),
                  ),
                ),
              ],
              ),
            );
            },
          ),
        ),
      ),
      ),
    );
  }

  /// Page [index]: page-sized, scaled to the zoom, with its comments beside it and who else is on it around it. While the document
  /// is written, the rulers for its margins are with every page: across above it, down along its side.
  Widget _pageItem(int index) {
    final ruler = _rulerExtent;
    final page = _presenceFrame(
      index,
      SizedBox(
        key: ValueKey('page-$index'),
        width: _paperWidth * _pageScale,
        child: FittedBox(
          fit: BoxFit.fitWidth,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _paperWidth,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24.0),
              child: RepaintBoundary(child: _pageContent(index)),
            ),
          ),
        ),
      ),
    );
    final pageLeft = _pagesLeft;
    final room = _commentRoom;
    return _BuiltPage(
      index: index,
      onShown: _pageBuilt,
      child: Listener(
      onPointerSignal: _onPageSignal,
      child: _pageWithComments(
        index,
        Semantics(
          container: true,
          label: tr('Page {n} of {total}', {'n': index + 1, 'total': _pageCount}),
          child: Stack(children: [
            Padding(
              padding: EdgeInsets.only(left: room.left, right: room.right),
              child: Center(
                child: ruler == 0
                    ? page
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                          width: _paperWidth * _pageScale,
                          height: ruler,
                          child: MarginRuler(
                            pageWidth: _paperWidth,
                            left: _marginLeft,
                            right: _marginRight,
                            onChanged: (l, r) => setState(() {
                              _marginLeft = l;
                              _marginRight = r;
                            }),
                          ),
                        ),
                        page,
                      ]),
              ),
            ),
            if (ruler > 0)
              Positioned(
                left: math.max(0.0, pageLeft - VerticalMarginRuler.width),
                top: ruler,
                height: _shownPageHeight(index) * _pageScale,
                // (a long document has a long ruler: it is not drawn again when the page next to it is)
                child: RepaintBoundary(
                  child: VerticalMarginRuler(
                    pageHeight: _heightOf(index),
                    top: _marginTop,
                    bottom: _marginBottom,
                    onChanged: (t, b) => setState(() {
                      _marginTop = t;
                      _marginBottom = b;
                    }),
                  ),
                ),
              ),
          ]),
        ),
      ),
      ),
    );
  }

  /// Room above each page for its margin ruler: only while the document is written (screen pixels, the zoom does not change it).
  double get _rulerExtent => _mode == CanvasInteractionMode.document && !_infinite ? MarginRuler.height : 0.0;

  /// What is on page [index], at the size of the paper.
  Widget _pageContent(int index) {
    // (a page added to a PDF is a notebook page: there is nothing of the file on it to edit)
    if (_mode == CanvasInteractionMode.document && !_isBlank) return _nativePages.contains(index) ? IgnorePointer(child: _buildPageTile(index, null)) : _pdfEditPage(index);
    if (_mode == CanvasInteractionMode.document) {
      // text editing: the pages stay visible but untouchable
      return index == 0 ? _buildDocumentEditorPage() : IgnorePointer(child: _buildPageTile(index, null));
    }
    if (_isBlank || _nativePages.contains(index)) return _buildPageTile(index, null);
    return FutureBuilder<PdfPageData>(
      future: _getOrLoadPage(index),
      builder: (context, snapshot) => snapshot.hasData
          ? _buildPageTile(index, snapshot.data!)
          : SizedBox(
              width: _paperWidth,
              height: _heightOf(index),
              child: _PageSpinner(label: tr('Loading Page {n}...', {'n': index + 1})),
            ),
    );
  }
}

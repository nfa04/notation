part of 'fixed_page_note_editor.dart';

/// What the keyboard shortcuts do in the editor (which keys do what is set in the settings: see [ShortcutService]).
extension _EditorShortcuts on _FixedPageNoteEditorState {
  ShortcutService get _shortcuts => widget.shortcuts ?? ShortcutService.fallback;

  /// The line widths of the pen and of the highlighter that the thinner and thicker keys step through.
  static final _penWidths = [for (final (width, _) in _penWidthOptions) width];
  static final _highlighterWidths = [for (final (width, _) in _highlighterWidthOptions) width];

  /// Does the action [id] if this note is the one the keyboard is for and the action applies; false when it is not for the editor
  /// (or cannot be done now), so that the key goes on to whoever else may want it.
  bool _onShortcut(String id) {
    if (!mounted || !(widget.paneActive?.call() ?? true)) return false; // the shortcuts are for the note that was last used
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    // a text that is being typed in has its own undo, caret movement and paste
    final typing = shortcutTextFocused();
    if (id.startsWith('shape.')) return _chooseShape(ShapeTool.values.byName(id.substring(6)));
    if (id.startsWith('color.') && id != 'color.custom') return _chooseColor(int.parse(id.substring(6)) - 1);
    switch (id) {
      case 'edit.undo' || 'edit.redo':
        if (typing) return false;
        id == 'edit.redo' ? _redoDrawing() : _undoDrawing();
      case 'edit.paste':
        if (typing) {
          // a text field pastes text by itself, and cannot take a picture: when only a picture
          // is on the clipboard (a screenshot), it goes onto the page
          _paste(onlyPicture: true);
          return false;
        }
        _paste();
      case 'edit.delete':
        // (a text that is being typed in keeps its Delete and Backspace)
        if (typing || _mode == CanvasInteractionMode.document) return false;
        if (_hasSelection) {
          _deleteSelectedStroke();
        } else if (_activeSelectedBox != null) {
          _deleteTextBox(_activeSelectedBox!);
        } else if (_selectedImage != null) {
          _deleteImage(_selectedImage!);
        } else {
          return false;
        }
      case 'edit.clearPage':
        _clearPage();
      case 'find.open':
        _openFind();
      case 'find.replace':
        _openFind(replace: true);
      case 'find.next' || 'find.previous':
        if (!_findOpen) return false;
        _findStep(id == 'find.next' ? 1 : -1);

      case 'note.save':
        unawaited(_saveNow());
      case 'note.favorite':
        if (!_on(Feature.favorites)) return false;
        _toggleFavorite();
      case 'note.present':
        if (_infinite || !_on(Feature.present)) return false;
        unawaited(_present());
      case 'note.history':
        if (widget.history == null || !_on(Feature.history)) return false;
        _openHistory();
      case 'note.assistant':
        if (widget.ai == null || !_on(Feature.assistant)) return false;
        _toggleAssistant();
      case 'note.outline':
        if (!_on(Feature.outline) || (widget.bookmarks == null && widget.links == null)) return false;
        unawaited(_openOutline());
      case 'note.bookmark':
        if (widget.bookmarks == null || _infinite) return false;
        unawaited(_toggleBookmark(_visiblePage().$1));
      case 'note.importPdf':
        if (!_on(Feature.pdf) || _infinite || _isLoadingPdf) return false;
        unawaited(_pickAndLoadPdfFile());
      case 'note.exportPdf':
        if (!_on(Feature.pdf) || _infinite || _isLoadingPdf) return false;
        unawaited(_exportPdf());
      case 'note.dictate':
        if (widget.speech == null || !_on(Feature.dictate)) return false;
        unawaited(_dictate());
      case 'note.readAloud':
        if (widget.readAloud == null || !_on(Feature.readAloud)) return false;
        unawaited(_readAloud());
      case 'note.translate':
        if (widget.ai == null || !_on(Feature.translate)) return false;
        unawaited(_translateNote());
      case 'note.remind':
        if (widget.reminders == null || !_on(Feature.reminders)) return false;
        unawaited(_remindAboutNote());
      case 'note.beside':
        if (widget.onCloseSplit != null) {
          widget.onCloseSplit!();
        } else if (widget.onOpenBeside != null) {
          unawaited(_chooseNoteBeside());
        } else {
          return false;
        }

      case 'mode.select':
        _selectMode(CanvasInteractionMode.selectText);
      case 'mode.draw':
        _selectMode(CanvasInteractionMode.draw);
      case 'mode.document':
        if (!(_isBlank && !_infinite || _pdfEditable)) return false;
        _selectMode(CanvasInteractionMode.document);
      case 'tool.pen':
        _chooseTool();
      case 'tool.highlighter':
        if (!_on(Feature.highlighter)) return false;
        _chooseTool(highlighter: !_highlighter);
      case 'tool.eraser':
        _chooseTool(erase: !_erasing);
      case 'tool.lasso':
        if (!_on(Feature.lasso)) return false;
        _chooseTool(lasso: !_lassoing);
      case 'tool.eyedropper':
        if (!_on(Feature.colorPicker)) return false;
        _toggleEyedropper();
      case 'tool.fillBucket':
        if (!_on(Feature.fillBucket)) return false;
        _toggleBucket();
      case 'tool.straighten':
        if (!_on(Feature.straighten)) return false;
        setState(() => _straighten = !_straighten);
        widget.repository.settings.set('straighten_lines', _straighten ? '1' : '0');
      case 'tool.plot':
        if (!_on(Feature.plots)) return false;
        unawaited(_addEmptyPlot());

      case 'color.custom':
        if (_mode != CanvasInteractionMode.draw) return false;
        unawaited(_addCustomColor());
      case 'size.thinner' || 'size.thicker':
        if (_mode != CanvasInteractionMode.draw) return false;
        _stepStrokeWidth(id == 'size.thicker' ? 1 : -1);

      case 'insert.textBox':
        _addTextBoxHere();
      case 'insert.table':
        if (!_on(Feature.tables)) return false;
        unawaited(_insertTable());
      case 'insert.diagram':
        if (!_on(Feature.diagrams)) return false;
        unawaited(_insertDiagram());
      case 'insert.image':
        if (!_on(Feature.images)) return false;
        unawaited(_addImage());

      case 'zoom.in' || 'zoom.out' || 'zoom.reset':
        if (_zoomLocked) return false;
        final middle = Offset(_viewportW / 2, _viewportH / 2);
        _setZoom(id == 'zoom.reset' ? 1.0 : id == 'zoom.in' ? _zoom * 1.25 : _zoom / 1.25, middle);
      case 'toolbar.nextProfile' || 'toolbar.previousProfile':
        if (typing || _toolbarProfiles.length < 2) return false;
        unawaited(_stepToolbarProfile(id == 'toolbar.nextProfile' ? 1 : -1));
      case 'zoom.fit':
        if (!_infinite) return false;
        _fitCanvas();
      case 'view.turnLeft' || 'view.turnRight' || 'view.straighten':
        if (!_infinite || _zoomLocked) return false;
        // (in steps of 15 degrees, from the nearest step: a turn made with fingers comes onto them)
        const step = math.pi / 12;
        final turn = id == 'view.straighten' ? 0.0 : ((_viewTurn / step).round() + (id == 'view.turnRight' ? 1 : -1)) * step;
        _turnCanvas(turn, _viewMiddle);
      case 'page.next' || 'page.previous' || 'page.first' || 'page.last':
        if (typing || _infinite || _pageCount == 0) return false;
        final at = _visiblePage().$1;
        _jumpToPage(switch (id) {
          'page.next' => (at + 1).clamp(0, _pageCount - 1),
          'page.previous' => (at - 1).clamp(0, _pageCount - 1),
          'page.first' => 0,
          _ => _pageCount - 1,
        });
      default:
        return false; // (for the frame of the app)
    }
    return true;
  }

  /// Chooses what the pen does: draws (no argument), erases, selects with the lasso or highlights. The drawing mode is gone to if needed.
  void _chooseTool({bool erase = false, bool lasso = false, bool highlighter = false}) {
    if (_mode != CanvasInteractionMode.draw) _selectMode(CanvasInteractionMode.draw);
    setState(() {
      _picking = false;
      _bucket = false;
      _erasing = erase;
      _lassoing = lasso;
      _highlighter = highlighter;
      _brush = penBrushId;
      _chosenDrawTool = null;
      if (!lasso) _lassoPath = null;
      if (erase || lasso || highlighter) return;
      _shape = ShapeTool.freehand;
    });
  }

  /// Chooses what a drag with the pen draws, like the shape button does.
  bool _chooseShape(ShapeTool tool) {
    if (!_on(Feature.shapes)) return false;
    if (_mode != CanvasInteractionMode.draw) _selectMode(CanvasInteractionMode.draw);
    setState(() {
      _shape = tool;
      _picking = false;
      _bucket = false;
      _chosenDrawTool = null;
      _erasing = false;
      _lassoing = false;
      _lassoPath = null;
    });
    return true;
  }

  /// Chooses the [index]th color of the drawing bar for the pen (while drawing).
  bool _chooseColor(int index) {
    if (_mode != CanvasInteractionMode.draw || index < 0 || index >= drawColors.length) return false;
    setState(() {
      _selectedPenColor = drawColors[index];
      _erasing = false;
      _lassoing = false;
    });
    return true;
  }

  /// The next thicker ([by] 1) or thinner (-1) of the line widths the width menu has, for the pen or the highlighter.
  void _stepStrokeWidth(int by) {
    final widths = _highlighter ? _highlighterWidths : _penWidths;
    final now = _highlighter ? _highlighterWidth : _strokeWidth;
    // (the width in use may be none of them: the closest one counts)
    var at = 0;
    for (var i = 1; i < widths.length; i++) {
      if ((widths[i] - now).abs() < (widths[at] - now).abs()) at = i;
    }
    final to = widths[(at + by).clamp(0, widths.length - 1)];
    setState(() {
      if (_highlighter) {
        _highlighterWidth = to;
      } else {
        _strokeWidth = to;
      }
    });
  }
}

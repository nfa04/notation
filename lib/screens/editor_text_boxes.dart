part of 'fixed_page_note_editor.dart';

/// Text boxes and tables: making, pasting, resizing and showing them.
extension _EditorTextBoxes on _FixedPageNoteEditorState {
  void _attachBox(TextBoxWidgetModel box) {
    box.controller.addListener(() {
      _scheduleSave();
      _echoesSoon(() => box.controller.text);
    });
    // a new box starts empty (with only a hint): left without any text it is not worth keeping, nobody could see it to delete it
    box.focusNode.addListener(() {
      if (box.focusNode.hasFocus) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || box.focusNode.hasFocus || _activeSelectedBox?.id == box.id || box.controller.text.isNotEmpty || _inGutter(box)) return;
        if (_pageOfBox(box) != null) _deleteTextBox(box);
      });
    });
  }

  /// Counts the clicks of a mouse in about the same place, quick after each other;
  /// true on the third, which makes a text box. (A double click selects a word
  /// and a triple click a paragraph, so it takes three to mean "a box here".)
  /// Touch and pen are not counted: they keep the double tap and the long press.
  bool _tripleClick(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || (e.buttons & kPrimaryMouseButton) == 0) return false;
    final now = DateTime.now();
    final near = (e.localPosition - _lastClickAt).distance < 8;
    _clicks = near && now.difference(_lastClickTime) < const Duration(milliseconds: 500) ? _clicks + 1 : 1;
    _lastClickTime = now;
    _lastClickAt = e.localPosition;
    if (_clicks < 3) return false;
    _clicks = 0;
    return true;
  }

  // ---- pasting (the keys that ask for it are in editor_shortcuts.dart)

  /// Ctrl+V (Cmd+V): a picture on the clipboard becomes a picture on the page on
  /// screen, text becomes a text box there. While a text is being edited the
  /// paste belongs to that text instead.
  Future<void> _paste({bool onlyPicture = false}) async {
    final content = await (widget.readClipboard ?? () => readSystemClipboard(onProblem: _clipboardProblem))();
    if (!mounted) return;
    // with text on the clipboard too (copied from a web page), the field's own paste is the one
    if (onlyPicture && (content.text ?? '').trim().isNotEmpty) return;
    var bytes = content.image;
    var jpeg = false;
    if (bytes == null) {
      for (final path in content.files) {
        final lower = path.toLowerCase();
        if (!['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'].any(lower.endsWith)) continue;
        final file = File(path);
        if (!await file.exists()) continue; // (on a phone these are not paths)
        bytes = await file.readAsBytes();
        jpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
        break;
      }
    }
    if (bytes != null && bytes.isNotEmpty) {
      try {
        await _placeImage(bytes, isPng: !jpeg && _looksLikePng(bytes), isJpeg: jpeg);
        return;
      } catch (e) {
        debugPrint('pasting a picture failed: $e');
        _clipboardProblem(tr('The picture could not be added: {error}', {'error': e}));
      }
    }
    final text = content.text;
    if (!onlyPicture && text != null && text.trim().isNotEmpty) {
      final (page, scrolled) = _visiblePage();
      _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text.trim());
    }
  }

  /// Says why pasting did nothing, instead of failing silently.
  void _clipboardProblem(String problem) {
    if (!mounted || problem == _lastClipboardProblem) return;
    _lastClipboardProblem = problem;
    Future<void>.delayed(const Duration(seconds: 30), () => _lastClipboardProblem = null);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(problem), duration: const Duration(seconds: 8)));
  }

  /// A new text box at the top of the page on screen: the button for it in the top bar.
  void _addTextBoxHere() {
    final (page, scrolled) = _visiblePage();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40));
  }

  /// Asks for a size and puts a table there: into the text of the document being
  /// written, else onto the page on screen as an element of its own.
  Future<void> _insertTable() async {
    final size = await askTableSize(context);
    if (size == null || !mounted) return;
    if (_mode == CanvasInteractionMode.document) {
      _documentController.value = insertTable(_documentController.value, size.$1, size.$2);
      setState(() {}); // the preview shows it
      return;
    }
    final (page, scrolled) = _visiblePage();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: emptyTable(size.$1, size.$2), width: 120.0 * size.$2.clamp(2, 5));
  }

  /// The tap or click that makes a text box ends a moment later: that end must not let go of the new box again.
  bool get _boxJustMade => DateTime.now().difference(_boxMadeAt) < const Duration(milliseconds: 600);

  void _addTextBoxAt(
    int pageIndex,
    Offset localPosition, {
    String initialText = '',
    String? id,
    double width = 260,
  }) {
    if (!_drawingLayer.editable) {
      _layerBlocked(); // (a box on a hidden or locked layer could not be reached)
      return;
    }
    setState(() {
      final newBox = TextBoxWidgetModel(
        id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        position: Offset(
          localPosition.dx.clamp(0.0, math.max(0.0, _paperWidth - width)),
          localPosition.dy.clamp(
            0.0,
            math.max(0.0, _heightOf(pageIndex) - 120),
          ),
        ),
        initialText: initialText,
        size: Size(width, 0),
        author: Authorship.current,
        layer: _drawingLayer.id,
      );
      _attachBox(newBox);
      _textBoxesPerPage.putIfAbsent(pageIndex, () => []).add(newBox);
      // a comment's box is beside the page, in its own card: it has no tools above it to select it for
      _activeSelectedBox = _inGutter(newBox) ? null : newBox;
      _boxMadeAt = DateTime.now();
      newBox.focusNode.requestFocus();
    });
  }

  /// The height of [box] as the editor shows it, or null if it is not on screen
  /// (or being edited, when it is a little taller than it will be).
  double? _shownHeight(TextBoxWidgetModel box) {
    if (_activeSelectedBox?.id == box.id) return null;
    return _laidOutHeight(box);
  }

  void _resizeBox(TextBoxWidgetModel box, Offset delta) {
    final shown = _laidOutHeight(box) ?? box.size.height;
    final height = (_resizeFrom ?? shown) + delta.dy;
    _resizeFrom = height;
    setState(() {
      box.size = Size(
        (box.size.width + delta.dx).clamp(_minBoxWidth, math.max(_minBoxWidth, _paperWidth - box.position.dx)),
        math.max(0.0, height),
      );
    });
  }

  Widget _buildFloatingTextBox(TextBoxWidgetModel box) {
    final isSelected = _activeSelectedBox?.id == box.id;
    final layer = _layers.byId(box.layer);
    if (!layer.visible) return SizedBox.shrink(key: ValueKey('floating-box-${box.id}')); // (a hidden layer shows nothing)

    return Positioned(
      // (by the box: boxes come and go in the list of what the page shows, and a box must not be taken for the one that stood in
      // its place - its text field, with the key of its own, would be moved to another place in the tree and its accessibility node
      // with it, which Flutter's checks of the semantics tree do not stand)
      key: ValueKey('floating-box-${box.id}'),
      left: box.position.dx,
      top: box.position.dy,
      // (with the connector tool the pen draws over the boxes, from one to the other, instead of moving them; a locked layer's boxes
      // are only to be seen)
      child: Opacity(
        opacity: layer.opacity,
        child: IgnorePointer(
        ignoring: _connecting || layer.locked,
        child: ElementDragDetector(
        onTap: () => setState(() {
          // Shift adds the box to what is selected (or takes it out); on the box that is being edited and nothing else it is the
          // text's own, which extends its selection
          final page = _pageOfBox(box);
          if (_addingToSelection && page != null && !(isSelected && !_hasSelection && _selectedImage == null)) {
            _toggleInSelection(page, box: box);
            return;
          }
          _activeSelectedBox = box;
          box.focusNode.requestFocus();
        }),
        onDragStart: (global) {
          // a box in a group is pulled with the rest of the group
          if (!_groupBoxes.contains(box) && !_selectGroupOf(box: box)) return _startDrag(box, box.position, global);
          setState(() {});
          _startStrokeDrag(global);
        },
        child: Stack(
          children: [
            _floatingTextBoxBody(box, isSelected),
            if (isSelected)
              // pull the corner to make the box wider or taller
              Positioned(
                right: 0,
                bottom: 0,
                child: ElementDragDetector(
                  key: ValueKey('resize-box-${box.id}'),
                  onDragUpdate: (delta) => _resizeBox(box, delta),
                  onDragEnd: () {
                    _resizeFrom = null;
                    _scheduleSave();
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: Icon(Icons.south_east_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        ),
        ),
      ),
    );
  }

  Widget _floatingTextBoxBody(TextBoxWidgetModel box, bool isSelected) {
    if (isSelected) box.controller.useSpelling(widget.spell); // (the lines under misspelled words show while it is edited)
    return Builder(
      builder: (context) {
        return Container(
          key: _boxKeys.putIfAbsent(box.id, () => GlobalKey()),
          width: box.size.width,
          constraints: BoxConstraints(minHeight: box.size.height),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: box.style.fill,
            borderRadius: BorderRadius.circular(box.style.radius),
            // a box without a border still shows a thin one while it is selected
            border: isSelected
                ? Border.all(color: Theme.of(context).colorScheme.primary, width: math.max(2.0, box.style.borderWidth))
                : _boxFound(box.id) > 0
                    ? Border.all(color: _boxFound(box.id) == 2 ? const Color(0xFFFF9800) : const Color(0xFFFFEB3B), width: 3)
                    : (box.style.borderWidth > 0
                    ? Border.all(color: box.style.borderColor, width: box.style.borderWidth)
                    : null),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                      blurRadius: 8,
                    ),
                  ]
                : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(
                      Icons.drag_indicator_rounded,
                      size: 16,
                      color: Colors.grey.shade600,
                    ),
                    Text(
                      '${box.fontSize.toInt()}pt',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              // selected = editing the raw Markdown, otherwise show it rendered
              if (isSelected && isTableText(box.controller.text))
                TableEditor(source: box.controller, fontSize: box.fontSize, textColor: box.style.textColor)
              else if (isSelected)
                SpellTapRegion(
                  controller: box.controller,
                  service: widget.spell,
                  child: TextField(
                  controller: box.controller,
                  focusNode: box.focusNode,
                  autofocus: true,
                  maxLines: null,
                  contextMenuBuilder: (context, state) => _calculateMenu(_MenuOn.field(state), box.controller),
                  selectionControls: selectionControlsAtZoom(() => _pageScale),
                  onTap: () => setState(() => _activeSelectedBox = box),
                  style: TextStyle(
                    fontSize: box.fontSize,
                    height: 1.4,
                    color: box.style.textColor,
                  ),
                  cursorColor: box.style.textColor,
                  decoration: InputDecoration(
                    hintText: tr('Type text...'),
                    filled: false, border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  ),
                )
              else
                ListenableBuilder(
                  listenable: box.controller,
                  builder: (_, _) => MarkdownView(
                    controller: box.controller,
                    fontSize: box.fontSize,
                    onLink: _openLink,
                    onCitation: (run) => _editCitation(box.controller, run),
                    textColor: box.style.textColor,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

part of 'fixed_page_note_editor.dart';

/// The line widths of the highlighter in the width menu.
const _highlighterWidthOptions = <(double, String)>[
  (12.0, 'Slim (12pt)'),
  (18.0, 'Normal (18pt)'),
  (28.0, 'Wide (28pt)'),
  (40.0, 'Broad (40pt)'),
  (60.0, 'Huge (60pt)'),
];

/// The line widths of the pen in the width menu (the keys of the line width step through them too), thinnest first.
const _penWidthOptions = <(double, String)>[
  (0.5, 'Hairline (0.5pt)'),
  (1.0, 'Extra fine (1.0pt)'),
  (1.5, 'Fine (1.5pt)'),
  (2.0, 'Light (2.0pt)'),
  (3.0, 'Normal (3.0pt)'),
  (4.0, 'Medium (4.0pt)'),
  (6.0, 'Thick (6.0pt)'),
  (9.0, 'Bold (9pt)'),
  (14.0, 'Marker (14pt)'),
  (24.0, 'Extra thick (24pt)'),
];

/// The drawing menu on the right: pens, colours, shapes and plots.
extension _EditorDrawBar on _FixedPageNoteEditorState {
  /// The last entry of the width menu: a slider for any width in between (the pen's or the highlighter's, whichever is in use).
  /// It changes the width as it is moved and leaves the menu open, so the others stay the quick way.
  PopupMenuEntry<double> _customWidthSlider() {
    final (min, max) = _highlighter ? (5.0, 100.0) : (0.5, 40.0);
    return PopupMenuItem<double>(
      key: const ValueKey('custom-width'),
      enabled: false, // (it is not picked: it is moved)
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: StatefulBuilder(
        builder: (context, setLocal) {
          final value = (_highlighter ? _highlighterWidth : _strokeWidth).clamp(
            min,
            max,
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${tr('Custom')}: ${value.toStringAsFixed(1)}pt',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              SizedBox(
                width: 200,
                child: Slider.adaptive(
                  min: min,
                  max: max,
                  value: value,
                  onChanged: (v) {
                    final width = double.parse(v.toStringAsFixed(1));
                    setLocal(() {});
                    setState(() {
                      if (_highlighter) {
                        _highlighterWidth = width;
                      } else {
                        _strokeWidth = width;
                      }
                    });
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _loadCustomColors() async {
    final saved = await widget.repository.settings.penColors();
    final straighten = await widget.repository.settings.get('straighten_lines');
    final onionBack = int.tryParse(await widget.repository.settings.get('onion_back') ?? '');
    final onionNext = await widget.repository.settings.get('onion_next');
    final more = await widget.repository.settings.get('draw_bar_more');
    final stabiliser = double.tryParse(
      await widget.repository.settings.get('stabiliser_strength') ?? '',
    );
    final layout = _decodeToolbarLayout(
      await widget.repository.settings.get('toolbar_layout'),
    );
    final profiles = decodeToolbarProfiles(
      await widget.repository.settings.get('toolbar_profiles'),
    );
    if (mounted) {
      setState(() {
        _toolbarOrder = layout.top;
        _toolbarBottom = layout.bottom;
        _toolbarHidden = layout.hidden;
        _toolbarProfiles = profiles.profiles;
        _activeToolbarProfile = profiles.active;
        _customColors = saved;
        _straighten = straighten != '0';
        _moreTools = more == '1';
        _onionBack = (onionBack ?? 0).clamp(0, 3);
        _onionNext = onionNext == '1';
        _stabiliserStrength = (stabiliser ?? 0).clamp(0.0, 1.0);
      });
    }
  }

  Future<void> _addCustomColor() async {
    final picked = await pickColorOnWheel(context, _selectedPenColor);
    if (picked == null || !mounted) return;
    setState(() {
      _customColors.removeWhere((c) => c.toARGB32() == picked.toARGB32());
      _customColors.add(picked);
      if (_customColors.length > _maxCustomColors) _customColors.removeAt(0);
      _selectedPenColor = picked;
      _erasing = false;
      _lassoing = false;
    });
    await widget.repository.settings.setPenColors(_customColors);
  }

  /// Offers complementary, triadic and analogous palettes built on the pen colour.
  Future<void> _chooseHarmony() async {
    final choice = await showColorHarmonies(context, _selectedPenColor);
    if (choice == null || !mounted) return;
    setState(() {
      for (final c in choice.keep) {
        if ([...drawColors, ..._customColors].any((x) => x.toARGB32() == c.toARGB32())) continue;
        _customColors.add(c);
        if (_customColors.length > _maxCustomColors) _customColors.removeAt(0);
      }
      _selectedPenColor = choice.use;
      _erasing = false;
      _lassoing = false;
    });
    await widget.repository.settings.setPenColors(_customColors);
  }

  Future<void> _removeCustomColor(Color c) async {
    setState(
      () => _customColors.removeWhere((x) => x.toARGB32() == c.toARGB32()),
    );
    await widget.repository.settings.setPenColors(_customColors);
  }

  /// Page area with the drawing tools on the right while in draw mode.
  Widget _withDrawBar(Widget pages) {
    // always the same layout, so that the pages keep their state (and their scroll
    // position) when the tools come and go
    final draw = _mode == CanvasInteractionMode.draw;
    final wide = MediaQuery.of(context).size.width >= _sidePanelFrom;
    final panelItems = <Widget>[
      if (_lookup != null && wide)
        ..._sidePanel(
          'lookup',
          LookupPanel(
            key: const ValueKey('lookup-panel'),
            term: _lookup!.term,
            source: _lookup!.source,
            address: _lookup!.address,
            page: widget.webPage,
            onLinkPage: _linkWebPage,
            onAddText: _addWebText,
            language: _translateTo,
            onLanguage: _setTranslateTo,
            onClose: () => setState(() => _lookup = null),
          ),
        ),
      if (_assistantOpen && _assistant != null && wide)
        ..._sidePanel(
          'assistant',
          AssistantPanel(
            key: const ValueKey('assistant-panel'),
            ai: widget.ai!,
            chat: _assistant!,
            onClose: () => setState(() => _assistantOpen = false),
            onJumpToPage: _jumpToPage,
            onAddToNote: _addGenerated,
            flashcards: _on(Feature.flashcards),
            onMake: (kind) => _openNoteAi(kind),
          ),
        ),
      if (_historyOpen && widget.history != null && wide) ..._sidePanel('history', _historyPanel(onClose: () => setState(() => _historyOpen = false))),
      if (_generatedOpen && widget.ai != null && wide) ..._sidePanel('generated', _generatedPanel(onClose: () => setState(() => _generatedOpen = false))),
      if (_layersOpen && wide) ..._sidePanel('layers', _layersPanel(onClose: () => setState(() => _layersOpen = false))),
      if (_outlineOpen && wide) ..._sidePanel('outline', _outlinePanel(onClose: () => setState(() => _outlineOpen = false))),
      if (_findOpen && wide) ..._sidePanel('find', _findPanel()),
      if (_pictureEditing != null && wide) ..._sidePanel('picture-edit', _pictureEditPanel()),
      if (_stampsOpen && wide) ..._sidePanel('stamps', _stampsPanel(onClose: () => setState(() => _stampsOpen = false))),
      if (_audioOpen && widget.audio != null && wide) ..._sidePanel('audio', _audioPanel(onClose: () => setState(() => _audioOpen = false))),
    ];
    // (the bars slide in and out, so that the page does not jump aside)
    return PageWithSideBars(
      pages: pages,
      pagesDrop: _rulerExtent,
      pagesScale: () => _pageScale,
      // (the panels fill the height, whatever they hold)
      panels: panelItems.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: panelItems),
      first: draw ? _beside(_buildDrawToolBar()) : null,
      second: _documentBarAtSide ? _beside(SteadyBar(child: _documentSideBar())) : null,
    );
  }

  /// A bar at the side of the page, with the thin line between it and the page.
  Widget _beside(Widget bar) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const VerticalDivider(width: 1, thickness: 1), bar],
      );

  /// Asks which part of the plane an empty plot shows, and puts it on the page.
  Future<void> _addEmptyPlot() => showDialog<void>(
    context: context,
    builder: (context) =>
        EmptyPlotDialog(onAdd: (png, size) => _placeImage(png, keepMode: true)),
  );

  /// Asks how the next shapes look.
  Future<void> _chooseShapeStyle() async {
    final style = await showShapeStyleDialog(
      context,
      ShapeStyle(
        color: _selectedPenColor,
        width: _strokeWidth,
        dash: _shapeDash,
        fill: _shapeFill,
        gradient: _shapeGradient,
      ),
    );
    if (style == null || !mounted) return;
    setState(() {
      _selectedPenColor = style.color;
      _strokeWidth = style.width;
      _shapeDash = style.dash;
      _shapeFill = style.fill;
      _shapeGradient = style.gradient;
    });
  }

  /// The brushes the person can choose: the pen, the roller and the others that come with the app (if their tools are on) and those
  /// of extensions.
  List<Brush> get _availableBrushes => [
    for (final b in Brushes.all)
      if (Brushes.isListed(b.id) &&
          (b.id != rollerBrushId || _on(Feature.roller)) &&
          (!Brushes.creative.contains(b) || _on(Feature.brushes)))
        b,
  ];

  /// The menu item that opens the brush designer (it is not the id of a brush).
  static const _designBrushes = '\u0000design';

  /// Chooses the brush the pen draws with, among those there are (the pen, the roller, and those of extensions).
  Widget _brushButton() {
    final scheme = Theme.of(context).colorScheme;
    final brush = Brushes.byId(_brush) ?? Brushes.pen;
    final chosen =
        _brush != penBrushId && !_erasing && !_lassoing && !_highlighter;
    return PopupMenuButton<String>(
      key: const ValueKey('brush-picker'),
      tooltip: tr('Brush: {brush}', {'brush': tr(brush.label)}),
      position: PopupMenuPosition.under,
      initialValue: _brush,
      onSelected: (id) async {
        if (id == _designBrushes) {
          final made = await showBrushDesigner(context, BrushLibrary(widget.repository.settings));
          if (made == null || !mounted || Brushes.byId(made) == null) return;
          id = made;
        }
        setState(() {
          _brush = id;
          _highlighter = false;
          _erasing = false;
          _lassoing = false;
          _bucket = false;
          _lassoPath = null;
        });
      },
      itemBuilder: (context) => [
        for (final b in _availableBrushes)
          PopupMenuItem(
            key: ValueKey('brush-${b.id}'),
            value: b.id,
            child: Row(
              children: [
                Icon(b.icon, size: 20),
                const SizedBox(width: 12),
                // (the name of a brush that was designed can be long)
                Flexible(child: Text(tr(b.label), overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        if (_on(Feature.brushes)) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            key: const ValueKey('brush-design'),
            value: _designBrushes,
            child: Row(
              children: [
                const Icon(Icons.tune, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(tr('Design a brush...'), overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ],
      ],
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: chosen ? scheme.secondaryContainer : null,
        ),
        child: Icon(
          Icons.brush_outlined,
          size: 20,
          color: chosen ? scheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  /// How steady the line is: nothing, or a string of some length between the pen and the line.
  Widget _stabiliserButton() {
    final scheme = Theme.of(context).colorScheme;
    const levels = [
      ('Off', 0.0),
      ('Light', 0.25),
      ('Medium', 0.55),
      ('Strong', 0.9),
    ];
    final on = _stabiliserStrength > 0;
    final current = levels.lastWhere((l) => l.$2 <= _stabiliserStrength + 1e-9);
    return PopupMenuButton<double>(
      key: const ValueKey('stabiliser-picker'),
      tooltip: tr('Line stabiliser: {level}', {'level': tr(current.$1)}),
      position: PopupMenuPosition.under,
      onSelected: (v) {
        setState(() => _stabiliserStrength = v);
        widget.repository.settings.set('stabiliser_strength', '$v');
      },
      itemBuilder: (context) => [
        for (final (name, v) in levels)
          CheckedPopupMenuItem(
            key: ValueKey('stabiliser-$name'),
            value: v,
            checked: v == current.$2,
            child: Text(tr(name)),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? scheme.secondaryContainer : null,
        ),
        child: Icon(
          Icons.timeline,
          size: 20,
          color: on ? scheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  /// Chooses how lines are repeated while drawing (a mirror, or turns around the centre of the page).
  Widget _symmetryButton() {
    final scheme = Theme.of(context).colorScheme;
    final on = !_symmetry.isOff;
    return PopupMenuButton<Object>(
      key: const ValueKey('symmetry-picker'),
      tooltip: tr('Symmetry: {kind}', {'kind': tr(_symmetry.kind.label)}),
      position: PopupMenuPosition.under,
      onSelected: (v) => setState(() {
        if (v is Symmetry) {
          _symmetry = v;
        } else {
          _symmetryAt = const Offset(0.5, 0.5); // "Centre it again"
        }
      }),
      itemBuilder: (context) => [
        for (final k in SymmetryKind.values)
          CheckedPopupMenuItem(
            key: ValueKey('symmetry-${k.name}'),
            value: k == _symmetry.kind
                ? _symmetry
                : Symmetry(k, turns: _symmetry.turns),
            checked: k == _symmetry.kind,
            child: Text(tr(k.label)),
          ),
        if (_symmetry.hasTurns) ...[
          const PopupMenuDivider(),
          for (final n in const [3, 4, 5, 6, 8, 10, 12])
            CheckedPopupMenuItem(
              key: ValueKey('symmetry-turns-$n'),
              value: _symmetry.withTurns(n),
              checked: _symmetry.turns == n,
              child: Text(tr('{n} turns', {'n': '$n'})),
            ),
        ],
        if (!_symmetry.isOff) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            key: const ValueKey('symmetry-centre'),
            value: 'centre',
            enabled: _symmetryAt != const Offset(0.5, 0.5),
            child: Text(tr('Centre it on the page again')),
          ),
        ],
      ],
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? scheme.secondaryContainer : null,
        ),
        child: Icon(
          Icons.flip,
          size: 20,
          color: on ? scheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  /// Chooses a drawing tool of an extension, or the plain pen again.
  Widget _drawToolButton() {
    final scheme = Theme.of(context).colorScheme;
    final tools = widget.extensions?.drawTools ?? const [];
    final active = _activeDrawTool;
    return PopupMenuButton<int>(
      key: const ValueKey('draw-tool-picker'),
      tooltip: active == null
          ? tr('Drawing tools of extensions')
          : tr('Drawing tool: {tool}', {'tool': active.tool.title}),
      position: PopupMenuPosition.under,
      onSelected: (i) => setState(() {
        if (i < 0) {
          _chosenDrawTool = null;
          _shape = ShapeTool.freehand;
          return;
        }
        final t = tools[i];
        _chosenDrawTool = t;
        _shape = switch (t.tool.preview) {
          DrawPreview.path => ShapeTool.freehand,
          DrawPreview.line => ShapeTool.line,
          DrawPreview.rect => ShapeTool.rectangle,
          DrawPreview.ellipse => ShapeTool.ellipse,
        };
        _highlighter = false;
        _erasing = false;
        _lassoing = false;
        _bucket = false;
        _lassoPath = null;
      }),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: -1,
          child: Row(
            children: [
              const Icon(Icons.edit_outlined, size: 20),
              const SizedBox(width: 12),
              Text(tr('Plain pen')),
            ],
          ),
        ),
        for (var i = 0; i < tools.length; i++)
          PopupMenuItem(
            key: ValueKey(
              'draw-tool-${tools[i].extension.id}-${tools[i].tool.id}',
            ),
            value: i,
            child: Row(
              children: [
                const Icon(Icons.auto_fix_high, size: 20),
                const SizedBox(width: 12),
                Text.verbatim(
                  _EditorExtensions.toolLabel(
                    tools[i].extension,
                    ExtensionTool(tools[i].tool.id, tools[i].tool.title),
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active != null ? scheme.secondaryContainer : null,
        ),
        child: Icon(
          Icons.auto_fix_high,
          size: 20,
          color: active != null ? scheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  /// Chooses what a drag with the pen draws: the hand's own line, or a shape.
  Widget _shapeButton() {
    final scheme = Theme.of(context).colorScheme;
    final shaped = _shape != ShapeTool.freehand && !_erasing && !_lassoing;
    return PopupMenuButton<ShapeTool>(
      key: const ValueKey('shape-tool'),
      tooltip: tr(
        'Shapes: {shape} (hold Shift for even sides and 45 degrees)',
        {'shape': tr(_shape.label)},
      ),
      position: PopupMenuPosition.under,
      initialValue: _shape,
      onSelected: (tool) => setState(() {
        _shape = tool;
        _chosenDrawTool = null;
        _erasing = false;
        _lassoing = false;
        _bucket = false;
        _lassoPath = null;
      }),
      itemBuilder: (context) => [
        for (final tool in ShapeTool.values)
          PopupMenuItem(
            key: ValueKey('shape-${tool.name}'),
            value: tool,
            child: Row(
              children: [
                _shapeIcon(tool),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(tr(tool.label), overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: shaped ? scheme.secondaryContainer : null,
        ),
        child: _shapeIcon(
          _shape,
          color: shaped ? scheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  Widget _buildDrawToolBar() {
    final colors = drawColors;
    final primary = Theme.of(context).colorScheme.primary;

    final tools = <Widget>[
      Center(
        heightFactor: 1,
        child: IconButton(
          key: const ValueKey('undo-button'),
          icon: const Icon(Icons.undo_rounded, size: 22),
          tooltip: tr('Undo'),
          onPressed: _undoStack.canUndo ? _undoDrawing : null,
        ),
      ),
      Center(
        heightFactor: 1,
        child: IconButton(
          key: const ValueKey('redo-button'),
          icon: const Icon(Icons.redo_rounded, size: 22),
          tooltip: tr('Redo'),
          onPressed: _undoStack.canRedo ? _redoDrawing : null,
        ),
      ),
      const ToolGroupDivider(width: 32, height: 24),
      if (_availableBrushes.length > 1) Center(heightFactor: 1, child: _brushButton()),
      if (_on(Feature.highlighter))
        Center(
          heightFactor: 1,
          child: IconButton.filledTonal(
            isSelected: _highlighter,
            style: toggleToolStyle(context),
            selectedIcon: const Icon(Icons.border_color, size: 20),
            icon: const Icon(Icons.border_color_outlined, size: 20),
            tooltip: tr('Highlighter (see-through, in the chosen color)'),
            onPressed: () => setState(() {
              _highlighter = !_highlighter;
              _picking = false;
              _bucket = false;
              _brush = penBrushId;
              _erasing = false;
              _lassoing = false;
            }),
          ),
        ),
      if ((widget.extensions?.drawTools ?? const []).isNotEmpty)
        Center(heightFactor: 1, child: _drawToolButton()),
      if (_on(Feature.layers)) Center(heightFactor: 1, child: _layersButton()),
      const SizedBox(height: 8),
      const SizedBox(height: 8),
      if (_on(Feature.shapes)) ...[
        Center(heightFactor: 1, child: _shapeButton()),
        if (_shape != ShapeTool.freehand && !_erasing && !_lassoing)
          Center(
            heightFactor: 1,
            child: IconButton(
              key: const ValueKey('shape-style'),
              tooltip: tr('Style of the shapes: line, dashes and fill'),
              icon: Icon(
                Icons.format_color_fill,
                size: 20,
                color: _shapeFill ?? _selectedPenColor,
              ),
              onPressed: _chooseShapeStyle,
            ),
          ),
        if (_connecting) Center(heightFactor: 1, child: _routeButton()),
        const SizedBox(height: 8),
      ],
      Center(
        heightFactor: 1,
        child: IconButton.filledTonal(
          isSelected: _erasing,
            style: toggleToolStyle(context),
          selectedIcon: const Icon(Icons.auto_fix_normal, size: 20),
          icon: const Icon(Icons.auto_fix_normal_outlined, size: 20),
          tooltip: tr('Eraser (drawings only)'),
          onPressed: () => setState(() {
            _erasing = !_erasing;
            _picking = false;
            _bucket = false;
            _lassoing = false;
            _highlighter = false;
            _brush = penBrushId;
          }),
        ),
      ),
      const SizedBox(height: 8),
      const SizedBox(height: 8),
      if (_on(Feature.lasso))
        Center(
          heightFactor: 1,
          child: IconButton.filledTonal(
            isSelected: _lassoing,
            style: toggleToolStyle(context),
            selectedIcon: const Icon(Icons.gesture, size: 20),
            icon: const Icon(Icons.gesture, size: 20),
            tooltip: tr(
              'Lasso: draw around drawings, text boxes and pictures to select them',
            ),
            onPressed: () => setState(() {
              _lassoing = !_lassoing;
              _picking = false;
              _bucket = false;
              _erasing = false;
              _highlighter = false;
              _brush = penBrushId;
              if (!_lassoing) _lassoPath = null;
            }),
          ),
        ),
      const SizedBox(height: 8),
      const ToolGroupDivider(width: 32, height: 24),
      for (final color in [...colors, ..._customColors])
        Center(
          heightFactor: 1,
          child: GestureDetector(
            onLongPress:
                _customColors.any((c) => c.toARGB32() == color.toARGB32())
                ? () =>
                      _removeCustomColor(color) // only added colours can go
                : null,
            onTap: () => setState(() {
              _selectedPenColor = color;
              _picking = false;
              _erasing = false;
              _lassoing = false;
            }),
            child: Semantics(
              button: true,
              selected:
                  !_erasing &&
                  !_lassoing &&
                  _selectedPenColor.toARGB32() == color.toARGB32(),
              label: tr('Pen color: {color}', {'color': colorName(color)}),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        !_erasing &&
                            !_lassoing &&
                            _selectedPenColor.toARGB32() == color.toARGB32()
                        ? primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: CircleAvatar(radius: 9, backgroundColor: color),
              ),
            ),
          ),
        ),
      Center(
        heightFactor: 1,
        child: IconButton(
          icon: const Icon(Icons.add_circle_outline, size: 22),
          tooltip: tr('Add a color (hold an added color to remove it)'),
          onPressed: _addCustomColor,
        ),
      ),
      Center(
        heightFactor: 1,
        child: IconButton(
          key: const ValueKey('color-harmonies'),
          icon: const Icon(Icons.palette_outlined, size: 22),
          tooltip: tr('Color harmonies: complementary, triadic and analogous colors from the pen color'),
          onPressed: _chooseHarmony,
        ),
      ),
      if (_on(Feature.colorPicker))
        Center(
          heightFactor: 1,
          child: IconButton.filledTonal(
            key: const ValueKey('eyedropper-button'),
            isSelected: _picking,
            style: toggleToolStyle(context),
            selectedIcon: const Icon(Icons.colorize, size: 20),
            icon: const Icon(Icons.colorize_outlined, size: 20),
            tooltip: tr('Eyedropper: touch anything on the page to draw in its color (I)'),
            onPressed: _toggleEyedropper,
          ),
        ),
      if (_on(Feature.fillBucket)) ...[
        Center(
          heightFactor: 1,
          child: IconButton.filledTonal(
            key: const ValueKey('fill-bucket-button'),
            isSelected: _bucketOn,
            style: toggleToolStyle(context),
            selectedIcon: const Icon(Icons.format_color_fill, size: 20),
            icon: const Icon(Icons.format_color_fill, size: 20),
            tooltip: tr('Fill bucket: touch a closed area to fill it with the pen color (G)'),
            onPressed: _toggleBucket,
          ),
        ),
        if (_bucketOn) Center(heightFactor: 1, child: _fillGapButton()),
      ],
      const ToolGroupDivider(width: 32, height: 24),
      Center(
        heightFactor: 1,
        child: PopupMenuButton<double>(
          tooltip: tr('Stroke Size'),
          position: PopupMenuPosition.under,
          icon: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width:
                    6 +
                    (_highlighter ? _highlighterWidth / 2 : _strokeWidth).clamp(
                      1.5,
                      20.0,
                    ),
                height:
                    6 +
                    (_highlighter ? _highlighterWidth / 2 : _strokeWidth).clamp(
                      1.5,
                      20.0,
                    ),
                decoration: BoxDecoration(
                  color: _selectedPenColor,
                  shape: BoxShape.circle,
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 16),
            ],
          ),
          onSelected: (newWidth) => setState(() {
            if (_highlighter) {
              _highlighterWidth = newWidth;
            } else {
              _strokeWidth = newWidth;
            }
          }),
          itemBuilder: (context) => [
            if (_highlighter)
              for (final (width, label) in _highlighterWidthOptions)
                PopupMenuItem(value: width, child: Text(label))
            else
              for (final (width, label) in _penWidthOptions)
                PopupMenuItem(value: width, child: Text(label)),
            const PopupMenuDivider(),
            _customWidthSlider(),
          ],
        ),
      ),
      const SizedBox(height: 8),
      const SizedBox(height: 8),
      const ToolGroupDivider(width: 32, height: 24),
      Center(
        heightFactor: 1,
        child: IconButton(
          key: const ValueKey('more-tools'),
          icon: Icon(_moreTools ? Icons.expand_less : Icons.more_horiz, size: 22),
          tooltip: _moreTools ? tr('Fewer tools') : tr('More tools: guides, stabiliser, symmetry, onion skin, straightening, clear the page'),
          onPressed: () {
            setState(() => _moreTools = !_moreTools);
            unawaited(widget.repository.settings.set('draw_bar_more', _moreTools ? '1' : '0'));
          },
        ),
      ),
      if (_moreTools) ...[
      Center(
        heightFactor: 1,
        child: IconButton(
          key: const ValueKey('clear-page'),
          icon: const Icon(Icons.cleaning_services_outlined, size: 22),
          tooltip: tr('Clear the drawings and highlights on this page'),
          onPressed: _clearPage,
        ),
      ),
      if (_on(Feature.flipbook) && !_infinite) Center(heightFactor: 1, child: _onionButton()),
      if (_on(Feature.guides)) Center(heightFactor: 1, child: _guidesButton()),
      if (_on(Feature.stabiliser)) Center(heightFactor: 1, child: _stabiliserButton()),
      if (_on(Feature.symmetry)) Center(heightFactor: 1, child: _symmetryButton()),
      if (_on(Feature.straighten))
        Center(
          heightFactor: 1,
          child: IconButton.filledTonal(
            key: const ValueKey('straighten-toggle'),
            isSelected: _straighten,
            style: toggleToolStyle(context),
            selectedIcon: const Icon(Icons.show_chart, size: 20),
            icon: const Icon(Icons.show_chart, size: 20),
            tooltip: tr(
              _straighten
                  ? 'Straight lines and shapes: on (lines drawn nearly straight are straightened, and drawings very close to a rectangle, ellipse, triangle or diamond become that shape)'
                  : 'Straight lines and shapes: off',
            ),
            onPressed: () {
              setState(() => _straighten = !_straighten);
              widget.repository.settings.set(
                'straighten_lines',
                _straighten ? '1' : '0',
              );
            },
          ),
        ),
      if (_on(Feature.plots)) ...[
        Center(
          heightFactor: 1,
          child: IconButton(
            key: const ValueKey('empty-plot'),
            icon: const Icon(Icons.auto_graph, size: 22),
            tooltip: tr('Place an empty plot to draw into'),
            onPressed: _addEmptyPlot,
          ),
        ),
      ],
      ],
    ];
    return Container(
      decoration: BoxDecoration(color: toolBarColor(context), border: toolBarEdge(context, left: true)),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      // (as wide as the tools, which the larger touch targets make wider)
      child: ToolColumns(children: tools),
    );
  }
}

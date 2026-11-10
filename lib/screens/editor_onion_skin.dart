part of 'fixed_page_note_editor.dart';

/// Onion skin for drawing frames of an animation (see the flipbook): the lines of the pages before the one being drawn - up to three,
/// fainter the further back - show through in red, and the next page, if asked, in green. Only in the drawing mode, and not on a canvas.
extension _EditorOnionSkin on _FixedPageNoteEditorState {
  static const _backColor = Color(0xFFE53935), _nextColor = Color(0xFF43A047);
  static const _backOpacity = [0.30, 0.18, 0.10];

  bool get _onionOn => _mode == CanvasInteractionMode.draw && !_infinite && _on(Feature.flipbook) && (_onionBack > 0 || _onionNext);

  /// The ghosts over page [pageIndex], or none.
  List<Widget> _onionLayers(int pageIndex, double pageHeight) {
    if (!_onionOn) return const [];
    final ghosts = <OnionGhost>[
      for (var k = _onionBack; k >= 1; k--)
        if (pageIndex - k >= 0 && (_strokesPerPage[pageIndex - k] ?? const <DrawingStroke>[]).isNotEmpty) OnionGhost(_strokesPerPage[pageIndex - k]!, _backColor, _backOpacity[k - 1]),
      if (_onionNext && (_strokesPerPage[pageIndex + 1] ?? const <DrawingStroke>[]).isNotEmpty) OnionGhost(_strokesPerPage[pageIndex + 1]!, _nextColor, 0.25),
    ];
    if (ghosts.isEmpty) return const [];
    return [
      IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            key: ValueKey('onion-skin-$pageIndex'),
            painter: OnionSkinPainter(ghosts, layers: _layers, pressureSensitivity: widget.stylus?.effectiveSensitivity ?? 0.6),
            size: Size(_paperWidth, pageHeight),
          ),
        ),
      ),
    ];
  }

  void _setOnion({int? back, bool? next}) {
    setState(() {
      if (back != null) _onionBack = back.clamp(0, 3);
      if (next != null) _onionNext = next;
    });
    widget.repository.settings.set('onion_back', '$_onionBack');
    widget.repository.settings.set('onion_next', _onionNext ? '1' : '0');
  }

  /// How many earlier pages show through, and whether the next one does.
  Widget _onionButton() => PopupMenuButton<String>(
        key: const ValueKey('onion-skin'),
        tooltip: tr('Onion skin: show the pages before and after this one faintly, to draw the frames of an animation'),
        position: PopupMenuPosition.under,
        icon: Icon(Icons.layers_outlined, size: 20, color: _onionBack > 0 || _onionNext ? Theme.of(context).colorScheme.primary : null),
        onSelected: (v) {
          if (v == 'next') {
            _setOnion(next: !_onionNext);
          } else {
            _setOnion(back: int.parse(v));
          }
        },
        itemBuilder: (context) => [
          for (var n = 0; n <= 3; n++)
            CheckedPopupMenuItem(
              key: ValueKey('onion-back-$n'),
              value: '$n',
              checked: _onionBack == n,
              child: Text(n == 0 ? tr('No earlier page') : trCount(n, '1 earlier page (red)', '{n} earlier pages (red)')),
            ),
          const PopupMenuDivider(),
          CheckedPopupMenuItem(key: const ValueKey('onion-next'), value: 'next', checked: _onionNext, child: Text(tr('The next page (green)'))),
        ],
      );
}

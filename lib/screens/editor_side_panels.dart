part of 'fixed_page_note_editor.dart';

/// The panels that stand beside the pages on a wide screen (the layers, the outline, the sounds, the assistant, the history, what the
/// AI made, a look-up): one at a time, one width for all of them, a thin bar between them and the note to drag. On a narrow screen
/// each of them is a dialog, a sheet or a page over the note instead.
extension _EditorSidePanels on _FixedPageNoteEditorState {
  /// Whether the screen has room for a panel beside the pages.
  bool get _roomForSidePanel => MediaQuery.of(context).size.width >= _sidePanelFrom;

  /// Shuts every panel beside the pages. Call it inside setState, before opening another one, so that only one is open.
  void _closeSidePanels() {
    _lookup = null;
    _assistantOpen = false;
    _historyOpen = false;
    _generatedOpen = false;
    _layersOpen = false;
    _outlineOpen = false;
    _audioOpen = false;
    _stampsOpen = false;
    _endPictureEdit(null);
  }

  /// Opens the panel set by [open] beside the pages (and shuts the others), or shuts it if [isOpen].
  void _toggleSidePanel(bool isOpen, void Function() open) {
    _closeFindForPanel();
    setState(() {
      _closeSidePanels();
      if (!isOpen) open();
    });
  }

  /// The resize bar and the box of the panel [name] (its bar is keyed '[name]-resize').
  List<Widget> _sidePanel(String name, Widget child) {
    final maxWidth = MediaQuery.of(context).size.width * 0.7;
    return [
      MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          key: ValueKey('$name-resize'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => setState(() => _lookupWidth = (_lookupWidth - d.delta.dx).clamp(280.0, maxWidth)),
          child: SizedBox(
            width: 14,
            child: Center(child: Container(width: 4, height: 48, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2)))),
          ),
        ),
      ),
      SizedBox(width: _lookupWidth.clamp(280.0, maxWidth), child: child),
    ];
  }
}

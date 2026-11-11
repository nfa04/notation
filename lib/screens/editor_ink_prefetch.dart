part of 'fixed_page_note_editor.dart';

/// Reading the writing ahead of time: see [NoteInkReader] (which does the work) and [InkPrefetcher]. It is started by the automation
/// "Read the writing and formulas ahead of time" when the note is opened, and used when a selection is converted.
extension _EditorInkPrefetch on _FixedPageNoteEditorState {
  /// The background reader, once something asked for it.
  InkPrefetcher? get _ink => _reader.prefetcher;

  /// Whether worked maths is being checked line by line.
  bool get _checkOn => _reader.checkOn;
  set _checkOn(bool on) => _reader.checkOn = on;

  Future<String?> _startInk() => _reader.start();

  /// A good moment to read in the background: the person is not drawing and the app is on screen.
  bool _inkQuiet() =>
      mounted && _currentActiveStroke == null && WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused && WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;

  /// [icon] of a conversion button, with a green dot when what is selected has been read already (the result is
  /// there at once).
  Widget _readyDot(IconData icon, {required bool math}) {
    final ready = _ink?.isReady(_selection, math: math) ?? false;
    return Badge(
      key: ValueKey('ink-ready-${math ? 'math' : 'text'}-$ready'),
      isLabelVisible: ready,
      smallSize: 8,
      backgroundColor: Colors.green,
      child: Icon(icon),
    );
  }

  /// Readings arrived: the marks, the underlines and the buttons are brought up to date once, at the next frame, however many
  /// arrived before it.
  void _inkProgressed() {
    if (_inkRefreshDue) return;
    _inkRefreshDue = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _inkRefreshDue = false;
      if (!mounted) return;
      if (_checkOn) _marks = _currentMarks();
      _refreshInkSpelling();
      setState(() {}); // (the buttons over a selection show whether it is ready)
    });
  }

  /// Says that the writing is being read and how many blocks are left; disappears when there are none. A tap on the cross hides it
  /// until the note is opened again.
  Widget _inkProgressChip() => ValueListenableBuilder<int>(
        valueListenable: _reader.pending,
        builder: (context, waiting, _) {
          if (waiting <= 0) return const SizedBox.shrink();
          final scheme = Theme.of(context).colorScheme;
          return Material(
            key: const ValueKey('ink-progress'),
            elevation: 2,
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSecondaryContainer)),
                const SizedBox(width: 8),
                Text(trCount(waiting, 'Reading the handwriting: 1 left', 'Reading the handwriting: {n} left'), style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer)),
                IconButton(
                  key: const ValueKey('ink-progress-hide'),
                  tooltip: tr('Hide'),
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
                  onPressed: () => setState(() => _inkChipHidden = true),
                ),
              ]),
            ),
          );
        },
      );
}

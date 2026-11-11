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
}

/// One thing that can be taken back and done again.
class UndoStep {
  final void Function() undo;
  final void Function() redo;

  const UndoStep(this.undo, this.redo);
}

/// What was done, newest last, to be taken back one at a time. Doing something
/// new after taking back forgets what could have been done again.
class UndoStack {
  /// Steps kept; the oldest go first.
  final int limit;

  UndoStack({this.limit = 200});

  final List<UndoStep> _done = [];
  final List<UndoStep> _undone = [];

  /// Called after each step is pushed.
  void Function()? onPush;

  bool get canUndo => _done.isNotEmpty;
  bool get canRedo => _undone.isNotEmpty;

  void push(UndoStep step) {
    _done.add(step);
    if (_done.length > limit) _done.removeAt(0);
    _undone.clear();
    onPush?.call();
  }

  /// Takes back the last step; false if there is none.
  bool undo() {
    if (_done.isEmpty) return false;
    final step = _done.removeLast();
    step.undo();
    _undone.add(step);
    return true;
  }

  /// Does the last step taken back again; false if there is none.
  bool redo() {
    if (_undone.isEmpty) return false;
    final step = _undone.removeLast();
    step.redo();
    _done.add(step);
    return true;
  }

  void clear() {
    _done.clear();
    _undone.clear();
  }
}

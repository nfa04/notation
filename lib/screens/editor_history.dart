part of 'fixed_page_note_editor.dart';

/// Earlier versions of the note: looking at them, comparing, and going back to one.
extension _EditorHistory on _FixedPageNoteEditorState {
  /// The history beside the note on a wide screen (resizable, like the web pages), else as a page over it.
  void _openHistory() {
    if (_roomForSidePanel) {
      _toggleSidePanel(_historyOpen, () => _historyOpen = true);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (context) => Scaffold(body: SafeArea(child: _historyPanel(onClose: () => Navigator.pop(context)))),
    ));
  }

  Widget _historyPanel({required VoidCallback onClose}) => HistoryPanel(
        history: widget.history!,
        noteId: widget.noteId,
        current: () async {
          await _saveNow();
          return _snapshot();
        },
        restore: _restoreVersion,
        apply: _applyVersion,
        applyChanges: _applyChanges,
        onClose: onClose,
      );

  /// Makes the note what it was in [version]. The note as it is now is kept as a version first. In a live session
  /// the others get the change like any other.
  Future<void> _restoreVersion(NoteVersion version) async {
    await _saveNow();
    await widget.history!.snapshot(widget.noteId, reason: VersionReason.restore);
    await _applyVersion(version);
  }

  /// Makes the note what it was in [version], without keeping the note as it is (the caller did, as on switching branch).
  Future<void> _applyVersion(NoteVersion version) async {
    final history = widget.history!;
    await _saveNow();
    await _applyChanges(await history.restoreChanges(version, _snapshot()));
  }

  /// Puts changes into the note (a restored version, a merged branch). In a live session the others get them like any other change.
  Future<void> _applyChanges(List<CollabOp> changes) async {
    final history = widget.history!;
    if (changes.isEmpty || !mounted) return;
    final live = _live;
    if (live != null && live.state != SessionState.ended && live.hasScreen) {
      live.applyExternal(changes);
    } else {
      final saver = await history.pictureSaver();
      if (!mounted) return;
      final raw = Replica('restore');
      setState(() {
        final note = _snapshot();
        for (final op in changes) {
          raw.apply(note, op,
              makeBox: (id) {
                final b = TextBoxWidgetModel(id: id, position: Offset.zero);
                _attachBox(b);
                return b;
              },
              saveImage: saver,
              onNoteField: _takeNoteField);
        }
      });
      _live?.localChanged();
    }
    await _saveNow();
  }
}

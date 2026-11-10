part of 'fixed_page_note_editor.dart';

/// Locking this note, and what a locked note offers.
extension _EditorLock on _FixedPageNoteEditorState {
  Widget _lockButton() {
    final locked = _lockMode != LockMode.none;
    return PopupMenuButton<String>(
      key: const ValueKey('lock-note'),
      tooltip: tr(locked ? 'This note is locked' : 'Lock this note'),
      icon: Icon(locked ? Icons.lock : Icons.lock_open_outlined, size: 20, color: locked ? Theme.of(context).colorScheme.primary : null),
      onSelected: _lockAction,
      itemBuilder: (_) => [
        if (!locked) PopupMenuItem(value: 'lock', child: Text('Lock this note...')),
        if (locked) ...[
          PopupMenuItem(value: 'now', child: Text('Lock now')),
          PopupMenuItem(value: 'change', child: Text(_lockMode == LockMode.encrypted ? 'Change the passphrase...' : 'Change the passcode...')),
          PopupMenuItem(value: 'remove', child: Text('Take the lock off')),
        ],
      ],
    );
  }

  Future<void> _lockAction(String action) async {
    final locks = widget.locks;
    if (locks == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'lock':
          // what is shared live cannot be locked (the others would still have it)
          if (_live != null) {
            messenger.showSnackBar(SnackBar(content: Text('End the live session of this note before locking it.')));
            return;
          }
          final mode = await lockNoteDialog(
            context,
            locks,
            widget.noteId,
            beforeEncrypting: () async {
              await _saveNow();
              _sealedAway = true; // from here on nothing of it is written back
            },
            afterEncrypting: () => widget.onLeave?.call(),
          );
          if (mode != null && mounted) setState(() => _lockMode = mode);
        case 'now':
          widget.onLeave?.call();
        case 'change':
          final ok = await changeSecretDialog(context, locks, widget.noteId);
          if (ok) messenger.showSnackBar(SnackBar(content: Text('The lock was changed.')));
        case 'remove':
          if (await locks.removeLock(widget.noteId) && mounted) {
            setState(() => _lockMode = LockMode.none);
            messenger.showSnackBar(SnackBar(content: Text('The lock was taken off.')));
          }
      }
    } catch (e) {
      _sealedAway = false;
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not lock the note: {error}', {'error': e}))));
    }
  }
}

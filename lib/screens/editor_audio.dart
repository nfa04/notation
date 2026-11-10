part of 'fixed_page_note_editor.dart';

/// Stands in for the player's changes until there is a player.
final _noPlayer = ValueNotifier<int>(0);

/// The sounds kept with the note, and reading the note into a sound file.
extension _EditorAudio on _FixedPageNoteEditorState {
  SoundPlayer get _sounds {
    var player = _soundPlayer;
    if (player == null) {
      player = _soundPlayer = widget.soundPlayer?.call() ?? SoundPlayer();
      player.addListener(_onSoundTick);
    }
    return player;
  }

  Widget _audioButton() => ListenableBuilder(
        listenable: _soundPlayer ?? _noPlayer,
        builder: (context, _) => IconButton(
          key: const ValueKey('audio-button'),
          tooltip: tr('Sound kept with this note'),
          visualDensity: VisualDensity.compact,
          icon: Icon((_soundPlayer?.playing ?? false) ? Icons.graphic_eq : Icons.headphones_outlined, size: 20, color: _audioOpen ? Theme.of(context).colorScheme.primary : null),
          onPressed: _openAudio,
        ),
      );

  /// The sounds beside the note on a wide screen: a sound can go on while the person writes, and the lines written to it light up.
  Widget _audioPanel({required VoidCallback onClose}) {
    final reader = widget.readAloud;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: AudioPanel(
        key: const ValueKey('audio-panel'),
        noteId: widget.noteId,
        audio: widget.audio!,
        player: _sounds,
        canMakeReading: reader?.canSynthesize ?? Future.value(false),
        onMakeReading: reader == null ? null : _makeReading,
        onClose: onClose,
      ),
    );
  }

  Future<void> _openAudio() async {
    final audio = widget.audio;
    if (audio == null) return;
    if (_roomForSidePanel) {
      _toggleSidePanel(_audioOpen, () => _audioOpen = true);
      return;
    }
    final reader = widget.readAloud;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (sheet) => SizedBox(
        height: MediaQuery.of(sheet).size.height * 0.6,
        child: AudioPanel(
          noteId: widget.noteId,
          audio: audio,
          player: _sounds,
          canMakeReading: reader?.canSynthesize ?? Future.value(false),
          onMakeReading: reader == null ? null : _makeReading,
          onClose: () => Navigator.pop(sheet),
        ),
      ),
    );
    // (a sound goes on playing when the panel is closed; the button shows that it does)
    if (mounted) setState(() {});
  }

  /// Reads the whole note (its title, written document and text boxes, as [_readAloud] does) into a sound file kept with the note.
  Future<void> _makeReading(void Function(int done, int total) onProgress, AiCancel cancel) async {
    final reader = widget.readAloud, audio = widget.audio;
    if (reader == null || audio == null) return;
    final index = await _documentIndex();
    final text = speakableText(index.chunks.map((c) => c.text).join('\n'));
    if (text.trim().isEmpty) throw StateError(tr('There is nothing to read yet.'));
    final wav = await reader.synthesize(text, language: AppLanguage.instance.code, onProgress: onProgress, cancel: cancel);
    if (cancel.cancelled) return;
    if (wav == null) throw StateError(tr('This device cannot save a voice as a file.'));
    final title = _titleController.text.trim();
    await audio.add(widget.noteId, wav, kind: AudioKind.speech, title: tr('{title} read aloud', {'title': title.isEmpty ? tr('Untitled Note') : title}));
  }
}

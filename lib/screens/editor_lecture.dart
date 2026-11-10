part of 'fixed_page_note_editor.dart';

/// Lights up the places of the lines that are being said at this moment of the sound.
class _FollowPainter extends CustomPainter {
  final List<Rect> rects;
  final Color color;
  const _FollowPainter(this.rects, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // (one path, so that boxes that overlap are not darker where they do)
    final path = Path();
    for (final r in rects) {
      path.addRRect(RRect.fromRectAndRadius(r.inflate(2), const Radius.circular(6)));
    }
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.16));
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.7)..style = PaintingStyle.stroke..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_FollowPainter old) => !listEquals(old.rects, rects) || old.color != color;
}

/// Recording the sound while the note is written, and playing it from the line that was being written (sound-synced notes). While the
/// recording goes on, every stroke and text box that appears is marked with the moment it appeared; the marks are kept with the sound.
extension _EditorLecture on _FixedPageNoteEditorState {
  /// The ids of the strokes and text boxes of every page.
  Map<int, List<String>> _elementIds() => {
        for (final e in _strokesPerPage.entries) e.key: [for (final s in e.value) s.id],
        for (final e in _textBoxesPerPage.entries) e.key: [for (final b in e.value) b.id],
      }..removeWhere((k, v) => v.isEmpty);

  Future<void> _loadSoundMarks() async {
    final audio = widget.audio;
    if (audio == null) return;
    final marks = await audio.marksOf(widget.noteId);
    if (!mounted) return;
    _followTimeline = null; // (made again from these marks)
    setState(() => _soundMarks = marks);
    _updateFollow();
  }

  /// The sound being played changes or moves on: the lines written at this moment of it are lit.
  void _onSoundTick() {
    final player = _soundPlayer;
    if (player == null) return;
    final path = player.path;
    if (path != _followPath) {
      // another sound (or none): which recording is it?
      _followPath = path;
      _followAudioId = null;
      _followTimeline = null;
      _followPage = null;
      _followIds.value = const {};
      if (path != null) unawaited(_findFollowedRecording(path));
      return;
    }
    _updateFollow();
  }

  Future<void> _findFollowedRecording(String path) async {
    final audio = widget.audio;
    if (audio == null) return;
    String? found;
    for (final a in await audio.list(widget.noteId)) {
      if ((await audio.fileOf(a))?.path == path) {
        found = a.id;
        break;
      }
    }
    if (!mounted || _followPath != path) return; // (it has changed since)
    _followAudioId = found;
    _updateFollow();
  }

  void _updateFollow() {
    final player = _soundPlayer, audioId = _followAudioId;
    Set<String> ids = const {};
    if (player != null && player.path != null && audioId != null && _soundMarks.isNotEmpty) {
      final timeline = _followTimeline ??= SoundTimeline(audioId, _soundMarks);
      ids = timeline.idsAt(player.position);
    }
    if (setEquals(ids, _followIds.value)) return;
    _followIds.value = ids;
    // when the lit lines are on another page than before, that page is brought into view (not while they stay on one: a person who
    // scrolls away meanwhile is left where they are)
    final page = _pageOfElements(ids);
    if (page != null && page != _followPage) {
      _followPage = page;
      if (!_infinite) _jumpToPage(page);
    }
  }

  /// The first page that has one of the elements [ids].
  int? _pageOfElements(Set<String> ids) {
    if (ids.isEmpty) return null;
    final pages = {..._strokesPerPage.keys, ..._textBoxesPerPage.keys}.toList()..sort();
    for (final page in pages) {
      if ((_strokesPerPage[page] ?? const <DrawingStroke>[]).any((s) => ids.contains(s.id)) ||
          (_textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[]).any((b) => ids.contains(b.id))) {
        return page;
      }
    }
    return null;
  }

  /// Draws a glow around the lines that were being written at the moment of the sound that plays.
  Widget _followOverlay(int pageIndex) => ValueListenableBuilder<Set<String>>(
        valueListenable: _followIds,
        builder: (context, ids, _) {
          if (ids.isEmpty) return const SizedBox.shrink();
          final rects = <Rect>[
            for (final s in _strokesPerPage[pageIndex] ?? const <DrawingStroke>[])
              if (ids.contains(s.id) && s.points.isNotEmpty) _boundsOf(s),
            for (final b in _textBoxesPerPage[pageIndex] ?? const <TextBoxWidgetModel>[])
              if (ids.contains(b.id)) _boxRect(b).inflate(2),
          ];
          if (rects.isEmpty) return const SizedBox.shrink();
          return Positioned.fill(child: IgnorePointer(child: CustomPaint(key: ValueKey('follow-$pageIndex'), painter: _FollowPainter(rects, Theme.of(context).colorScheme.primary))));
        },
      );

  /// A tap on a line that was written during the recording that plays: the sound goes to that moment (and goes on if it was paused).
  Future<void> _jumpSoundTo(String elementId) async {
    final player = _soundPlayer, audioId = _followAudioId;
    if (player == null || player.path == null || audioId == null || !player.canSeek) return;
    final to = (_followTimeline ??= SoundTimeline(audioId, _soundMarks)).startFor(elementId);
    if (to == null) return;
    await player.seek(to);
    if (player.paused) await player.resume();
  }

  Widget _lectureButton() {
    final rec = _lecture;
    if (rec == null || !rec.recording) {
      return IconButton(
        key: const ValueKey('lecture-button'),
        tooltip: tr('Record the sound while you write: each line is tied to the moment it was written'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.fiber_manual_record_outlined, size: 20),
        onPressed: _startLecture,
      );
    }
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(seconds: 1), (n) => n),
      builder: (context, _) => TextButton.icon(
        key: const ValueKey('lecture-button'),
        onPressed: _stopLecture,
        style: TextButton.styleFrom(foregroundColor: Colors.red, visualDensity: VisualDensity.compact),
        icon: const Icon(Icons.stop_circle_outlined, size: 20),
        label: Text.verbatim('${rec.length.inMinutes}:${(rec.length.inSeconds % 60).toString().padLeft(2, '0')}'),
      ),
    );
  }

  Future<void> _startLecture() async {
    // (the recorder is taken at once, before the microphone is open: a second press meanwhile starts no second one, which would go
    // on recording unseen; _lecture is null again only when a recording is over)
    if (widget.audio == null || _lecture != null) return;
    final rec = _lecture = LectureRecorder(mic: widget.lectureMic?.call());
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await rec.start(_elementIds())) {
        _lecture = null;
        messenger.showSnackBar(SnackBar(content: Text(tr('The microphone is not allowed (see the settings of the system)'))));
        return;
      }
    } catch (e) {
      _lecture = null;
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not start recording: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')}))));
      return;
    }
    if (!mounted) {
      // the note was closed while the microphone was being opened: it is closed again (a moment of sound is not kept)
      unawaited(rec.cancel());
      return;
    }
    _lectureCounts
      ..clear()
      ..addAll(_pageCounts());
    setState(() {});
  }

  Map<int, int> _pageCounts() => {
        for (final e in _strokesPerPage.entries) e.key: e.value.length,
        for (final e in _textBoxesPerPage.entries) e.key: (e.value.length) + 100000,
      };

  /// Called on every change: when the recording goes, the elements that came since get their moment. (A page whose number of strokes and
  /// text boxes has not changed is not looked through.)
  void _observeLecture() {
    final rec = _lecture;
    if (rec == null || !rec.recording) return;
    final now = _pageCounts();
    if (now.length == _lectureCounts.length && now.entries.every((e) => _lectureCounts[e.key] == e.value)) return;
    _lectureCounts
      ..clear()
      ..addAll(now);
    rec.observe(_elementIds());
  }

  Future<void> _stopLecture() async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await _finishLecture();
    if (!mounted) return;
    setState(() => _lecture = null);
    if (saved == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Nothing was recorded'))));
    } else {
      messenger.showSnackBar(SnackBar(content: Text(trCount(saved, 'Kept the sound with 1 line tied to its moment', 'Kept the sound with {n} lines tied to their moments'))));
    }
  }

  /// Ends the recording and keeps it with the note, with the marks; says how many elements were marked, null when nothing was kept.
  Future<int?> _finishLecture() async {
    final rec = _lecture, audio = widget.audio;
    if (rec == null || audio == null) return null;
    _observeLecture();
    final result = await rec.finish();
    if (result == null) return null;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final kept = await audio.add(widget.noteId, result.wav,
        title: tr('Lecture {date}', {'date': '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}'}), duration: result.length);
    await audio.saveMarks(widget.noteId, kept.id, result.marks);
    await _loadSoundMarks();
    return result.marks.length;
  }

  /// A note that is left while the recording goes on keeps what was recorded.
  void _finishLectureOnClose() {
    final rec = _lecture;
    if (rec == null || !rec.recording) return;
    unawaited(_finishLecture().catchError((Object e) {
      debugPrint('keeping the lecture failed: $e');
      return null;
    }));
  }

  /// Where the first of the selected strokes was written, if the recordings know.
  SoundPoint? _soundPointOfSelection() {
    if (_soundMarks.isEmpty || _selection.isEmpty) return null;
    SoundPoint? first;
    for (final s in _selection) {
      final p = _soundMarks[s.id];
      if (p != null && (first == null || p.offsetMs < first.offsetMs)) first = p;
    }
    return first;
  }

  Widget _playFromHereButton() => IconButton(
        key: const ValueKey('play-from-here'),
        icon: const Icon(Icons.play_circle_outline),
        tooltip: tr('Play the sound from when this was written'),
        visualDensity: VisualDensity.compact,
        onPressed: _playFromSelection,
      );

  Future<void> _playFromSelection() async {
    final point = _soundPointOfSelection(), audio = widget.audio;
    if (point == null || audio == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final sound = (await audio.list(widget.noteId)).where((a) => a.id == point.audioId).firstOrNull;
    final file = sound == null ? null : await audio.fileOf(sound);
    if (file == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('The sound of this line is not there any more'))));
      return;
    }
    try {
      // a little before, so that the first words are not cut
      final from = point.offset - const Duration(seconds: 2);
      await _sounds.play(file.path, from: from.isNegative ? Duration.zero : from, length: sound!.duration);
      if (mounted) setState(() {});
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim('$e'.replaceFirst('Bad state: ', ''))));
    }
  }
}

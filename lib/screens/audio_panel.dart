import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../ai/text_provider.dart' show AiCancel;
import '../audio/sound_marks.dart';
import '../audio/sound_player.dart';
import '../data/audio_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// The sounds kept with a note: recordings made while writing it down, and the note read aloud into a file. Each can be played,
/// paused, moved within, named and deleted.
class AudioPanel extends StatefulWidget {
  final String noteId;
  final AudioRepository audio;
  final SoundPlayer player;

  /// Whether this device can write a reading of the note into a file.
  final Future<bool> canMakeReading;

  /// Reads the note into a new sound ([onProgress] says how far; [cancel] stops it). Null: not offered.
  final Future<void> Function(void Function(int done, int total) onProgress, AiCancel cancel)? onMakeReading;
  final VoidCallback? onClose;

  const AudioPanel({super.key, required this.noteId, required this.audio, required this.player, required this.canMakeReading, this.onMakeReading, this.onClose});

  @override
  State<AudioPanel> createState() => _AudioPanelState();
}

class _AudioPanelState extends State<AudioPanel> {
  List<NoteAudio> _sounds = const [];

  /// The moments (in ms) at which lines of the note were written, by recording: ticks on the bar of the sound.
  Map<String, List<int>> _ticks = const {};
  bool _loaded = false;
  StreamSubscription<void>? _sub;
  String? _problem;
  (int, int)? _making;
  AiCancel? _cancel;

  @override
  void initState() {
    super.initState();
    _sub = widget.audio.changes.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await widget.audio.list(widget.noteId);
    final marks = await widget.audio.marksOf(widget.noteId);
    if (mounted) {
      setState(() {
        _sounds = list;
        _ticks = {for (final a in list) if (SoundTimeline(a.id, marks) case final t when !t.isEmpty) a.id: t.offsetsMs};
        _loaded = true;
      });
    }
  }

  static String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  static String _size(int bytes) => bytes < 1 << 20 ? tr('{n} KB', {'n': (bytes / 1024).ceil()}) : tr('{n} MB', {'n': (bytes / (1 << 20)).toStringAsFixed(1)});

  String _title(NoteAudio a) {
    if (a.title.isNotEmpty) return a.title;
    final l = MaterialLocalizations.of(context);
    final when = '${l.formatMediumDate(a.createdAt)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(a.createdAt), alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat)}';
    return a.kind == AudioKind.speech ? tr('Reading, {when}', {'when': when}) : tr('Recording, {when}', {'when': when});
  }

  Future<void> _toggle(NoteAudio a) async {
    final player = widget.player;
    final file = await widget.audio.fileOf(a);
    if (file == null) {
      setState(() => _problem = tr('The file of this sound is missing.'));
      return;
    }
    try {
      setState(() => _problem = null);
      if (player.path == file.path) {
        player.playing ? await player.pause() : await player.resume();
      } else {
        await player.play(file.path, length: a.duration);
      }
    } catch (e) {
      if (mounted) setState(() => _problem = '$e'.replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _rename(NoteAudio a) async {
    final name = await showDialog<String>(context: context, builder: (context) => _NameDialog(initial: a.title));
    if (name != null) await widget.audio.rename(a, name);
  }

  Future<void> _delete(NoteAudio a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Delete this sound?'),
        content: Text.verbatim(tr('"{title}" is taken out of the note for good.', {'title': _title(a)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('audio-delete-ok'), onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final file = await widget.audio.fileOf(a);
    if (file != null && widget.player.path == file.path) await widget.player.stop();
    await widget.audio.remove(a);
  }

  Future<void> _makeReading() async {
    final make = widget.onMakeReading;
    if (make == null) return;
    final cancel = _cancel = AiCancel();
    setState(() {
      _making = (0, 0);
      _problem = null;
    });
    try {
      await make((done, total) {
        if (mounted) setState(() => _making = (done, total));
      }, cancel);
    } catch (e) {
      if (mounted) setState(() => _problem = '$e'.replaceFirst('Bad state: ', ''));
    }
    if (mounted) setState(() => _making = null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
        child: Row(children: [
          Expanded(child: Text('Sound', style: Theme.of(context).textTheme.titleMedium)),
          if (widget.onClose != null) IconButton(tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: widget.onClose),
        ]),
      ),
      if (_problem != null) Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Text.verbatim(_problem!, key: const ValueKey('audio-problem'), style: TextStyle(color: scheme.error))),
      Expanded(
        child: ListenableBuilder(
          listenable: widget.player,
          builder: (context, _) {
            if (!_loaded) return const Center(child: CircularProgressIndicator.adaptive(),);
            if (_sounds.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('No sound is kept with this note. Record a meeting from the dashboard or dictate with "Keep the sound", or have the note read into a sound file below.',
                      textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              );
            }
            return ListView(children: [for (final a in _sounds) _row(context, a)]);
          },
        ),
      ),
      if (widget.onMakeReading != null)
        FutureBuilder<bool>(
          future: widget.canMakeReading,
          builder: (context, snap) {
            final can = snap.data ?? false;
            return Padding(
              padding: const EdgeInsets.all(12),
              child: _making != null
                  ? Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          LinearProgressIndicator(value: _making!.$2 == 0 ? null : _making!.$1 / _making!.$2),
                          const SizedBox(height: 4),
                          Text('Making the sound file...', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                      TextButton(key: const ValueKey('audio-making-stop'), onPressed: () => _cancel?.cancel(), child: const Text('Stop')),
                    ])
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        FilledButton.tonalIcon(
                          key: const ValueKey('audio-make-reading'),
                          icon: const Icon(Icons.record_voice_over_outlined, size: 18),
                          label: const Text('Read the note into a sound file'),
                          onPressed: can ? _makeReading : null,
                        ),
                        if (snap.hasData && !can)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('This device cannot save a voice as a file (on Linux it needs espeak-ng).', key: const ValueKey('audio-cannot'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          ),
                      ]),
                    ),
            );
          },
        ),
    ]);
  }

  Widget _row(BuildContext context, NoteAudio a) {
    final player = widget.player;
    final scheme = Theme.of(context).colorScheme;
    // the player knows files, not sounds: this row is the one playing when the file is
    final current = player.path != null && player.path!.endsWith('${a.id}.wav') && player.path!.contains(a.noteId);
    final length = current && player.length > Duration.zero ? player.length : a.duration;
    final position = current ? player.position : Duration.zero;
    return Column(children: [
      ListTile(
        key: ValueKey('audio-${a.id}'),
        leading: IconButton.filledTonal(
          key: ValueKey('audio-play-${a.id}'),
          tooltip: tr(current && player.playing ? 'Pause' : 'Play'),
          icon: Icon(current && player.playing ? Icons.pause : Icons.play_arrow),
          onPressed: () => _toggle(a),
        ),
        title: Text.verbatim(_title(a), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text.verbatim('${_clock(current ? position : Duration.zero)} / ${_clock(length)}  -  ${_size(a.bytes)}'),
        trailing: PopupMenuButton<VoidCallback>(
          key: ValueKey('audio-menu-${a.id}'),
          onSelected: (action) => action(),
          itemBuilder: (_) => [
            PopupMenuItem(key: ValueKey('audio-rename-${a.id}'), value: () => _rename(a), child: const Text('Name')),
            PopupMenuItem(key: ValueKey('audio-delete-${a.id}'), value: () => _delete(a), child: const Text('Delete')),
          ],
        ),
      ),
      if (current)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: player.canSeek && length > Duration.zero
              ? Slider.adaptive(
                  value: position.inMilliseconds.clamp(0, length.inMilliseconds).toDouble(),
                  max: length.inMilliseconds.toDouble(),
                  onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
                )
              : LinearProgressIndicator(value: length > Duration.zero ? (position.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0) : null, color: scheme.primary),
        ),
      // where lines of the note were written during this recording
      if (current && length > Duration.zero && (_ticks[a.id]?.isNotEmpty ?? false))
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 0, 26, 8),
          child: Tooltip(
            message: tr('Marks show when lines of the note were written'),
            child: CustomPaint(key: ValueKey('audio-ticks-${a.id}'), size: const Size(double.infinity, 6), painter: _TickPainter(_ticks[a.id]!, length.inMilliseconds, scheme.primary)),
          ),
        ),
    ]);
  }
}

/// Small ticks along the bar of a sound at the moments lines of the note were written.
class _TickPainter extends CustomPainter {
  final List<int> offsetsMs;
  final int lengthMs;
  final Color color;
  const _TickPainter(this.offsetsMs, this.lengthMs, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (lengthMs <= 0 || size.width <= 0) return;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.65)
      ..strokeWidth = 2;
    var lastX = -10.0;
    for (final ms in offsetsMs) {
      final x = (ms / lengthMs).clamp(0.0, 1.0) * size.width;
      if (x - lastX < 2) continue; // (a crowd of lines in one moment is one tick)
      lastX = x;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.lengthMs != lengthMs || old.color != color || !identical(old.offsetsMs, offsetsMs);
}

class _NameDialog extends StatefulWidget {
  final String initial;

  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Name this sound'),
        content: TextField(key: const ValueKey('audio-name-field'), controller: _field, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('audio-name-ok'), onPressed: () => Navigator.pop(context, _field.text), child: const Text('Save')),
        ],
      );
}

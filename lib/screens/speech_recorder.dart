import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../audio/wav.dart';
import '../ink/ink_recognizer.dart' show HandwritingStatus;
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../speech/mic_recorder.dart';
import '../speech/speech_to_text.dart';
import '../speech/whisper_audio.dart';

/// What a recording came to: what was said as text, and the sound itself when the person chose to keep it.
class SpeechRecording {
  final String text;

  /// The sound as a WAV file (mu-law, see `SpeechWavWriter`); null when it is not kept.
  final Uint8List? audio;
  final Duration length;

  const SpeechRecording(this.text, {this.audio, this.length = Duration.zero});
}

/// Records from the microphone and writes down what is said while it goes: every time about half a minute of sound is there
/// (cut where it is quiet) it is given to Whisper, so that the text grows during the meeting and little is left to do at the end.
/// Returns the text, or null when it was cancelled.
Future<String?> showSpeechRecorder(BuildContext context, {required SpeechToText speech, MicRecorder? mic, String? title}) async =>
    (await showSpeechRecording(context, speech: speech, mic: mic, title: title))?.text;

/// Like [showSpeechRecorder], and with [offerKeep] the person can choose to keep the sound ([keepByDefault] says what is chosen
/// to begin with); it comes back in [SpeechRecording.audio].
Future<SpeechRecording?> showSpeechRecording(BuildContext context, {required SpeechToText speech, MicRecorder? mic, String? title, bool offerKeep = false, bool keepByDefault = true}) =>
    showDialog<SpeechRecording>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          child: _SpeechRecorder(speech: speech, mic: mic ?? MicRecorder(), title: title, offerKeep: offerKeep, keep: keepByDefault),
        ),
      ),
    );

class _SpeechRecorder extends StatefulWidget {
  final SpeechToText speech;
  final MicRecorder mic;
  final String? title;
  final bool offerKeep;
  final bool keep;
  const _SpeechRecorder({required this.speech, required this.mic, this.title, this.offerKeep = false, this.keep = true});

  @override
  State<_SpeechRecorder> createState() => _SpeechRecorderState();
}

class _SpeechRecorderState extends State<_SpeechRecorder> {
  Timer? _tick;
  var _audio = Float32List(0);
  final _pieces = <String>[];
  final _jobs = <Future<void>>[];
  int _done = 0, _started = 0;
  String? _problem;
  bool _finishing = false;
  bool _stopped = false;
  bool _cancelled = false;
  final _scroll = ScrollController();

  /// The sound as it is recorded, kept small as it goes (a lecture is an hour: as samples it would take 230 MB).
  final SpeechWavWriter _kept = SpeechWavWriter(fromRate: whisperSampleRate);
  late bool _keep = widget.keep;

  String get _text => _pieces.where((p) => p.isNotEmpty).join(' ');

  @override
  void dispose() {
    _tick?.cancel();
    _cancelled = true;
    widget.mic.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _problem = null);
    try {
      await widget.mic.start();
      _tick?.cancel(); // (a second press while the microphone was being opened)
      _tick = Timer.periodic(const Duration(seconds: 2), (_) => _collect());
    } catch (e) {
      setState(() => _problem = '$e'.replaceFirst('Bad state: ', ''));
    }
  }

  void _append(Float32List more) {
    if (more.isEmpty) return;
    if (widget.offerKeep) _kept.add(more);
    final joined = Float32List(_audio.length + more.length)
      ..setAll(0, _audio)
      ..setAll(_audio.length, more);
    _audio = joined;
  }

  /// Takes what has been recorded; when there is a window's worth, all but the last bit of it goes to be written down.
  void _collect({bool last = false}) {
    _append(widget.mic.take());
    final window = 28 * whisperSampleRate;
    if (!last && _audio.length < window) return;
    final pieces = last ? [_audio] : splitAtQuiet(_audio);
    final rest = last ? Float32List(0) : (pieces.length > 1 ? pieces.removeLast() : Float32List(0));
    _audio = rest;
    for (final piece in pieces) {
      if (piece.length < whisperSampleRate ~/ 2) continue;
      final index = _pieces.length;
      _pieces.add('');
      _started++;
      _jobs.add(widget.speech.transcribe(piece, shouldStop: () => _cancelled).then((text) {
        _pieces[index] = text.trim();
      }).catchError((Object e) {
        _problem = '$e'.replaceFirst('Bad state: ', '');
      }).whenComplete(() {
        _done++;
        if (mounted) {
          setState(() {});
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }
      }));
    }
    if (mounted) setState(() {});
  }

  Future<void> _stop() async {
    _tick?.cancel();
    setState(() => _finishing = true);
    _append(await widget.mic.stop());
    _collect(last: true);
    await Future.wait(_jobs);
    if (mounted) {
      setState(() {
        _finishing = false;
        _stopped = true;
      });
    }
  }

  static String _clock(Duration d) => '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.speech, widget.mic]),
      builder: (context, _) {
        final speech = widget.speech;
        final recording = widget.mic.recording;
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(children: [
              const Icon(Icons.mic_none, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text.verbatim(widget.title ?? tr('Record and write down'), style: Theme.of(context).textTheme.titleSmall)),
              IconButton(
                key: const ValueKey('speech-cancel'),
                tooltip: tr('Cancel'),
                icon: const Icon(Icons.close),
                onPressed: () async {
                  _cancelled = true;
                  _tick?.cancel();
                  if (recording) await widget.mic.stop();
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ]),
          ),
          const Divider(height: 1),
          if (speech.status != HandwritingStatus.installed) Expanded(child: _download(context)) else ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                if (!_stopped && !_finishing)
                  FilledButton.icon(
                    key: ValueKey(recording ? 'speech-stop' : 'speech-record'),
                    style: recording ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError) : null,
                    onPressed: recording ? _stop : _start,
                    icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record),
                    label: Text(recording ? 'Stop' : 'Record'),
                  ),
                if (_finishing) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)),
                const SizedBox(width: 16),
                if (recording || _stopped || _finishing) Text.verbatim(_clock(widget.mic.length), key: const ValueKey('speech-clock')),
                const SizedBox(width: 12),
                if (recording) Expanded(child: LinearProgressIndicator(value: widget.mic.level.clamp(0.0, 1.0).toDouble())) else const Spacer(),
              ]),
            ),
            if (_problem != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text.verbatim(_problem!, key: const ValueKey('speech-problem'), style: TextStyle(color: scheme.error))),
            if (_started > _done)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_finishing ? 'Writing down the last part...' : 'Writing down...', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SelectableText(
                    _text.isEmpty ? tr(recording ? 'What is said appears here, about every half minute.' : 'Press Record and speak. Everything stays on this device.') : _text,
                    key: const ValueKey('speech-text'),
                    style: TextStyle(color: _text.isEmpty ? scheme.onSurfaceVariant : null),
                  ),
                ),
              ),
            ),
            if (widget.offerKeep)
              CheckboxListTile.adaptive(
                key: const ValueKey('speech-keep'),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _keep,
                onChanged: _finishing ? null : (v) => setState(() => _keep = v ?? false),
                title: const Text('Keep the sound with the note, to listen to later'),
                subtitle: Text.verbatim(tr('About {mb} MB an hour', {'mb': 29}), style: const TextStyle(fontSize: 12)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                FilledButton(
                  key: const ValueKey('speech-use'),
                  onPressed: _stopped && _text.isNotEmpty
                      ? () => Navigator.pop(context, SpeechRecording(_text, audio: widget.offerKeep && _keep ? _kept.finish() : null, length: _kept.length))
                      : null,
                  child: const Text('Use the text'),
                ),
              ]),
            ),
          ],
        ]);
      },
    );
  }

  Widget _download(BuildContext context) {
    final speech = widget.speech;
    final scheme = Theme.of(context).colorScheme;
    final downloading = speech.status == HandwritingStatus.downloading;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.record_voice_over_outlined, size: 40, color: scheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Text.verbatim(
          tr('Writing down speech needs a model on this device (about {size} MB). It works without the internet, and nothing you say leaves the device.', {'size': speech.sizeMb}),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        if (downloading)
          LinearProgressIndicator(value: speech.progress > 0 ? speech.progress : null)
        else
          FilledButton(key: const ValueKey('speech-download'), onPressed: speech.install, child: const Text('Download')),
        if (speech.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(speech.error!, style: TextStyle(color: scheme.error))),
      ]),
    );
  }
}

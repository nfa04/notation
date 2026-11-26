import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pure_audio/pure_audio.dart' show AudioFormatException, ByteSource, MemoryByteSource;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../speech/speech_to_text.dart';
import '../style/platform_dialog.dart';
import '../transcript/media_source_io.dart' if (dart.library.js_interop) '../transcript/media_source_web.dart';
import '../transcript/transcribe_media.dart';
import '../transcript/transcript.dart';
import '../transcript/transcript_source.dart';
import 'note_file_actions.dart' show pickerFilter;

const _largestCaptionFile = 8 * 1024 * 1024;

/// "Note from a transcript": the person pastes captions or picks a caption file (SRT, VTT, YouTube's own formats), or has a source
/// (an extension) fetch them from an address; a new note is made with the text, a time on each paragraph. [onOpenNote] opens it.
Future<void> showTranscriptImport(
  BuildContext context, {
  required NoteRepository repository,
  required ValueChanged<String> onOpenNote,
  String? folderId,
  List<TranscriptSource> sources = const [],
  SpeechToText? speech,
}) async {
  final id = await showDialog<String>(
    context: context,
    builder: (context) => _TranscriptDialog(repository: repository, folderId: folderId, sources: sources, speech: speech),
  );
  if (id != null) onOpenNote(id);
}

class _TranscriptDialog extends StatefulWidget {
  final NoteRepository repository;
  final String? folderId;
  final List<TranscriptSource> sources;
  final SpeechToText? speech;
  const _TranscriptDialog({required this.repository, required this.folderId, required this.sources, this.speech});

  @override
  State<_TranscriptDialog> createState() => _TranscriptDialogState();
}

class _TranscriptDialogState extends State<_TranscriptDialog> {
  final _title = TextEditingController();
  final _source = TextEditingController();
  final _captions = TextEditingController();
  bool _times = true;
  bool _busy = false;
  String? _error;

  /// What a source fetched (used while the pasted text is left alone), or what the pasted text makes.
  Transcript? _fetched;
  Transcript? _parsed;
  String? _parseError;
  String? _fetchingWith;

  // listening to a media file
  bool _listening = false, _stopAsked = false;
  double _heard = 0;
  double? _heardOf;

  @override
  void dispose() {
    _title.dispose();
    _source.dispose();
    _captions.dispose();
    super.dispose();
  }

  Transcript? get _current => _fetched ?? _parsed;

  void _reparse() {
    final text = _captions.text;
    if (text.trim().isEmpty) {
      _parsed = null;
      _parseError = null;
      return;
    }
    try {
      _parsed = Transcript(source: _source.text.trim(), segments: parseCaptions(text));
      _parseError = null;
    } on FormatException catch (e) {
      _parsed = null;
      _parseError = e.message;
    }
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Pick a caption file',
      type: pickerFilter(const ['srt', 'vtt', 'json', 'xml', 'txt', 'sbv']).type,
      allowedExtensions: pickerFilter(const ['srt', 'vtt', 'json', 'xml', 'txt', 'sbv']).extensions,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (bytes.length > _largestCaptionFile) {
      if (mounted) setState(() => _error = tr('This file is too big to be a caption file.'));
      return;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!mounted) return;
    setState(() {
      _error = null;
      _fetched = null;
      _captions.text = text;
      if (_title.text.trim().isEmpty) _title.text = picked.name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '').replaceFirst(RegExp(r'\.[a-z]{2}(-[A-Za-z]+)?$'), '');
      _reparse();
    });
  }

  static const _mediaExtensions = ['mp4', 'm4a', 'm4v', 'mov', 'mp3', 'wav', 'flac', 'aac', 'mkv', 'mka', 'webm'];

  /// Writes down what is said in an audio or video file, with Whisper on this device.
  Future<void> _listen() async {
    final speech = widget.speech!;
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Pick a video or audio file',
      type: pickerFilter(_mediaExtensions).type,
      allowedExtensions: pickerFilter(_mediaExtensions).extensions,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _listening = true;
      _stopAsked = false;
      _heard = 0;
      _heardOf = null;
      _error = null;
    });
    ByteSource? source;
    try {
      source = kIsWeb || picked.path == null ? MemoryByteSource(await picked.readAsBytes()) : await openFileSource(picked.path!);
      final t = await transcribeMedia(
        speech,
        source,
        name: picked.name,
        progress: (done, total) {
          if (mounted) {
            setState(() {
              _heard = done;
              _heardOf = total;
            });
          }
        },
        shouldStop: () => _stopAsked || !mounted,
      );
      if (!mounted) return;
      if (t.isEmpty) throw const AudioFormatException('No speech was found in this file.');
      setState(() {
        _fetched = Transcript(title: t.title, source: t.source, language: t.language, segments: t.segments);
        _captions.clear();
        _parsed = null;
        _parseError = null;
        if (_title.text.trim().isEmpty) _title.text = t.title;
      });
    } on AudioFormatException catch (e) {
      if (mounted) setState(() => _error = tr(e.message));
    } on StateError {
      if (mounted) setState(() => _error = tr('The speech model is not downloaded yet. Get it in the settings.'));
    } catch (e) {
      if (mounted) setState(() => _error = tr('Could not listen to this file: {error}', {'error': e}));
    } finally {
      await source?.close();
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _fetch(TranscriptSource source) async {
    final input = _source.text.trim();
    if (input.isEmpty) return;
    setState(() {
      _busy = true;
      _fetchingWith = source.id;
      _error = null;
    });
    try {
      final t = await source.fetch(input);
      if (!mounted) return;
      if (t.isEmpty) throw const TranscriptSourceError('There were no captions to take.');
      setState(() {
        _fetched = Transcript(title: t.title, source: t.source.isEmpty ? input : t.source, language: t.language, segments: t.segments);
        _captions.clear();
        _parsed = null;
        _parseError = null;
        if (_title.text.trim().isEmpty && t.title.isNotEmpty) _title.text = t.title;
      });
    } on TranscriptSourceError catch (e) {
      if (mounted) setState(() => _error = tr(e.message));
    } catch (e) {
      if (mounted) setState(() => _error = tr('{source} did not work: {error}', {'source': source.title, 'error': e}));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _fetchingWith = null;
        });
      }
    }
  }

  Future<void> _create() async {
    final t = _current;
    if (t == null) return;
    setState(() => _busy = true);
    try {
      final source = _source.text.trim().isNotEmpty ? _source.text.trim() : t.source;
      final text = formatTranscript(Transcript(title: t.title, source: source, language: t.language, segments: t.segments), times: _times, sourceLabel: tr('Source'));
      final title = _title.text.trim().isEmpty ? tr('Transcript') : _title.text.trim();
      final id = NoteRepository.newId();
      await widget.repository.createNote(title: title, folderId: widget.folderId, id: id);
      final note = (await widget.repository.loadNote(id))!;
      note.documentText = text;
      await widget.repository.saveNote(note);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = tr('Could not make the note: {error}', {'error': e});
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = _current;
    final length = t == null || t.segments.isEmpty ? null : clockText(t.segments.last.end > 0 ? t.segments.last.end : t.segments.last.start);
    return PlatformAlertDialog(
      title: const Text('Note from a transcript'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(key: const ValueKey('transcript-title'), controller: _title, decoration: InputDecoration(labelText: tr('Title'))),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('transcript-source'),
              controller: _source,
              decoration: InputDecoration(labelText: tr('Link or file name of the video (optional)'), helperText: tr('A link makes every time in the note open the video at that point.')),
              onChanged: (_) => setState(() {
                _reparse();
              }),
            ),
            if (widget.sources.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final s in widget.sources)
                  OutlinedButton.icon(
                    key: ValueKey('transcript-fetch-${s.id}'),
                    onPressed: _busy || _source.text.trim().isEmpty ? null : () => _fetch(s),
                    icon: _fetchingWith == s.id ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Symbols.cloud_download),
                    label: Text.verbatim(tr('Get captions with {name}', {'name': s.title})),
                  ),
              ]),
            ],
            if (widget.speech != null) ...[
              const SizedBox(height: 8),
              if (_listening) ...[
                LinearProgressIndicator(key: const ValueKey('transcript-progress'), value: _heardOf == null || _heardOf == 0 ? null : (_heard / _heardOf!).clamp(0.0, 1.0)),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: Text.verbatim(tr('Listening: {done}{total}', {'done': clockText(_heard), 'total': _heardOf == null ? '' : ' / ${clockText(_heardOf!)}'}))),
                  TextButton(key: const ValueKey('transcript-stop'), onPressed: _stopAsked ? null : () => setState(() => _stopAsked = true), child: const Text('Stop and keep what is written')),
                ]),
              ] else
                OutlinedButton.icon(
                  key: const ValueKey('transcript-media'),
                  onPressed: _busy ? null : _listen,
                  icon: const Icon(Symbols.graphic_eq),
                  label: const Text('Listen to a video or audio file'),
                ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Text(widget.sources.isEmpty ? 'Paste the captions, or pick a caption file' : 'Or paste the captions, or pick a caption file', style: TextStyle(color: scheme.onSurfaceVariant))),
              TextButton.icon(key: const ValueKey('transcript-pick'), onPressed: _busy ? null : _pickFile, icon: const Icon(Symbols.upload_file), label: const Text('Pick a file')),
            ]),
            TextField(
              key: const ValueKey('transcript-captions'),
              controller: _captions,
              minLines: 5,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr('SRT, WebVTT, or YouTube JSON or XML')),
              onChanged: (_) => setState(() {
                _fetched = null;
                _reparse();
              }),
            ),
            const SizedBox(height: 8),
            if (_parseError != null) Text.verbatim(tr(_parseError!), key: const ValueKey('transcript-problem'), style: TextStyle(color: scheme.error)),
            if (_error != null) Text.verbatim(_error!, key: const ValueKey('transcript-error'), style: TextStyle(color: scheme.error)),
            if (t != null && length != null)
              Text.verbatim(
                tr('{lines} lines, {length} long', {'lines': t.segments.length, 'length': length}) + (t.language.isEmpty ? '' : ' · ${t.language}'),
                key: const ValueKey('transcript-summary'),
              ),
            SwitchListTile(
              key: const ValueKey('transcript-times'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Put the time at the start of each paragraph'),
              value: _times,
              onChanged: (v) => setState(() => _times = v),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy || _listening ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('transcript-create'), onPressed: _busy || _listening || t == null ? null : _create, child: const Text('Make the note')),
      ],
    );
  }
}

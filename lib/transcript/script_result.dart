import 'transcript.dart';
import 'transcript_source.dart';

const _mostSegments = 100000;

/// The transcript a transcript source of an extension answered with. The answer is an object with
///
/// * `segments`: `[{ start, end?, text }]`, seconds from the start (what a script that knows the times returns), or
///   `captions`: `{ text }`, a caption file as text (SRT, WebVTT, YouTube JSON or XML) which the app reads itself;
/// * `title`, `language`, `source` (the address of the video): all optional.
///
/// Anything else is refused with a sentence for the person ([TranscriptSourceError]); a script's mistakes are never taken on trust.
Transcript transcriptFromScript(Object? value, {required String input}) {
  if (value is! Map) throw const TranscriptSourceError('The extension did not answer with a transcript.');
  String line(String key, int max) {
    final v = value[key];
    if (v == null) return '';
    if (v is! String) throw TranscriptSourceError('"$key" of the answer has to be text.');
    return v.replaceAll(RegExp(r'\s+'), ' ').trim().characters(max);
  }

  final List<TranscriptSegment> segments;
  final raw = value['segments'];
  final captions = value['captions'];
  if (raw != null) {
    if (raw is! List) throw const TranscriptSourceError('"segments" of the answer has to be a list.');
    if (raw.length > _mostSegments) throw const TranscriptSourceError('The extension gave too many lines of captions.');
    segments = [];
    for (final e in raw) {
      if (e is! Map) throw const TranscriptSourceError('A line of the captions is not an object.');
      final start = e['start'], end = e['end'], text = e['text'];
      if (start is! num || !start.isFinite || start < 0 || start > 7 * 24 * 3600) throw const TranscriptSourceError('A line of the captions has no valid "start" (seconds).');
      if (end != null && (end is! num || !end.isFinite || end < start)) throw const TranscriptSourceError('A line of the captions has an "end" that is before its start.');
      if (text is! String) throw const TranscriptSourceError('A line of the captions has no "text".');
      final words = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (words.isEmpty) continue;
      segments.add(TranscriptSegment(start.toDouble(), (end as num?)?.toDouble() ?? start.toDouble(), words.characters(5000)));
    }
    segments.sort((a, b) => a.start.compareTo(b.start));
  } else if (captions is Map && captions['text'] is String) {
    if ((captions['text'] as String).length > 8 * 1024 * 1024) throw const TranscriptSourceError('The captions are too big.');
    try {
      segments = parseCaptions(captions['text'] as String);
    } on FormatException catch (e) {
      throw TranscriptSourceError(e.message);
    }
  } else {
    throw const TranscriptSourceError('The answer has neither "segments" nor "captions".');
  }

  // (the address of the video is only kept when it is one: it ends up in links)
  var source = line('source', 2000);
  final uri = Uri.tryParse(source);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty || source.contains(RegExp(r'[<>\s]'))) source = '';
  return Transcript(title: line('title', 200), source: source.isEmpty ? input.trim() : source, language: line('language', 20), segments: segments);
}

extension on String {
  String characters(int max) => length <= max ? this : substring(0, max);
}

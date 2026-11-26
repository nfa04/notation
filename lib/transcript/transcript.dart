import 'dart:convert';

/// One stretch of speech: when it starts and ends (seconds from the start of the recording) and what was said.
class TranscriptSegment {
  final double start, end;
  final String text;
  const TranscriptSegment(this.start, this.end, this.text);

  Map<String, Object?> toJson() => {'start': start, 'end': end, 'text': text};

  @override
  String toString() => '[$start-$end] $text';
}

/// A transcript: the segments in time order and where they came from.
class Transcript {
  final String title;

  /// The address or file name it was made from ('' if unknown). An address is used to make the times links.
  final String source;

  /// A language code like 'en' ('' if unknown).
  final String language;
  final List<TranscriptSegment> segments;
  const Transcript({this.title = '', this.source = '', this.language = '', required this.segments});

  bool get isEmpty => segments.isEmpty;
}

/// The segments in a caption text of any of these kinds, found out from the text itself: WebVTT, SubRip (SRT), YouTube's `json3`, and
/// the two XML kinds of YouTube (`<transcript><text start dur>` and `<timedtext><body><p t d>`). Throws a [FormatException] when it is
/// none of them or has no words in it. Overlapping cues of "rolling" automatic captions are made into one line each.
List<TranscriptSegment> parseCaptions(String input) {
  final text = input.replaceFirst('﻿', '').trim();
  if (text.isEmpty) throw const FormatException('The captions are empty.');
  List<TranscriptSegment> found;
  if (text.startsWith('{')) {
    found = _json3(text);
  } else if (text.startsWith('<')) {
    found = _xml(text);
  } else if (text.startsWith('WEBVTT') || text.contains('-->')) {
    found = _cues(text);
  } else {
    throw const FormatException('This does not look like captions (WebVTT, SRT, YouTube JSON or XML).');
  }
  found = _tidy(found);
  if (found.isEmpty) throw const FormatException('There are no words in these captions.');
  return found;
}

/// The seconds of "00:01:02,500", "01:02.500" or "1:02" (null when it is not a time).
double? _clock(String s) {
  final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$').firstMatch(s.trim());
  if (m == null) return null;
  final ms = m.group(4) == null ? 0.0 : int.parse(m.group(4)!.padRight(3, '0')) / 1000;
  return ((int.tryParse(m.group(1) ?? '0') ?? 0) * 3600 + int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!)).toDouble() + ms;
}

List<TranscriptSegment> _cues(String text) {
  final out = <TranscriptSegment>[];
  for (final block in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split(RegExp(r'\n{2,}'))) {
    final lines = block.split('\n');
    final at = lines.indexWhere((l) => l.contains('-->'));
    if (at < 0) continue;
    final parts = lines[at].split('-->');
    final start = _clock(parts[0].trim().split(RegExp(r'\s+')).first);
    final end = _clock(parts[1].trim().split(RegExp(r'\s+')).first);
    if (start == null || end == null) continue;
    final words = [for (final l in lines.skip(at + 1)) _plain(l)].where((l) => l.isNotEmpty).join('\n');
    if (words.isNotEmpty) out.add(TranscriptSegment(start, end < start ? start : end, words));
  }
  return out;
}

List<TranscriptSegment> _json3(String text) {
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    throw const FormatException('The captions are not valid JSON.');
  }
  final events = data is Map ? data['events'] : null;
  if (events is! List) throw const FormatException('The JSON has no "events": it is not a YouTube caption file.');
  final out = <TranscriptSegment>[];
  for (final e in events) {
    if (e is! Map || e['segs'] is! List || e['tStartMs'] is! num) continue;
    final words = _plain((e['segs'] as List).map((s) => s is Map ? '${s['utf8'] ?? ''}' : '').join());
    if (words.isEmpty) continue;
    final start = (e['tStartMs'] as num) / 1000;
    out.add(TranscriptSegment(start, start + ((e['dDurationMs'] as num?) ?? 0) / 1000, words));
  }
  return out;
}

List<TranscriptSegment> _xml(String text) {
  final out = <TranscriptSegment>[];
  // <text start="1.5" dur="2">..</text> (seconds) and <p t="1500" d="2000">..</p> (milliseconds)
  for (final m in RegExp(r'<(text|p)\s([^>]*)>(.*?)</\1>', dotAll: true).allMatches(text)) {
    final attrs = {for (final a in RegExp(r'([\w:]+)="([^"]*)"').allMatches(m.group(2)!)) a.group(1)!: a.group(2)!};
    final seconds = m.group(1) == 'text';
    final from = double.tryParse(attrs[seconds ? 'start' : 't'] ?? '');
    if (from == null) continue;
    final length = double.tryParse(attrs[seconds ? 'dur' : 'd'] ?? '') ?? 0;
    final start = seconds ? from : from / 1000;
    // (the older kind writes `&amp;#39;`: the entities were encoded twice, so they are read twice, after the tags are gone)
    final words = _plain(_entities(m.group(3)!.replaceAll(RegExp(r'<[^>]*>'), '')));
    if (words.isNotEmpty) out.add(TranscriptSegment(start, start + (seconds ? length : length / 1000), words));
  }
  if (out.isEmpty && !text.contains('<text') && !text.contains('<p ')) throw const FormatException('This XML has no captions in it.');
  return out;
}

/// Without markup, with entities turned into letters and white space folded to single spaces (line breaks kept as `\n` by the caller
/// where it joins lines).
String _plain(String s) {
  var t = s.replaceAll(RegExp(r'<[^>]*>'), '');
  t = _entities(t);
  t = t.replaceAll(RegExp(r'\{\\an?\d+\}'), '').replaceAll(RegExp(r'[ \t ]+'), ' ');
  return t.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
}

String _entities(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp);'), (m) {
      final e = m.group(1)!;
      switch (e) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
      }
      final code = e.startsWith('#x') ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
      return code == null || code > 0x10FFFF ? m.group(0)! : String.fromCharCode(code);
    });

/// Puts the segments in time order, folds each into one line, and drops what automatic captions repeat: a cue that shows the line of
/// the one before it again (rolling captions), or says the same.
List<TranscriptSegment> _tidy(List<TranscriptSegment> input) {
  final sorted = [...input]..sort((a, b) => a.start.compareTo(b.start));
  final out = <TranscriptSegment>[];
  var lastLine = '';
  for (final s in sorted) {
    final lines = s.text.split('\n').where((l) => l.isNotEmpty).toList();
    // the first lines that were already on screen in the cue before
    while (lines.isNotEmpty && lines.first == lastLine) {
      lines.removeAt(0);
    }
    if (lines.isEmpty) continue;
    lastLine = lines.last;
    final words = lines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (words.isEmpty) continue;
    out.add(TranscriptSegment(s.start, s.end < s.start ? s.start : s.end, words));
  }
  return out;
}

/// "3:07" or, from an hour on, "1:03:07".
String clockText(num seconds) {
  final t = seconds < 0 ? 0 : seconds.floor();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, s = t % 60;
  final two = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$two' : '$m:$two';
}

/// An address that opens the video at [seconds], or null when the source is not one of those (a file, nothing). YouTube links go
/// to `youtu.be/ID?t=N`; any other http(s) address gets the media fragment `#t=N`, which players that know it follow.
String? timeLink(String source, int seconds) {
  final uri = Uri.tryParse(source.trim());
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) return null;
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m|music)\.'), '');
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.firstOrNull;
  } else if (host == 'youtube.com' || host == 'youtube-nocookie.com') {
    if (uri.path == '/watch') {
      id = uri.queryParameters['v'];
    } else if (uri.pathSegments.length >= 2 && const {'shorts', 'embed', 'live', 'v'}.contains(uri.pathSegments.first)) {
      id = uri.pathSegments[1];
    }
  }
  if (id != null && RegExp(r'^[\w-]{6,20}$').hasMatch(id)) return 'https://youtu.be/$id?t=$seconds';
  if (host == 'youtube.com' || host == 'youtu.be') return null;
  return uri.removeFragment().replace(fragment: 't=$seconds').toString();
}

/// The text of the note for a transcript: a line naming the source, then paragraphs of about [paragraphSeconds] each, every one
/// starting with its time (a link when the source is an address).
String formatTranscript(Transcript t, {int paragraphSeconds = 60, bool times = true, String sourceLabel = 'Source'}) {
  final out = StringBuffer();
  final source = t.source.trim();
  if (source.isNotEmpty) {
    out.writeln(timeLink(source, 0) != null || RegExp(r'^https?://', caseSensitive: false).hasMatch(source) ? '$sourceLabel: <$source>' : '$sourceLabel: $source');
    out.writeln();
  }
  final paragraph = <String>[];
  double? from;
  var previous = '';
  void flush() {
    if (paragraph.isEmpty) return;
    var mark = '';
    if (times) {
      final at = from!.floor();
      final link = source.isEmpty ? null : timeLink(source, at);
      mark = link == null ? '**${clockText(at)}** ' : '[${clockText(at)}]($link) ';
    }
    out.writeln('$mark${paragraph.join(' ')}');
    out.writeln();
    paragraph.clear();
    from = null;
  }

  for (final s in t.segments) {
    if (from != null) {
      final length = s.start - from!;
      final sentenceEnd = RegExp(r'[.!?…]["”)]?$').hasMatch(previous);
      if (length >= paragraphSeconds || (length >= paragraphSeconds / 2 && sentenceEnd)) flush();
    }
    from ??= s.start;
    paragraph.add(s.text);
    previous = s.text;
  }
  flush();
  return out.toString().trimRight();
}
